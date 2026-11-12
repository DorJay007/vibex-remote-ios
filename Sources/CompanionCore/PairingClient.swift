import CryptoKit
import Darwin
import Foundation

public struct HttpExchange: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol HttpTransport: Sendable {
    func execute(
        method: String,
        url: String,
        headers: [String: String],
        body: Data?
    ) async throws -> HttpExchange
}

public struct DiscoveredLanHost: Identifiable, Equatable, Sendable {
    public let origin: String
    public let hostId: String?
    public let name: String

    public var id: String { hostId ?? origin }

    public var isCloudService: Bool {
        let lower = origin.lowercased()
        return lower.contains("/t/") || lower.hasPrefix("https://")
    }

    public var displayName: String {
        let cleaned = name.replacingOccurrences(of: ".local", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "VibeX 桌面端" : cleaned
    }

    public init(origin: String, hostId: String?, name: String) {
        self.origin = origin
        self.hostId = hostId
        self.name = name
    }
}

public struct DeviceConnectRequestResult {
    public let requestId: String
    public let hostId: String
    public let hostName: String?
    public let sasCode: String
    public let status: String
    public let credential: DeviceCredential?

    public init(
        requestId: String,
        hostId: String,
        hostName: String?,
        sasCode: String,
        status: String,
        credential: DeviceCredential?
    ) {
        self.requestId = requestId
        self.hostId = hostId
        self.hostName = hostName
        self.sasCode = sasCode
        self.status = status
        self.credential = credential
    }
}

public enum PairingError: Error, Equatable, LocalizedError {
    case invalidOrigin(String)
    case missingInput(String)
    case redeemFailed(Int)
    case codeAlreadyUsed
    case codeExpired
    case codeInvalid
    case nonCompanionScopes([String])
    case capabilitiesFailed(Int)
    case incompatibleProtocol(host: String, client: String)
    case invalidInvitation
    case notCompanionInvitation
    case invitationExpired
    case mobileDeviceConflict(existingDeviceName: String)
    case unreachable
    /// Every origin in the invitation is on the Host's LAN and none answered.
    case hostCloudServiceOff
    case accountMismatch
    case accountTokenInvalid
    case hostAccountSignedOut
    case accountVerificationUnavailable
    case connectRejected
    case connectExpired

    public var errorDescription: String? {
        switch self {
        case .invalidOrigin(let message), .missingInput(let message):
            return message
        case .redeemFailed(let status):
            return "配对失败（\(status)）"
        case .codeAlreadyUsed:
            return "连接码已被使用，请在电脑上重新生成"
        case .codeExpired:
            return "连接码已过期，请在电脑上重新生成"
        case .codeInvalid:
            return "连接码不正确，请检查后重试"
        case .nonCompanionScopes(let scopes):
            return "Host granted non-companion scopes: \(scopes.joined(separator: ", "))"
        case .capabilitiesFailed(let status):
            return "电脑状态校验失败（\(status)）"
        case .incompatibleProtocol(let host, let client):
            return "协议版本不兼容（电脑 \(host)，手机 \(client)）"
        case .invalidInvitation:
            return "无法识别连接码"
        case .notCompanionInvitation:
            return "此连接码不是手机用的。在电脑上将“连接设备”选为“手机”后重新生成"
        case .invitationExpired:
            return "连接码已过期，请在电脑上重新生成"
        case .mobileDeviceConflict(let existingDeviceName):
            return "该电脑已连接移动设备「\(existingDeviceName)」，同一台电脑仅支持一台手机远程连接"
        case .unreachable:
            return "无法连接到电脑，请确认电脑端在线并已开启远程连接"
        case .hostCloudServiceOff:
            return "电脑未开启云服务。请连接与电脑相同的 Wi-Fi，或在电脑上登录 VibeX 账号"
        case .accountMismatch:
            return "这台电脑登录的是其他 VibeX 账号"
        case .accountTokenInvalid:
            return "登录状态已失效，请重新登录"
        case .hostAccountSignedOut:
            return "这台电脑未登录 VibeX 账号"
        case .accountVerificationUnavailable:
            return "暂时无法验证账号，请稍后重试"
        case .connectRejected:
            return "电脑端已拒绝连接"
        case .connectExpired:
            return "确认超时，请重试"
        }
    }
}

public struct CompanionSession {
    public let origin: HostOrigin
    public let credential: DeviceCredential
    public let capabilities: ServerCapabilities
}

private final class RelayBaseRegistry: @unchecked Sendable {
    static let shared = RelayBaseRegistry()
    private let lock = NSLock()
    private var bases: [String] = {
        let initial = PairingClient.defaultOfficialRelayBase.trimmingCharacters(in: .whitespacesAndNewlines)
        return initial.isEmpty ? [] : [initial]
    }()
    private var lastConflictOriginValue: String?

