import Foundation
import Testing
@testable import CompanionCore

private final class ScriptedTransport: HttpTransport, @unchecked Sendable {
    struct Recorded {
        let method: String
        let url: String
        let headers: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var responses: [HttpExchange]
    private(set) var requests: [Recorded] = []

    init(_ responses: [String], statuses: [Int]) {
        self.responses = zip(statuses, responses).map {
            HttpExchange(status: $0, body: Data($1.utf8))
        }
    }

    func execute(
        method: String, url: String, headers: [String: String], body: Data?
    ) async throws -> HttpExchange {
        lock.withLock {
            requests.append(Recorded(method: method, url: url, headers: headers, body: body))
            return responses.removeFirst()
        }
    }
}

private let credentialJSON = """
{"device_id":"11111111-1111-1111-1111-111111111111","access_token":"device-token","scopes":["conversation.read","conversation.attach"]}
"""
private let capabilitiesJSON = """
{"server_version":"0.1.3","protocol_version":"1.0","minimum_client_version":"1.0","capabilities":["conversation.attach"]}
"""

@Test func redeemStoresCompanionCredentialAndChecksCapabilities() async throws {
    let transport = ScriptedTransport([credentialJSON, capabilitiesJSON], statuses: [201, 200])
    let session = try await PairingClient(transport: transport).redeem(
        origin: HostOrigin.parse("http://127.0.0.1:17891"),
        pairingToken: "one-time-secret",
        deviceName: "iPhone"
    )
    #expect(session.credential.access_token == "device-token")
    #expect(session.capabilities.protocol_version == "1.0")
    #expect(transport.requests.count == 2)
    #expect(transport.requests[0].method == "POST")
    #expect(transport.requests[0].url.hasSuffix("/api/v1/auth/pairings/redeem"))
    let sent = try #require(transport.requests[0].body.flatMap { String(data: $0, encoding: .utf8) })
    #expect(sent.contains("\"pairing_token\":\"one-time-secret\""))
    #expect(transport.requests[1].headers["authorization"] == "Bearer device-token")
}

@Test func redeemRejectsHostAdminScopes() async throws {
    let granted = """
    {"device_id":"11111111-1111-1111-1111-111111111111","access_token":"t","scopes":["conversation.read","host.admin"]}
    """
    let transport = ScriptedTransport([granted], statuses: [201])
    await #expect(throws: PairingError.nonCompanionScopes(["host.admin"])) {
        try await PairingClient(transport: transport).redeem(
            origin: HostOrigin.parse("https://host.example"),
            pairingToken: "token"
        )
    }
}

@Test func redeemRejectsIncompatibleProtocolMajor() async throws {
    let newer = """
    {"server_version":"9","protocol_version":"2.0","minimum_client_version":"2.0","capabilities":[]}
    """
    let transport = ScriptedTransport([credentialJSON, newer], statuses: [201, 200])
    await #expect(throws: PairingError.incompatibleProtocol(host: "2.0", client: "1.0")) {
        try await PairingClient(transport: transport).redeem(
            origin: HostOrigin.parse("https://host.example"),
            pairingToken: "token"
        )
    }
}

@Test func hostOriginRejectsCredentialsInUrl() {
    #expect(throws: PairingError.self) {
        try HostOrigin.parse("http://user:secret@127.0.0.1:17891")
    }
}

@Test func hostOriginNormalizesTrailingSlash() throws {
    let origin = try HostOrigin.parse(" https://host.example:8443/base/ ")
    #expect(origin.value == "https://host.example:8443/base")
    #expect(origin.resolve("api/v1/capabilities") == "https://host.example:8443/base/api/v1/capabilities")
}

