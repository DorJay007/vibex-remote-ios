import CryptoKit
import Foundation

/// Manages End-to-End Encryption (E2EE v1: ECDHE-P256 + HKDF-SHA256 + AES-256-GCM)
/// between the iOS Companion client and a paired VibeX Host.
public final class E2eeSessionManager: @unchecked Sendable {
    public static let shared = E2eeSessionManager()

    public static let headerE2ee = "x-vibex-e2ee"
    public static let headerClientPub = "x-vibex-e2ee-client-pub"
    public static let headerServerPub = "x-vibex-e2ee-server-pub"
    public static let headerSession = "x-vibex-e2ee-session"
    public static let headerAuth = "x-vibex-e2ee-auth"
    public static let version = "v1"

    private static let hkdfSalt = Data("vibex-e2ee-v1-salt".utf8)
    private static let hkdfInfo = Data("vibex-e2ee-v1-aes256gcm".utf8)
    private static let aadAuth = Data("vibex-e2ee-auth-v1".utf8)
    private static let aadReq = Data("vibex-e2ee-req-v1".utf8)
    private static let aadResp = Data("vibex-e2ee-resp-v1".utf8)

    public struct SessionState: Sendable {
        public let sessionId: String
        public let serverPubBase64: String
        public let symmetricKey: SymmetricKey
    }

    private let lock = NSLock()
    private let privateKey: P256.KeyAgreement.PrivateKey
    public let clientPublicKeyBase64: String
    private var sessionsByOrigin: [String: SessionState] = [:]

    public init() {
        let priv = P256.KeyAgreement.PrivateKey()
        self.privateKey = priv
        self.clientPublicKeyBase64 = priv.publicKey.x963Representation.base64EncodedString()
    }

    public static func originKey(from urlOrOrigin: String) -> String {
        var trimmed = urlOrOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "/api/v1") {
            trimmed = String(trimmed[..<range.lowerBound])
        } else if let range = trimmed.range(of: "/health") {
            trimmed = String(trimmed[..<range.lowerBound])
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed.lowercased()
    }

    public func session(for urlOrOrigin: String) -> SessionState? {
        let key = Self.originKey(from: urlOrOrigin)
        lock.lock()
        defer { lock.unlock() }
        return sessionsByOrigin[key]
    }

    public func isE2eeActive(for urlOrOrigin: String) -> Bool {
        session(for: urlOrOrigin) != nil
    }

    @discardableResult
    public func ingestHandshake(
        originOrUrl: String,
        sessionId: String?,
        serverPubBase64: String?
    ) -> SessionState? {
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty,
              let serverPubBase64 = serverPubBase64?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverPubBase64.isEmpty
        else {
            return nil
        }

        let key = Self.originKey(from: originOrUrl)
        lock.lock()
        if let existing = sessionsByOrigin[key],
           existing.sessionId == sessionId,
           existing.serverPubBase64 == serverPubBase64
        {
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let serverPubData = Data(base64Encoded: serverPubBase64),
              let serverPub = try? P256.KeyAgreement.PublicKey(x963Representation: serverPubData),
              let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: serverPub)
        else {
            return nil
        }

        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.hkdfSalt,
            sharedInfo: Self.hkdfInfo,
            outputByteCount: 32
        )

        let state = SessionState(
            sessionId: sessionId,
            serverPubBase64: serverPubBase64,
            symmetricKey: symmetricKey
        )
        lock.lock()
        sessionsByOrigin[key] = state
        lock.unlock()
        return state
    }

    @discardableResult
    public func ingestHandshakeHeaders(originOrUrl: String, response: HTTPURLResponse) -> SessionState? {
        let sessionId = response.value(forHTTPHeaderField: Self.headerSession)
        let serverPub = response.value(forHTTPHeaderField: Self.headerServerPub)
        return ingestHandshake(originOrUrl: originOrUrl, sessionId: sessionId, serverPubBase64: serverPub)
    }

    public static func encrypt(key: SymmetricKey, aad: Data, plaintext: Data) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        guard let combined = sealed.combined else {
            throw PairingError.invalidOrigin("E2EE 加密失败")
        }
        return Data(combined.base64EncodedString().utf8)
    }

    public static func encryptString(key: SymmetricKey, aad: Data, plaintext: String) throws -> String {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: nonce, authenticating: aad)
        guard let combined = sealed.combined else {
            throw PairingError.invalidOrigin("E2EE 加密失败")
        }
        return combined.base64EncodedString()
    }

    public static func decrypt(key: SymmetricKey, aad: Data, base64Payload: Data) throws -> Data {
        let text = String(decoding: base64Payload, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: text) else {
            throw HostError.malformedResponse
        }
        let box = try AES.GCM.SealedBox(combined: raw)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    public func encryptAuthHeader(_ authValue: String, session: SessionState) throws -> String {
        try Self.encryptString(key: session.symmetricKey, aad: Self.aadAuth, plaintext: authValue)
    }

    public func encryptRequestBody(_ body: Data, session: SessionState) throws -> Data {
        try Self.encrypt(key: session.symmetricKey, aad: Self.aadReq, plaintext: body)
    }

    public func decryptResponseBody(_ body: Data, session: SessionState) throws -> Data {
        try Self.decrypt(key: session.symmetricKey, aad: Self.aadResp, base64Payload: body)
    }
}