    func setConflictOrigin(_ origin: String?) {
        lock.lock()
        defer { lock.unlock() }
        lastConflictOriginValue = origin
    }

    func consumeConflictOrigin() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let value = lastConflictOriginValue
        lastConflictOriginValue = nil
        return value
    }

    func remember(_ originOrBaseUrl: String) {
        var trimmed = originOrBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") else {
            return
        }
        let base: String
        if let range = trimmed.range(of: "/t/") {
            base = String(trimmed[..<range.lowerBound])
        } else {
            guard let comps = URLComponents(string: trimmed),
                  let scheme = comps.scheme,
                  let host = comps.host,
                  !host.isEmpty
            else { return }
            let port = comps.port.map { ":\($0)" } ?? ""
            base = "\(scheme)://\(host)\(port)"
        }
        guard !base.isEmpty,
              !base.contains("127.0.0.1"),
              !base.contains("localhost"),
              !base.contains(":17890")
        else { return }
        lock.lock()
        defer { lock.unlock() }
        if !bases.contains(base) {
            bases.append(base)
        }
    }

    func all(extraOrigins: [String]) -> [String] {
        for origin in extraOrigins where origin.contains("/t/") {
            remember(origin)
        }
        lock.lock()
        defer { lock.unlock() }
        return bases
    }
}

public struct PairingClient: Sendable {
    public static let clientProtocolVersion = "1.0"
    public static let protocolHeader = "x-vibex-protocol-version"
    public static var defaultOfficialRelayBase: String {
        if let env = ProcessInfo.processInfo.environment["VIBEX_RELAY_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty
        {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "VIBEXRelayURL") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "https://vibex.xforever.xin"
    }

    private let transport: HttpTransport
    private let protocolVersion: String

    public init(
        transport: HttpTransport = URLSessionTransport(),
        protocolVersion: String = PairingClient.clientProtocolVersion
    ) {
        self.transport = transport
        self.protocolVersion = protocolVersion
    }

    public func redeem(
        origin: HostOrigin,
        pairingToken: String,
        deviceName: String = "iOS Companion",
        replaceExistingMobile: Bool = false
    ) async throws -> CompanionSession {
        let token = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw PairingError.missingInput("请输入连接码") }
        guard !name.isEmpty else { throw PairingError.missingInput("设备名称不能为空") }

        let body = try JSONSerialization.data(
            withJSONObject: [
                "pairing_token": token,
                "device_name": name,
                "client_kind": "mobile",
                "replace_existing_mobile": replaceExistingMobile,
            ] as [String: Any]
        )
        let redeem = try await transport.execute(
            method: "POST",
            url: origin.resolve("/api/v1/auth/pairings/redeem"),
            headers: [
                "content-type": "application/json",
                Self.protocolHeader: protocolVersion,
            ],
            body: body
        )
        guard (200...299).contains(redeem.status) else {
            let err = Self.redeemError(status: redeem.status, body: redeem.body)
            if case .mobileDeviceConflict = err {
                RelayBaseRegistry.shared.setConflictOrigin(origin.value)
            }
            throw err
        }
        let credential = try JSONDecoder().decode(DeviceCredential.self, from: redeem.body)
        let extras = CompanionScopes.extras(credential.scopes)
        guard extras.isEmpty else {
            throw PairingError.nonCompanionScopes(extras.sorted())
        }

        let response = try await transport.execute(
            method: "GET",
            url: origin.resolve("/api/v1/capabilities"),
            headers: [
                "authorization": "Bearer \(credential.access_token)",
                Self.protocolHeader: protocolVersion,
            ],
            body: nil
        )
        guard (200...299).contains(response.status) else {
            throw PairingError.capabilitiesFailed(response.status)
        }
        let capabilities = try JSONDecoder().decode(ServerCapabilities.self, from: response.body)
        guard Self.major(capabilities.protocol_version) == Self.major(protocolVersion) else {
            throw PairingError.incompatibleProtocol(
                host: capabilities.protocol_version,
                client: protocolVersion
            )
        }
        if origin.value.contains("/t/") {
            Self.rememberRelayBase(origin.value)
        }
        return CompanionSession(origin: origin, credential: credential, capabilities: capabilities)
    }