private func invitationText(
    preset: String = "companion",
    expiresAt: String = "2999-01-01T00:00:00Z",
    hostId: String = "h",
    origins: [String]
) -> String {
    let reach = origins.map { "{\"origin\":\"\($0)\",\"kind\":\"lan\"}" }.joined(separator: ",")
    return "vibex-pairing:{\"version\":1,\"host_id\":\"\(hostId)\",\"preset\":\"\(preset)\",\"expires_at\":\"\(expiresAt)\",\"pairing_id\":\"p\",\"pairing_token\":\"secret\",\"reachability\":[\(reach)]}"
}

private final class FlakyTransport: HttpTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [String] = []
    func execute(
        method: String, url: String, headers: [String: String], body: Data?
    ) async throws -> HttpExchange {
        let step = lock.withLock { () -> Int in
            urls.append(url)
            return urls.count
        }
        if step == 1 { throw URLError(.cannotConnectToHost) }
        let text = step == 2 ? credentialJSON : capabilitiesJSON
        return HttpExchange(status: 200, body: Data(text.utf8))
    }
}

@Test func invitationRejectsUnknownPresetBeforeAnyRequest() async throws {
    let transport = ScriptedTransport([], statuses: [])
    let invitation = try PairingInvitation.parse(
        invitationText(preset: "admin", origins: ["http://192.168.1.2:17891"])
    )
    await #expect(throws: PairingError.notCompanionInvitation) {
        try await PairingClient(transport: transport).redeem(invitation: invitation)
    }
    #expect(transport.requests.isEmpty)
}

@Test func invitationRejectsExpired() async throws {
    let invitation = try PairingInvitation.parse(
        invitationText(expiresAt: "2000-01-01T00:00:00Z", origins: ["http://192.168.1.2:17891"])
    )
    await #expect(throws: PairingError.invitationExpired) {
        try await PairingClient(transport: ScriptedTransport([], statuses: [])).redeem(
            invitation: invitation
        )
    }
}

@Test func invitationFallsBackToNextOriginAndSkipsLoopback() async throws {
    let transport = FlakyTransport()
    let invitation = try PairingInvitation.parse(
        invitationText(origins: [
            "http://127.0.0.1:17891", "http://192.168.1.2:17891", "http://192.168.1.3:17891",
        ])
    )
    let session = try await PairingClient(transport: transport).redeem(invitation: invitation)
    #expect(session.origin.value == "http://192.168.1.3:17891")
    #expect(transport.urls.first?.hasPrefix("http://192.168.1.2") == true)
}

private struct OfflineTransport: HttpTransport {
    func execute(
        method: String, url: String, headers: [String: String], body: Data?
    ) async throws -> HttpExchange {
        throw URLError(.timedOut)
    }
}

@Test func lanOnlyInvitationThatNobodyAnswersSaysTheCloudServiceIsOff() async throws {
    let invitation = try PairingInvitation.parse(
        invitationText(hostId: "", origins: ["http://127.0.0.1:17891", "http://192.168.1.2:17891", "http://10.0.0.5:17891"])
    )
    #expect(invitation.offersOnlyLocalOrigins)
    await #expect(throws: PairingError.hostCloudServiceOff) {
        try await PairingClient(transport: OfflineTransport()).redeem(invitation: invitation)
    }
}

@Test func invitationWithACloudOriginStaysGenericallyUnreachable() async throws {
    let invitation = try PairingInvitation.parse(
        invitationText(hostId: "", origins: ["http://192.168.1.2:17891", "https://vibex.xforever.xin/t/host-1"])
    )
    #expect(!invitation.offersOnlyLocalOrigins)
    await #expect(throws: PairingError.unreachable) {
        try await PairingClient(transport: OfflineTransport()).redeem(invitation: invitation)
    }
}

@Test func invitationParseRejectsGarbage() {
    #expect(throws: PairingError.invalidInvitation) { try PairingInvitation.parse("K7M2NPQX") }
    #expect(throws: PairingError.invalidInvitation) { try PairingInvitation.parse("vibex-pairing:{") }
}

