import Foundation
import Testing
@testable import CompanionCore

private final class RecordingTransport: HttpTransport, @unchecked Sendable {
    struct Recorded {
        let url: String
        let headers: [String: String]
        let json: [String: Any]
    }

    private let lock = NSLock()
    private var responses: [HttpExchange]
    private var recorded: [Recorded] = []

    init(_ responses: [(Int, String)]) {
        self.responses = responses.map { HttpExchange(status: $0.0, body: Data($0.1.utf8)) }
    }

    var requests: [Recorded] { lock.withLock { recorded } }

    func execute(method: String, url: String, headers: [String: String], body: Data?) async throws -> HttpExchange {
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return lock.withLock {
            recorded.append(Recorded(url: url, headers: headers, json: json))
            return responses.removeFirst()
        }
    }
}

private let deviceLoginJSON = """
    {"requestId":"req-1","verifier":"ver-1","userCode":"ABCD","verifyUrl":"https://vibex.xforever.xin/desktop/authorize?request=req-1","expiresIn":600,"interval":2}
    """

private func client(_ transport: HttpTransport) -> AccountLoginClient {
    AccountLoginClient(siteBase: "https://vibex.xforever.xin/", transport: transport, sleep: { _ in })
}

@Test func passwordLoginPostsPasswordMode() async throws {
    let transport = RecordingTransport([(200, "{}")])
    try await client(transport).signIn(.password(login: "me@example.com", password: "secret-pass"))
    let request = try #require(transport.requests.first)
    #expect(request.url == "https://vibex.xforever.xin/api/auth/login")
    #expect(request.headers["content-type"] == "application/json")
    #expect(request.json as? [String: String] == ["mode": "password", "login": "me@example.com", "password": "secret-pass"])
}

@Test func codeLoginPostsCodeMode() async throws {
    let transport = RecordingTransport([(200, "{}")])
    try await client(transport).signIn(.code(login: "13800000000", code: "123456"))
    #expect(transport.requests.first?.json as? [String: String] == ["mode": "code", "login": "13800000000", "code": "123456"])
}

@Test func sendLoginCodeTargetsLoginPurpose() async throws {
    let transport = RecordingTransport([(200, "{}")])
    try await client(transport).sendLoginCode(to: "me@example.com")
    let request = try #require(transport.requests.first)
    #expect(request.url == "https://vibex.xforever.xin/api/auth/code")
    #expect(request.json as? [String: String] == ["target": "me@example.com", "purpose": "login"])
}

@Test func sendLoginCodeReportsCooldownWithRetryAfter() async throws {
    let transport = RecordingTransport([(429, #"{"error":"cooldown","retryAfter":42}"#)])
    await #expect(throws: AccountAuthError(code: "cooldown", retryAfter: 42)) {
        try await client(transport).sendLoginCode(to: "me@example.com")
    }
}

@Test func sessionLoginApprovesAndRedeemsDeviceToken() async throws {
    let transport = RecordingTransport([
        (200, deviceLoginJSON),
        (200, #"{"ok":true}"#),
        (200, #"{"status":"pending"}"#),
        (200, #"{"status":"approved","token":"bearer-1"}"#),
    ])
    let api = client(transport)
    let login = try await api.startDeviceLogin(deviceName: "iPhone")
    try await api.approve(login)
    let token = try await api.approvedToken(for: login, maxAttempts: 5)
    #expect(token == "bearer-1")
    let requests = transport.requests
    #expect(
        requests.map(\.url) == [
            "https://vibex.xforever.xin/api/auth/desktop/start",
            "https://vibex.xforever.xin/api/auth/desktop/decide",
            "https://vibex.xforever.xin/api/auth/desktop/token",
            "https://vibex.xforever.xin/api/auth/desktop/token",
        ])
    #expect(requests[0].json as? [String: String] == ["deviceName": "iPhone", "hostId": "", "nextPath": "/account"])
    #expect(requests[1].json["requestId"] as? String == "req-1")
    #expect(requests[1].json["approve"] as? Bool == true)
    #expect(requests[1].json.count == 2)
    #expect(requests[2].json as? [String: String] == ["requestId": "req-1", "verifier": "ver-1"])
}

@Test func oauthStartLandsOnTheAuthorizePage() throws {
    let login = try JSONDecoder().decode(AccountDeviceLogin.self, from: Data(deviceLoginJSON.utf8))
    let url = client(RecordingTransport([])).oauthStartURL(.github, for: login)
    #expect(
        url?.absoluteString
            == "https://vibex.xforever.xin/api/auth/oauth/github/start?next=%2Fdesktop%2Fauthorize%3Frequest%3Dreq-1"
    )
}

@Test func siteErrorCodesMapToLoginMessages() {
    let cases: [(AccountAuthError, String)] = [
        (AccountAuthError(code: "credentials"), "账号或密码错误"),
        (AccountAuthError(code: "suspended"), "该账号已被停用"),
        (AccountAuthError(code: "banned"), "该账号已被封禁"),
        (AccountAuthError(code: "email_not_found"), "该邮箱尚未注册，请先注册"),
        (AccountAuthError(code: "phone_not_found"), "该手机号尚未注册，请先注册"),
        (AccountAuthError(code: "rate"), "尝试次数过多，请稍后再试"),
        (AccountAuthError(code: "cooldown"), "验证码发送过于频繁，请稍后再试"),
        (AccountAuthError(code: "delivery"), "验证码发送失败，请稍后再试"),
        (AccountAuthError(code: "oauth_state"), "登录超时，请重试"),
        (AccountAuthError(code: "oauth_denied"), "已取消授权"),
        (AccountAuthError(code: "oauth_failed"), "第三方登录失败，请重试"),
        (AccountAuthError(code: "invalid", fields: ["code"]), "验证码错误或已过期"),
        (AccountAuthError(code: "invalid", fields: ["target"]), "格式不正确"),
        (AccountAuthError(code: "invalid", fields: ["email"]), "格式不正确"),
        (AccountAuthError(code: "invalid", fields: ["phone"]), "格式不正确"),
        (AccountAuthError(code: "invalid", fields: ["password"]), "密码至少 8 位"),
        (AccountAuthError.network, "网络不可用，请重试"),
        (AccountAuthError(code: "http_500"), "登录失败，请重试"),
    ]
    for (error, message) in cases {
        #expect(error.message == message)
    }
}

@Test func unreachableSiteIsANetworkError() async throws {
    struct Offline: HttpTransport {
        func execute(method: String, url: String, headers: [String: String], body: Data?) async throws -> HttpExchange {
            throw URLError(.notConnectedToInternet)
        }
    }
    await #expect(throws: AccountAuthError.network) {
        try await client(Offline()).signIn(.password(login: "me", password: "secret-pass"))
    }
}