    public func redeem(
        invitation: PairingInvitation,
        deviceName: String = "iOS Companion",
        replaceExistingMobile: Bool = false,
        now: Date = Date()
    ) async throws -> CompanionSession {
        let preset = invitation.preset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard preset.isEmpty || preset == PairingInvitation.companionPreset || preset == "workstation" else {
            throw PairingError.notCompanionInvitation
        }
        if let expiry = invitation.expiresAtDate, expiry <= now {
            throw PairingError.invitationExpired
        }
        var origins = invitation.candidateOrigins
        let cleanHostId = invitation.host_id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanHostId.isEmpty, !cleanHostId.hasPrefix("host:") {
            for base in Self.knownRelayBases() {
                var cleanBase = base
                while cleanBase.hasSuffix("/") { cleanBase.removeLast() }
                if let relayOrigin = try? HostOrigin.parse("\(cleanBase)/t/\(cleanHostId)"),
                   !origins.contains(relayOrigin)
                {
                    origins.append(relayOrigin)
                }
            }
        }
        if transport is URLSessionTransport {
            let localSubnets = Self.localPrivateIPv4Subnets()
            if localSubnets.isEmpty {
                // On 5G cellular (no Wi-Fi interface), private LAN IPs are guaranteed unreachable: try cloud origins first!
                origins = origins.filter(\.isCloud) + origins.filter { !$0.isCloud }
            }
        }
        let unreachable: PairingError = invitation.offersOnlyLocalOrigins ? .hostCloudServiceOff : .unreachable
        guard !origins.isEmpty else { throw unreachable }
        for origin in origins {
            do {
                return try await redeem(
                    origin: origin,
                    pairingToken: invitation.pairing_token,
                    deviceName: deviceName,
                    replaceExistingMobile: replaceExistingMobile
                )
            } catch let error as PairingError {
                switch error {
                case .codeAlreadyUsed, .codeExpired, .codeInvalid, .notCompanionInvitation,
                    .incompatibleProtocol, .mobileDeviceConflict:
                    throw error
                default:
                    continue
                }
            } catch {
                continue
            }
        }
        if !cleanHostId.isEmpty {
            let fallbackRendezvous = await Self.resolveHostRendezvous(hostId: cleanHostId)
            for raw in fallbackRendezvous {
                guard let fallbackOrigin = try? HostOrigin.parse(raw),
                      !origins.contains(fallbackOrigin)
                else { continue }
                do {
                    return try await redeem(
                        origin: fallbackOrigin,
                        pairingToken: invitation.pairing_token,
                        deviceName: deviceName,
                        replaceExistingMobile: replaceExistingMobile
                    )
                } catch let error as PairingError {
                    switch error {
                    case .codeAlreadyUsed, .codeExpired, .codeInvalid, .notCompanionInvitation,
                        .incompatibleProtocol, .mobileDeviceConflict:
                        throw error
                    default:
                        continue
                    }
                } catch {
                    continue
                }
            }
        }
        throw unreachable
    }