@Test func redeemExplainsWhyTheHostRejectedTheCode() async throws {
    func body(_ reason: String) -> String {
        "{\"code\":\"conflict\",\"message\":\"x\",\"retryable\":false,\"operation_id\":\"o\",\"details\":{\"reason\":\"\(reason)\"}}"
    }
    for (reason, status, expected) in [
        ("pairing_redeemed", 409, PairingError.codeAlreadyUsed),
        ("pairing_expired", 409, PairingError.codeExpired),
        ("invalid_pairing", 401, PairingError.codeInvalid),
    ] {
        let transport = ScriptedTransport([body(reason)], statuses: [status])
        await #expect(throws: expected) {
            try await PairingClient(transport: transport).redeem(
                origin: HostOrigin.parse("http://127.0.0.1:17891"),
                pairingToken: "YGFQX9R2"
            )
        }
    }
    let unknown = ScriptedTransport(["oops"], statuses: [500])
    await #expect(throws: PairingError.redeemFailed(500)) {
        try await PairingClient(transport: unknown).redeem(
            origin: HostOrigin.parse("http://127.0.0.1:17891"),
            pairingToken: "x"
        )
    }
}

@Test func requestConnectAndPollConnectRoundTrip() async throws {
    let pendingJSON = """
    {"request_id":"req-123","host_id":"host-abc","host_name":"ltfdeMacBook-Pro.local","sas_code":"5890","status":"pending"}
    """
    let approvedJSON = """
    {"request_id":"req-123","host_id":"host-abc","host_name":"ltfdeMacBook-Pro.local","sas_code":"5890","status":"approved","credential":\(credentialJSON)}
    """
    let transport = ScriptedTransport([pendingJSON, approvedJSON], statuses: [201, 200])
    let client = PairingClient(transport: transport)
    let origin = try HostOrigin.parse("https://relay.example.com/t/host-abc")

    let requested = try await client.requestConnect(origin: origin, deviceName: "iPhone")
    #expect(requested.requestId == "req-123")
    #expect(requested.sasCode == "5890")
    #expect(requested.status == "pending")
    #expect(requested.credential == nil)

    let polled = try await client.pollConnect(origin: origin, requestId: requested.requestId)
    #expect(polled.status == "approved")
    #expect(polled.credential?.access_token == "device-token")

    let host = DiscoveredLanHost(origin: origin.value, hostId: "host-abc", name: "ltfdeMacBook-Pro.local")
    #expect(host.isCloudService == true)
    #expect(host.displayName == "ltfdeMacBook-Pro")
}

@Test func e2eeHandshakeAndEncryptionRoundTrip() throws {
    let clientA = E2eeSessionManager()
    let clientB = E2eeSessionManager()
    let origin = "https://relay.example.com/t/host-e2ee-test"

    let sessionA = clientA.ingestHandshake(
        originOrUrl: origin,
        sessionId: "sess-01",
        serverPubBase64: clientB.clientPublicKeyBase64
    )
    let sessionB = clientB.ingestHandshake(
        originOrUrl: origin,
        sessionId: "sess-01",
        serverPubBase64: clientA.clientPublicKeyBase64
    )
    #expect(sessionA != nil)
    #expect(sessionB != nil)

    let plaintext = Data("{\"prompt\":\"end-to-end encrypted message\"}".utf8)
    let encryptedReq = try clientA.encryptRequestBody(plaintext, session: sessionA!)
    let decryptedByB = try E2eeSessionManager.decrypt(
        key: sessionB!.symmetricKey,
        aad: Data("vibex-e2ee-req-v1".utf8),
        base64Payload: encryptedReq
    )
    #expect(decryptedByB == plaintext)
}



private let pendingConnectJSON = "{\"request_id\":\"req-1\",\"host_id\":\"h1\",\"sas_code\":\"1234\",\"status\":\"pending\"}"

