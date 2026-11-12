import Foundation

/// What the user typed into the site's login card.
public enum AccountLoginCredential: Equatable, Sendable {
    case password(login: String, password: String)
    case code(login: String, code: String)
}

public enum AccountOAuthProvider: String, CaseIterable, Sendable {
    case google
    case github
}

/// A pending device login: the site issues a token for `requestId` once a signed-in session approves it.
public struct AccountDeviceLogin: Codable, Equatable, Sendable {
    public let requestId: String
    public let verifier: String
    public let userCode: String
    public let verifyUrl: String
    public let expiresIn: Int
    public let interval: Int

    public init(requestId: String, verifier: String, userCode: String, verifyUrl: String, expiresIn: Int, interval: Int) {
        self.requestId = requestId
        self.verifier = verifier
        self.userCode = userCode
        self.verifyUrl = verifyUrl
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

/// A failure reported by the site (`{error, fields?, retryAfter?}`) or by the network.
public struct AccountAuthError: Error, Equatable, Sendable {
    public static let networkCode = "network"
    public static let network = AccountAuthError(code: networkCode)

    public let code: String
    public let fields: [String]
    public let retryAfter: Int?

    public init(code: String, fields: [String] = [], retryAfter: Int? = nil) {
        self.code = code
        self.fields = fields
        self.retryAfter = retryAfter
    }

    public var message: String {
        switch code {
        case "credentials": return "账号或密码错误"
        case "suspended": return "该账号已被停用"
        case "banned": return "该账号已被封禁"
        case "email_not_found": return "该邮箱尚未注册，请先注册"
        case "phone_not_found": return "该手机号尚未注册，请先注册"
        case "rate": return "尝试次数过多，请稍后再试"
        case "cooldown": return "验证码发送过于频繁，请稍后再试"
        case "delivery": return "验证码发送失败，请稍后再试"
        case "oauth_state": return "登录超时，请重试"
        case "oauth_denied": return "已取消授权"
        case "oauth_failed": return "第三方登录失败，请重试"
        case Self.networkCode: return "网络不可用，请重试"
        default: break
        }
        if fields.contains("code") { return "验证码错误或已过期" }
        if fields.contains(where: { ["target", "email", "phone"].contains($0) }) { return "格式不正确" }
        if fields.contains("password") { return "密码至少 8 位" }
        return "登录失败，请重试"
    }

    static func parse(status: Int, body: Data) -> AccountAuthError {
        struct Envelope: Decodable {
            let error: String?
            let fields: [String]?
            let retryAfter: Int?
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
        return AccountAuthError(
            code: envelope?.error ?? "http_\(status)",
            fields: envelope?.fields ?? [],
            retryAfter: envelope?.retryAfter
        )
    }
}

/// Talks to the VibeX site's login API on one cookie session, so a site login can approve a device token
/// without leaving the app. Each client owns its cookies; releasing the client discards the site session.
public struct AccountLoginClient: Sendable {
    public static let codeResendSeconds = 60

    private let siteBase: String
    private let transport: HttpTransport
    private let sleep: @Sendable (UInt64) async throws -> Void

    public init(
        siteBase: String,
        transport: HttpTransport = EphemeralSessionTransport(),
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        var base = siteBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        self.siteBase = base
        self.transport = transport
        self.sleep = sleep
    }

    /// Signs into the site; the session cookie stays in this client's transport.
    public func signIn(_ credential: AccountLoginCredential) async throws {
        let body: [String: String]
        switch credential {
        case .password(let login, let password):
            body = ["mode": "password", "login": login, "password": password]
        case .code(let login, let code):
            body = ["mode": "code", "login": login, "code": code]
        }
        _ = try await post("/api/auth/login", body)
    }

    public func sendLoginCode(to target: String) async throws {
        _ = try await post("/api/auth/code", ["target": target, "purpose": "login"])
    }

    public func startDeviceLogin(deviceName: String) async throws -> AccountDeviceLogin {
        let data = try await post(
            "/api/auth/desktop/start",
            ["deviceName": deviceName, "hostId": "", "nextPath": "/account"]
        )
        guard let login = try? JSONDecoder().decode(AccountDeviceLogin.self, from: data) else {
            throw AccountAuthError(code: "decode_failed")
        }
        return login
    }

    /// Approves the device login with this client's signed-in site session.
    public func approve(_ login: AccountDeviceLogin) async throws {
        struct Decision: Encodable {
            let requestId: String
            let approve: Bool
        }
        _ = try await post("/api/auth/desktop/decide", Decision(requestId: login.requestId, approve: true))
    }

    /// Polls until the device login is approved; transient network failures count as still pending.
    public func approvedToken(for login: AccountDeviceLogin, maxAttempts: Int) async throws -> String {
        struct Poll: Decodable {
            let status: String
            let token: String?
        }
        let intervalNanos = UInt64(max(login.interval, 1)) * 1_000_000_000
        for attempt in 0..<max(maxAttempts, 1) {
            if attempt > 0 { try await sleep(intervalNanos) }
            try Task.checkCancellation()
            let data: Data
            do {
                data = try await post(
                    "/api/auth/desktop/token",
                    ["requestId": login.requestId, "verifier": login.verifier]
                )
            } catch let error as AccountAuthError where error.code == AccountAuthError.networkCode {
                continue
            }
            guard let poll = try? JSONDecoder().decode(Poll.self, from: data) else {
                throw AccountAuthError(code: "decode_failed")
            }
            if poll.status == "approved", let token = poll.token, !token.isEmpty {
                return token
            }
            guard poll.status == "pending" else { throw AccountAuthError(code: poll.status) }
        }
        throw AccountAuthError(code: "expired")
    }

    /// Provider sign-in page that lands on the site's authorize page for `login` once the provider succeeds.
    public func oauthStartURL(_ provider: AccountOAuthProvider, for login: AccountDeviceLogin) -> URL? {
        guard let verify = URLComponents(string: login.verifyUrl) else { return nil }
        let nextPath = verify.percentEncodedPath + (verify.percentEncodedQuery.map { "?\($0)" } ?? "")
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let next = nextPath.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "\(siteBase)/api/auth/oauth/\(provider.rawValue)/start?next=\(next)")
    }

    private func post<Body: Encodable>(_ path: String, _ body: Body) async throws -> Data {
        let exchange: HttpExchange
        do {
            exchange = try await transport.execute(
                method: "POST",
                url: siteBase + path,
                headers: [
                    "content-type": "application/json",
                    "accept": "application/json",
                    "origin": siteBase,
                ],
                body: try JSONEncoder().encode(body)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountAuthError.network
        }
        guard (200...299).contains(exchange.status) else {
            throw AccountAuthError.parse(status: exchange.status, body: exchange.body)
        }
        return exchange.body
    }
}

/// Plain HTTPS transport with private in-memory cookie storage, invalidated when released.
public final class EphemeralSessionTransport: HttpTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func execute(
        method: String,
        url: String,
        headers: [String: String],
        body: Data?
    ) async throws -> HttpExchange {
        guard let target = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        return HttpExchange(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