    /// `accountToken` asks the Host to verify that this phone and the desktop share one VibeX account.
    public func requestConnect(
        origin: HostOrigin,
        deviceName: String = "iOS Companion",
        replaceExistingMobile: Bool = false,
        accountToken: String? = nil
    ) async throws -> DeviceConnectRequestResult {
        let cleanName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: Any] = [
            "device_name": cleanName.isEmpty ? "iOS Companion" : cleanName,
            "client_kind": "mobile",
            "replace_existing_mobile": replaceExistingMobile,
        ]
        if let token = accountToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            payload["account_token"] = token
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let exchange = try await transport.execute(
            method: "POST",
            url: origin.resolve("/api/v1/auth/connect-requests"),
            headers: [
                "content-type": "application/json",
                Self.protocolHeader: protocolVersion,
            ],
            body: body
        )
        guard (200...299).contains(exchange.status) else {
            throw Self.redeemError(status: exchange.status, body: exchange.body)
        }
        return try Self.parseConnectRequestResult(exchange.body)
    }

    public func pollConnect(
        origin: HostOrigin,
        requestId: String
    ) async throws -> DeviceConnectRequestResult {
        let trimmedId = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        let exchange = try await transport.execute(
            method: "GET",
            url: origin.resolve("/api/v1/auth/connect-requests/\(trimmedId)"),
            headers: [Self.protocolHeader: protocolVersion],
            body: nil
        )
        guard (200...299).contains(exchange.status) else {
     throw Self.redeemError(status: exchange.status, body: exchange.body)
        }
 return try Self.parseConnectRequestResult(exchange.body)
    }

    /// Polls until the desktop user answers; transient poll failures are retried until the Host reports expiry.
    public func awaitConnectApproval(
        origin: HostOrigin,
        requestId: String,
        pollInterval: Duration = .milliseconds(1500)
    ) async throws -> DeviceConnectRequestResult {
        while true {
            try await Task.sleep(for: pollInterval)
            guard let poll = try? await pollConnect(origin: origin, requestId: requestId) else { continue }
            switch poll.status {
            case "approved" where poll.credential != nil:
                return poll
            case "rejected":
                throw PairingError.connectRejected
            case "expired":
                throw PairingError.connectExpired
            default:
                continue
            }
        }
    }

    private static func parseConnectRequestResult(_ data: Data) throws -> DeviceConnectRequestResult {
        struct WireResponse: Decodable {
            let request_id: String
            let host_id: String?
            let host_name: String?
            let sas_code: String
            let status: String
            let credential: DeviceCredential?
        }
        let decoded = try JSONDecoder().decode(WireResponse.self, from: data)
        return DeviceConnectRequestResult(
            requestId: decoded.request_id,
            hostId: decoded.host_id ?? "",
            hostName: decoded.host_name,
            sasCode: decoded.sas_code,
            status: decoded.status,
            credential: decoded.credential
        )
    }

    // MARK: - LAN & Cloud Service Discovery

    public static func consumeLastConflictOrigin() -> String? {
        RelayBaseRegistry.shared.consumeConflictOrigin()
    }

    public static func rememberRelayBase(_ originOrBaseUrl: String) {
        RelayBaseRegistry.shared.remember(originOrBaseUrl)
    }

    public static func knownRelayBases(extraOrigins: [String] = []) -> [String] {
        RelayBaseRegistry.shared.all(extraOrigins: extraOrigins)
    }

    public static func probeHostHealth(
        originUrl: String,
        timeoutSeconds: TimeInterval = 0.45,
        expectedHostId: String? = nil
    ) async -> (host: DiscoveredLanHost, rttMs: Int)? {
        guard let origin = try? HostOrigin.parse(originUrl),
              let url = URL(string: origin.resolve("/health"))
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "GET"
        request.setValue(
            E2eeSessionManager.shared.clientPublicKeyBase64,
            forHTTPHeaderField: E2eeSessionManager.headerClientPub
        )
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsedMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode)
            else { return nil }

            E2eeSessionManager.shared.ingestHandshakeHeaders(originOrUrl: origin.value, response: http)

            if let expected = expectedHostId, !expected.isEmpty,
               let routed = http.value(forHTTPHeaderField: "x-vibex-routed-host-id")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !routed.isEmpty, routed != expected
            {
                return nil
            }

            struct HealthPayload: Decodable {
                let status: String?
                let host_id: String?
                let name: String?
            }
            guard let payload = try? JSONDecoder().decode(HealthPayload.self, from: data),
                  payload.status == "ok"
            else { return nil }

            if let expected = expectedHostId, !expected.isEmpty,
               let actual = payload.host_id, !actual.isEmpty, actual != expected
            {
                return nil
            }

            if origin.value.contains("/t/") {
                rememberRelayBase(origin.value)
            }
            let fallbackName = origin.value
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
            let host = DiscoveredLanHost(
                origin: origin.value,
                hostId: payload.host_id,
                name: payload.name ?? fallbackName
            )
            return (host, elapsedMs)
        } catch {
            return nil
        }
    }

    public static func discoverLanHosts(port: Int = 17891) async -> [DiscoveredLanHost] {
        var candidates: [String] = []
        var seenCandidates = Set<String>()
        func addCandidate(_ url: String) {
            if seenCandidates.insert(url).inserted {
                candidates.append(url)
            }
        }

        let localPorts = Array(NSOrderedSet(array: [port, 17899] + Array(17891...17899))) as? [Int] ?? [port]
        for localPort in localPorts {
            addCandidate("http://127.0.0.1:\(localPort)")
        }

        let lanPorts = port == 17899 ? [17899] : [port, 17899]
        for (prefix, selfHost) in localPrivateIPv4Subnets() {
            for lanPort in lanPorts {
                for host in 1...254 where host != selfHost {
                    addCandidate("http://\(prefix).\(host):\(lanPort)")
                }
            }
        }

        return await withTaskGroup(of: DiscoveredLanHost?.self) { group -> [DiscoveredLanHost] in
            let maxConcurrency = 48
            var index = 0
            while index < min(maxConcurrency, candidates.count) {
                let candidate = candidates[index]
                index += 1
                group.addTask {
                    await probeHostHealth(originUrl: candidate, timeoutSeconds: 0.32)?.host
                }
            }

            var results: [DiscoveredLanHost] = []
            for await item in group {
                if let item {
                    results.append(item)
                }
                if index < candidates.count {
                    let candidate = candidates[index]
                    index += 1
                    group.addTask {
                        await probeHostHealth(originUrl: candidate, timeoutSeconds: 0.32)?.host
                    }
                }
            }
            return deduplicateHosts(results)
        }
    }

    public static func resolvePairingCodeRendezvous(
        connectionCode: String,
        knownOrigins: [String] = [],
        timeoutSeconds: TimeInterval = 2.0
    ) async -> [String] {
        let cleanCode = connectionCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        guard cleanCode.count == 8 else { return [] }
        let bases = knownRelayBases(extraOrigins: knownOrigins)
        guard !bases.isEmpty else { return [] }

        let digest = SHA256.hash(data: Data("vibex-pair-code-v1:\(cleanCode)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let topic = "vbx-p-\(hex.prefix(32))"

        struct BeaconResponse: Decodable {
            struct Entry: Decodable {
                struct Payload: Decodable {
                    let host_id: String?
                    let origin: String?
                }
                let payload: Payload?
            }
            let entries: [Entry]?
        }

        var resolved: [String] = []
        func appendUnique(_ origin: String) {
            if !resolved.contains(origin) {
                resolved.append(origin)
            }
        }

        for base in bases {
            var cleanBase = base
            while cleanBase.hasSuffix("/") { cleanBase.removeLast() }
            guard let url = URL(string: "\(cleanBase)/v1/beacon/\(topic)") else { continue }
            var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
            request.httpMethod = "GET"
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let decoded = try? JSONDecoder().decode(BeaconResponse.self, from: data)
            else { continue }

            for entry in decoded.entries ?? [] {
                guard let payload = entry.payload else { continue }
                if let origin = payload.origin?.trimmingCharacters(in: .whitespacesAndNewlines),
                   origin.hasPrefix("http://") || origin.hasPrefix("https://")
                {
                    appendUnique(origin)
                }
                if let hostId = payload.host_id?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !hostId.isEmpty
                {
                    appendUnique("\(cleanBase)/t/\(hostId)")
                }
            }
        }
        return resolved
    }

    public static func resolveHostRendezvous(
        hostId: String,
        knownOrigins: [String] = [],
        timeoutSeconds: TimeInterval = 2.0
    ) async -> [String] {
        let cleanId = hostId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty, !cleanId.hasPrefix("host:") else { return [] }
        let bases = knownRelayBases(extraOrigins: knownOrigins)
        guard !bases.isEmpty else { return [] }

        var resolved: [String] = []
        func appendUnique(_ origin: String) {
            if !resolved.contains(origin) {
                resolved.append(origin)
            }
        }

        for base in bases {
            var cleanBase = base
            while cleanBase.hasSuffix("/") { cleanBase.removeLast() }
            appendUnique("\(cleanBase)/t/\(cleanId)")
        }

        let digest = SHA256.hash(data: Data("vibex-host-v1:\(cleanId)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let topic = "vbx-h-\(hex.prefix(32))"

        struct BeaconResponse: Decodable {
            struct Entry: Decodable {
                struct Payload: Decodable {
                    let host_id: String?
                    let origin: String?
                }
                let payload: Payload?
            }
            let entries: [Entry]?
        }

        for base in bases {
            var cleanBase = base
            while cleanBase.hasSuffix("/") { cleanBase.removeLast() }
            guard let url = URL(string: "\(cleanBase)/v1/beacon/\(topic)") else { continue }
            var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
            request.httpMethod = "GET"
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let decoded = try? JSONDecoder().decode(BeaconResponse.self, from: data)
            else { continue }

            for entry in decoded.entries ?? [] {
                guard let payload = entry.payload else { continue }
                if let recordHostId = payload.host_id, recordHostId != cleanId { continue }
                if let origin = payload.origin?.trimmingCharacters(in: .whitespacesAndNewlines),
                   origin.hasPrefix("http://") || origin.hasPrefix("https://")
                {
                    appendUnique(origin)
                }
            }
        }
        return resolved
    }

    private static func deduplicateHosts(_ hosts: [DiscoveredLanHost]) -> [DiscoveredLanHost] {
        var seen = Set<String>()
        var result: [DiscoveredLanHost] = []
        for host in hosts {
            let key = host.hostId ?? host.origin
            if seen.insert(key).inserted {
                result.append(host)
            }
        }
        return result
    }

    private static func localPrivateIPv4Subnets() -> [(prefix: String, selfHost: Int)] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var results: [(String, Int)] = []
        var seenPrefixes = Set<String>()
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: current.pointee.ifa_name).lowercased()
            if name.hasPrefix("utun")
                || name.hasPrefix("tun")
                || name.hasPrefix("tap")
                || name.hasPrefix("ppp")
                || name.hasPrefix("ipsec")
                || name.hasPrefix("pdp_ip")
                || name.hasPrefix("awdl")
                || name.hasPrefix("llw")
                || name.hasPrefix("anpi")
            {
                continue
            }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let ip = UInt32(bigEndian: sin.sin_addr.s_addr)
            let b0 = Int((ip >> 24) & 0xFF)
            let b1 = Int((ip >> 16) & 0xFF)
            let b2 = Int((ip >> 8) & 0xFF)
            let b3 = Int(ip & 0xFF)
            if b0 == 198 && (b1 == 18 || b1 == 19) { continue }
            let isPrivate = b0 == 10 || (b0 == 172 && (16...31).contains(b1)) || (b0 == 192 && b1 == 168)
            guard isPrivate else { continue }
            let prefix = "\(b0).\(b1).\(b2)"
            if seenPrefixes.insert(prefix).inserted {
                results.append((prefix, b3))
            }
        }
        return results
    }

    /// The Host explains a rejected code in `details.reason`; map it to something the user can act on.
    static func redeemError(status: Int, body: Data) -> PairingError {
        struct Failure: Decodable {
            struct Details: Decodable {
                let reason: String?
                let existing_device_name: String?
            }
            let details: Details?
        }
        let details = (try? JSONDecoder().decode(Failure.self, from: body))?.details
        switch details?.reason {
        case "pairing_redeemed": return .codeAlreadyUsed
        case "pairing_expired": return .codeExpired
        case "invalid_pairing": return .codeInvalid
        case "mobile_device_conflict":
            return .mobileDeviceConflict(existingDeviceName: details?.existing_device_name ?? "另一台手机")
        case "account_mismatch": return .accountMismatch
        case "account_token_invalid": return .accountTokenInvalid
        case "host_account_signed_out": return .hostAccountSignedOut
        case "account_verification_unavailable": return .accountVerificationUnavailable
        default:
     // A relay answers 502/503/504 without an error envelope when the desktop is offline.
     if [502, 503, 504].contains(status) { return .unreachable }
     return status == 401 ? .codeInvalid : .redeemFailed(status)
        }
    }

    static func major(_ version: String) -> Substring {
        version.split(separator: ".", maxSplits: 1).first ?? ""
    }
}