@Test func requestConnectSendsAccountTokenOnlyWhenPresent() async throws {
    let transport = ScriptedTransport([pendingConnectJSON, pendingConnectJSON, pendingConnectJSON], statuses: [201, 201, 201])
    let client = PairingClient(transport: transport)
    let origin = try HostOrigin.parse("https://relay.example.com/t/h1")

    _ = try await client.requestConnect(origin: origin, deviceName: "iPhone", accountToken: "acct-token")
    _ = try await client.requestConnect(origin: origin, deviceName: "iPhone")
    _ = try await client.requestConnect(origin: origin, deviceName: "iPhone", accountToken: "  ")

    func sentBody(_ index: Int) throws -> [String: Any] {
        let data = try #require(transport.requests[index].body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    let withToken = try sentBody(0)
    #expect(withToken["account_token"] as? String == "acct-token")
    #expect(withToken["client_kind"] as? String == "mobile")
    #expect(withToken["replace_existing_mobile"] as? Bool == false)
    #expect(try sentBody(1)["account_token"] == nil)
    #expect(try sentBody(2)["account_token"] == nil)
}

@Test func requestConnectMapsAccountVerificationFailures() async throws {
    func body(_ reason: String, extra: String = "") -> String {
        "{\"code\":\"x\",\"message\":\"x\",\"retryable\":false,\"operation_id\":\"o\",\"details\":{\"reason\":\"\(reason)\"\(extra)}}"
    }
    let cases: [(String, Int, PairingError)] = [
        (body("account_mismatch"), 403, .accountMismatch),
        (body("account_token_invalid"), 401, .accountTokenInvalid),
        (body("host_account_signed_out"), 409, .hostAccountSignedOut),
        (body("account_verification_unavailable"), 503, .accountVerificationUnavailable),
        (body("mobile_device_conflict", extra: ",\"existing_device_name\":\"Old iPhone\""), 409, .mobileDeviceConflict(existingDeviceName: "Old iPhone")),
    ]
    for (payload, status, expected) in cases {
        let transport = ScriptedTransport([payload], statuses: [status])
        await #expect(throws: expected) {
            try await PairingClient(transport: transport).requestConnect(
                origin: HostOrigin.parse("http://192.168.1.2:17891"),
                accountToken: "acct-token"
            )
        }
    }
}

@Test func requestConnectReportsAnOfflineDesktopBehindTheRelay() async throws {
    for status in [502, 503, 504] {
 let transport = ScriptedTransport([""], statuses: [status])
 await #expect(throws: PairingError.unreachable) {
     try await PairingClient(transport: transport).requestConnect(
  origin: HostOrigin.parse("https://vibex.xforever.xin/t/host-1"),
  accountToken: "acct-token"
     )
 }
    }
}

@Test func awaitConnectApprovalReportsDesktopDecision() async throws {
    let origin = try HostOrigin.parse("http://192.168.1.2:17891")
    func poll(_ status: String) -> String {
        "{\"request_id\":\"req-1\",\"host_id\":\"h1\",\"sas_code\":\"1234\",\"status\":\"\(status)\"}"
    }
    let approved = "{\"request_id\":\"req-1\",\"host_id\":\"h1\",\"sas_code\":\"1234\",\"status\":\"approved\",\"credential\":\(credentialJSON)}"
    let approving = ScriptedTransport([poll("pending"), "oops", approved], statuses: [200, 500, 200])
    let result = try await PairingClient(transport: approving)
        .awaitConnectApproval(origin: origin, requestId: "req-1", pollInterval: .milliseconds(1))
    #expect(result.credential?.access_token == "device-token")

    for (status, expected) in [("rejected", PairingError.connectRejected), ("expired", PairingError.connectExpired)] {
        let transport = ScriptedTransport([poll(status)], statuses: [200])
        await #expect(throws: expected) {
            try await PairingClient(transport: transport)
                .awaitConnectApproval(origin: origin, requestId: "req-1", pollInterval: .milliseconds(1))
        }
    }
}