public struct URLSessionTransport: HttpTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(
        method: String,
        url: String,
        headers: [String: String],
        body: Data?
    ) async throws -> HttpExchange {
        let exchange = try await executeOnce(
            method: method,
            url: url,
            headers: headers,
            body: body,
            allowHandshakeBootstrap: true
        )
        if exchange.status == 412 {
            return try await executeOnce(
                method: method,
                url: url,
                headers: headers,
                body: body,
                allowHandshakeBootstrap: false
            )
        }
        return exchange
    }

    private func executeOnce(
        method: String,
        url: String,
        headers: [String: String],
        body: Data?,
        allowHandshakeBootstrap: Bool
    ) async throws -> HttpExchange {
        guard let target = URL(string: url) else {
            throw PairingError.invalidOrigin("无效的电脑连接地址")
        }
        let lower = url.lowercased()
        let isPrivateLan = lower.hasPrefix("http://192.168.")
            || lower.hasPrefix("http://10.")
            || lower.hasPrefix("http://172.")
            || lower.hasPrefix("http://127.")

        let e2ee = E2eeSessionManager.shared
        let originKey = E2eeSessionManager.originKey(from: url)
        if allowHandshakeBootstrap,
           e2ee.session(for: originKey) == nil,
           !lower.hasSuffix("/health"),
           !lower.hasSuffix("/api/v1/e2ee/handshake"),
           let handshakeUrl = URL(string: "\(originKey)/api/v1/e2ee/handshake")
        {
            var probe = URLRequest(url: handshakeUrl, timeoutInterval: isPrivateLan ? 0.85 : 3.5)
            probe.httpMethod = "GET"
            probe.setValue(e2ee.clientPublicKeyBase64, forHTTPHeaderField: E2eeSessionManager.headerClientPub)
            if let (_, probeResp) = try? await session.data(for: probe),
               let probeHttp = probeResp as? HTTPURLResponse
            {
                e2ee.ingestHandshakeHeaders(originOrUrl: originKey, response: probeHttp)
            }
        }

        var request = URLRequest(url: target, timeoutInterval: isPrivateLan ? 0.85 : 10)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(e2ee.clientPublicKeyBase64, forHTTPHeaderField: E2eeSessionManager.headerClientPub)

        let activeE2eeSession = e2ee.session(for: originKey)
        if let activeE2eeSession {
            request.setValue(E2eeSessionManager.version, forHTTPHeaderField: E2eeSessionManager.headerE2ee)
            request.setValue(activeE2eeSession.sessionId, forHTTPHeaderField: E2eeSessionManager.headerSession)
            if let authValue = request.value(forHTTPHeaderField: "authorization"),
               let encryptedAuth = try? e2ee.encryptAuthHeader(authValue, session: activeE2eeSession)
            {
                request.setValue(encryptedAuth, forHTTPHeaderField: E2eeSessionManager.headerAuth)
                request.setValue("Bearer e2ee", forHTTPHeaderField: "authorization")
            }
            if let body, !body.isEmpty,
               let encryptedBody = try? e2ee.encryptRequestBody(body, session: activeE2eeSession)
            {
                request.httpBody = encryptedBody
                request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "content-type")
            } else {
                request.httpBody = body
            }
        } else {
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return HttpExchange(status: 0, body: data)
        }
        let updatedSession = e2ee.ingestHandshakeHeaders(originOrUrl: originKey, response: http) ?? activeE2eeSession
        let respIsE2ee = http.value(forHTTPHeaderField: E2eeSessionManager.headerE2ee)?
            .lowercased() == E2eeSessionManager.version
        if respIsE2ee, !data.isEmpty, let updatedSession,
           let decrypted = try? e2ee.decryptResponseBody(data, session: updatedSession)
        {
            return HttpExchange(status: http.statusCode, body: decrypted)
        }
        return HttpExchange(status: http.statusCode, body: data)
    }
}
