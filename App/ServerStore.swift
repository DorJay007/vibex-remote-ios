import CompanionCore
import Foundation
import Observation

struct ServerProfile: Codable, Identifiable, Hashable {
    let id: String
    var origin: String
    var deviceName: String
    var serverVersion: String
    var protocolVersion: String
    var scopes: [String]
    var hostId: String? = nil
    var hostName: String? = nil

    var isCloudService: Bool {
        let lower = origin.lowercased()
        return lower.contains("/t/") || lower.hasPrefix("https://")
    }

    var channelBadgeText: String {
        isCloudService ? "云服务 Beta" : "局域网"
    }

    var transportChannelLabel: String {
        isCloudService ? "VibeX 云服务 · Beta" : "LAN 局域网直连"
    }

    var displayHost: String {
        if let hostName, !hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hostName
                .replacingOccurrences(of: ".local", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if isCloudService {
            return "VibeX 桌面端"
        }
        return URL(string: origin)?.host ?? origin
    }

    var serverName: String {
        if let hostName, !hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = hostName
                .replacingOccurrences(of: ".local", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.lowercased().hasPrefix("vibex") {
                return cleaned
            }
            return "VibeX (\(cleaned))"
        }
        if isCloudService {
            return "VibeX 桌面端"
        }
        return "VibeX (\(displayHost))"
    }
}

struct PendingMobileConflict: Identifiable {
    let id = UUID()
    let existingDeviceName: String
    let currentDeviceName: String
    let retryAction: @MainActor () async -> Void
}

struct PendingCloudFallbackPrompt: Identifiable {
    let id = UUID()
    let profileId: String
    let hostName: String
    let cloudOrigin: String
    let rttMs: Int
}

@Observable
final class ServerStore {
    private(set) var profiles: [ServerProfile]
    private let defaults: UserDefaults
    private static let key = "server-profiles"
    private static let autoConnectKey = "server-auto-connect"

    // Auto-connect switch (whether to automatically connect to paired computer on launch)
    var autoConnect: Bool {
        didSet {
            defaults.set(autoConnect, forKey: Self.autoConnectKey)
            if autoConnect, activeProfile != nil {
                isSessionConnected = true
                Task { await refreshActiveTelemetry() }
            }
        }
    }
    var isSessionConnected: Bool = true

    var discoveredHosts: [DiscoveredLanHost] = []
    var discoveringHosts: Bool = false
    var pairingInProgress: Bool = false
    var pairingError: String?
    var pendingCloudFallback: PendingCloudFallbackPrompt?
    var isPresentingPairSheet: Bool = false
    var connectionSuccessCount: Int = 0

    // Active host telemetry
    var isOnline: Bool = false
    var realtimeRttMs: Int?
    var connectionFailureReason: String?

    private var discoverTask: Task<Void, Never>?
    private var telemetryLoopTask: Task<Void, Never>?
    private var declinedCloudFallbackProfileIds = Set<String>()
    weak var accountStore: VibeXAccountStore?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = (defaults.data(forKey: Self.key))
            .flatMap { try? JSONDecoder().decode([ServerProfile].self, from: $0) } ?? []
        self.profiles = decoded
        let savedAutoConnect = defaults.object(forKey: Self.autoConnectKey) as? Bool ?? true
        self.autoConnect = savedAutoConnect
        self.isSessionConnected = savedAutoConnect || decoded.isEmpty
        for profile in decoded where profile.origin.contains("/t/") {
            PairingClient.rememberRelayBase(profile.origin)
        }
        startTelemetryMonitorLoop()
    }

    private func startTelemetryMonitorLoop() {
        telemetryLoopTask?.cancel()
        telemetryLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self, self.activeProfile != nil, self.isSessionConnected, !self.isPresentingPairSheet, !self.pairingInProgress {
                    await self.refreshActiveTelemetry()
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    @MainActor
    func connectSavedProfile(_ profile: ServerProfile) {
        setActive(profile.id)
        isSessionConnected = true
        pairingError = nil
        connectionSuccessCount += 1
        Task { await refreshActiveTelemetry() }
    }

    func discoverHosts() {
        discoverTask?.cancel()
        discoveringHosts = true
        discoverTask = Task { @MainActor in
            let found = await PairingClient.discoverLanHosts()
            guard !Task.isCancelled else { return }
            self.discoveredHosts = found
            self.discoveringHosts = false
        }
    }

    /// LAN origin of the desktop if it answered the latest Wi-Fi scan.
    func lanOrigin(forHostId hostId: String) -> String? {
        discoveredHosts.first { host in
            !host.isCloudService && host.hostId.map(AccountDesktop.rawHostId) == hostId
        }?.origin
    }

    /// Connects with a credential this phone already holds for the desktop; false when none is usable.
    @MainActor
    func connectSavedCredential(hostId: String, origin: String) async -> Bool {
        guard let profile = profiles.last(where: { $0.hostId.map(AccountDesktop.rawHostId) == hostId }) else { return false }
        guard let token = KeychainStore.read(account: profile.id) else { return false }
        guard let parsed = try? HostOrigin.parse(origin) else { return false }
        do {
            _ = try await HostClient(origin: parsed, accessToken: token).checkCapabilities()
        } catch let HostError.server(status, _) where status == 401 {
            forget(profile)
            return false
        } catch {
            return false
        }
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        profiles[idx].origin = parsed.value
        if parsed.value.contains("/t/") {
            PairingClient.rememberRelayBase(parsed.value)
        }
        adopt(profiles[idx])
        return true
    }

    /// Asks the desktop to approve this phone for the signed-in VibeX account, then adopts the issued credential.
    @MainActor
    func connectViaAccountRequest(
        origin: String,
        hostId: String,
        hostName: String,
        deviceName: String,
        accountToken: String,
        replaceExistingMobile: Bool,
        onAwaitingApproval: @MainActor (String) -> Void
    ) async throws {
        let parsed = try HostOrigin.parse(origin)
        if parsed.value.contains("/t/") {
            PairingClient.rememberRelayBase(parsed.value)
        }
        pairingInProgress = true
        defer { pairingInProgress = false }
        let client = PairingClient()
        let requested = try await client.requestConnect(
            origin: parsed,
            deviceName: deviceName,
            replaceExistingMobile: replaceExistingMobile,
            accountToken: accountToken
        )
        onAwaitingApproval(requested.sasCode)
        let approved = try await client.awaitConnectApproval(origin: parsed, requestId: requested.requestId)
        guard let credential = approved.credential else { throw PairingError.connectExpired }
        try KeychainStore.save(credential.access_token, account: credential.device_id)
        let capabilities = try? await HostClient(origin: parsed, accessToken: credential.access_token).checkCapabilities()
        let resolvedName = (approved.hostName ?? hostName)
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        adopt(
            ServerProfile(
                id: credential.device_id,
                origin: parsed.value,
                deviceName: deviceName,
                serverVersion: capabilities?.server_version ?? "",
                protocolVersion: capabilities?.protocol_version ?? PairingClient.clientProtocolVersion,
                scopes: credential.scopes,
                hostId: approved.hostId.isEmpty ? hostId : AccountDesktop.rawHostId(approved.hostId),
                hostName: resolvedName.isEmpty ? nil : resolvedName
            )
        )
    }

    /// `input` is a pasted or scanned invitation, or a bare 8-digit connection code.
    /// When `manualOrigin` is empty for an 8-digit code, automatically resolves candidate origins
    /// from discovered hosts, saved profiles, or LAN/Cloud discovery.
    @MainActor
    func pair(
        input: String,
        manualOrigin: String = "",
        deviceName: String,
        replaceExistingMobile: Bool = false,
        onConflict: @escaping @MainActor (PendingMobileConflict) -> Void
    ) async throws {
        let client = PairingClient()
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            throw PairingError.missingInput("请输入 8 位连接码或粘贴邀请")
        }

        var resolvedHostId: String?
        var resolvedHostName: String?
        let session: CompanionSession

        do {
            if PairingInvitation.looksLikeInvitation(trimmedInput) {
                let invitation = try PairingInvitation.parse(trimmedInput)
                resolvedHostId = invitation.host_id
                for reach in invitation.reachability where reach.origin.contains("/t/") {
                    PairingClient.rememberRelayBase(reach.origin)
                }
                let directOriginText = manualOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
                if !directOriginText.isEmpty, let directOrigin = try? HostOrigin.parse(directOriginText) {
                    session = try await client.redeem(
                        origin: directOrigin,
                        pairingToken: invitation.pairing_token,
                        deviceName: deviceName,
                        replaceExistingMobile: replaceExistingMobile
                    )
                } else {
                    session = try await client.redeem(
                        invitation: invitation,
                        deviceName: deviceName,
                        replaceExistingMobile: replaceExistingMobile
                    )
                }
            } else {
                var candidateUrls: [String] = []
                func appendCandidate(_ raw: String) {
                    let normalized = Self.normalizeOrigin(raw)
                    guard !normalized.isEmpty, !candidateUrls.contains(normalized) else { return }
                    candidateUrls.append(normalized)
                }

                if !manualOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendCandidate(manualOrigin)
                }
                for host in discoveredHosts {
                    appendCandidate(host.origin)
                }
                if let activeOrigin = activeProfile?.origin {
                    appendCandidate(activeOrigin)
                }
                for profile in profiles.reversed() {
                    appendCandidate(profile.origin)
                    if let hid = profile.hostId, !hid.isEmpty, !hid.hasPrefix("host:") {
                        let relayBase = PairingClient.defaultOfficialRelayBase
                        if !relayBase.isEmpty {
                            appendCandidate("\(relayBase)/t/\(hid)")
                        }
                    }
                }
                let codeRendezvous = await PairingClient.resolvePairingCodeRendezvous(
                    connectionCode: trimmedInput,
                    knownOrigins: profiles.map(\.origin)
                )
                for origin in codeRendezvous {
                    appendCandidate(origin)
                }
                let hasCloudCandidate = candidateUrls.contains { $0.contains("/t/") || $0.lowercased().hasPrefix("https://") }
                if candidateUrls.isEmpty || !hasCloudCandidate {
                    let autoFound = await PairingClient.discoverLanHosts()
                    if self.discoveredHosts.isEmpty {
                        self.discoveredHosts = autoFound
                    }
                    for host in autoFound {
                        appendCandidate(host.origin)
                    }
                }

                guard !candidateUrls.isEmpty else {
                    throw PairingError.missingInput("未发现在线电脑，请先确认电脑端在线")
                }

                var lastError: Error = PairingError.unreachable
                var matchedSession: CompanionSession?
                for url in candidateUrls {
                    guard let parsedOrigin = try? HostOrigin.parse(url) else { continue }
                    do {
                        let s = try await client.redeem(
                            origin: parsedOrigin,
                            pairingToken: trimmedInput.uppercased(),
                            deviceName: deviceName,
                            replaceExistingMobile: replaceExistingMobile
                        )
                        matchedSession = s
                        if let matchedHost = discoveredHosts.first(where: { $0.origin == parsedOrigin.value }) {
                            resolvedHostId = matchedHost.hostId
                            resolvedHostName = matchedHost.displayName
                        }
                        break
                    } catch let err as PairingError {
                        lastError = err
                        switch err {
                        case .codeAlreadyUsed, .codeExpired, .codeInvalid, .notCompanionInvitation, .mobileDeviceConflict:
                            throw err
                        default:
                            continue
                        }
                    } catch {
                        lastError = error
                        continue
                    }
                }
                guard let finalSession = matchedSession else {
                    throw lastError
                }
                session = finalSession
            }
        } catch let PairingError.mobileDeviceConflict(existingName) {
            let winningOrigin = PairingClient.consumeLastConflictOrigin() ?? manualOrigin
            let conflict = PendingMobileConflict(
                existingDeviceName: existingName,
                currentDeviceName: deviceName
            ) { [weak self] in
                guard let self else { return }
                do {
                    try await self.pair(
                        input: input,
                        manualOrigin: winningOrigin,
                        deviceName: deviceName,
                        replaceExistingMobile: true,
                        onConflict: onConflict
                    )
                } catch {
                    self.pairingError = Self.sanitizeError(error)
                }
            }
            onConflict(conflict)
            throw PairingError.mobileDeviceConflict(existingDeviceName: existingName)
        }

        let id = session.credential.device_id
        try KeychainStore.save(session.credential.access_token, account: id)
        adopt(
            ServerProfile(
                id: id,
                origin: session.origin.value,
                deviceName: deviceName,
                serverVersion: session.capabilities.server_version,
                protocolVersion: session.capabilities.protocol_version,
                scopes: session.credential.scopes,
                hostId: resolvedHostId,
                hostName: resolvedHostName
            )
        )
    }

    @MainActor
    private func adopt(_ profile: ServerProfile) {
        isSessionConnected = true
        isOnline = true
        connectionFailureReason = nil
        pairingError = nil
        pendingCloudFallback = nil
        declinedCloudFallbackProfileIds.remove(profile.id)
        upsertProfile(profile)
        connectionSuccessCount += 1
        Task { @MainActor [weak self] in
            await self?.refreshActiveTelemetry()
        }
    }

    @MainActor
    func confirmSwitchToCloudFallback() {
        guard let prompt = pendingCloudFallback else { return }
        pendingCloudFallback = nil
        declinedCloudFallbackProfileIds.remove(prompt.profileId)
        if let idx = profiles.firstIndex(where: { $0.id == prompt.profileId }) {
            profiles[idx].origin = prompt.cloudOrigin
            persist()
        }
        isOnline = true
        realtimeRttMs = prompt.rttMs
        connectionFailureReason = nil
        Task { await refreshActiveTelemetry() }
    }

    @MainActor
    func declineSwitchToCloudFallback() {
        if let prompt = pendingCloudFallback {
            declinedCloudFallbackProfileIds.insert(prompt.profileId)
        }
        pendingCloudFallback = nil
    }

    @MainActor
    func handleActiveCredentialRevoked(_ profile: ServerProfile) {
        guard !isPresentingPairSheet else {
            isOnline = false
            realtimeRttMs = nil
            connectionFailureReason = "已被其他手机接管下线"
            return
        }
        forget(profile)
        isOnline = false
        realtimeRttMs = nil
        connectionFailureReason = "已被其他手机接管下线"
        pairingError = "当前电脑已切换至其他手机远程连接，本机已强制下线并清除凭据，下次需重新连接"
    }

    @MainActor
    private func verifyActiveTokenNotRevoked(_ profile: ServerProfile) async -> Bool {
        guard let hostClient = client(for: profile) else {
            handleActiveCredentialRevoked(profile)
            return false
        }
        do {
            try await hostClient.checkCapabilities()
            return true
        } catch let HostError.server(status, _) where status == 401 {
            handleActiveCredentialRevoked(profile)
            return false
        } catch {
            return true
        }
    }

    @MainActor
    func refreshActiveTelemetry() async {
        guard let active = activeProfile else {
            isOnline = false
            realtimeRttMs = nil
            connectionFailureReason = nil
            return
        }

        if let probe = await PairingClient.probeHostHealth(
            originUrl: active.origin,
            timeoutSeconds: 1.5,
            expectedHostId: active.hostId
        ) {
            guard await verifyActiveTokenNotRevoked(active) else { return }
            if !active.isCloudService {
                declinedCloudFallbackProfileIds.remove(active.id)
            }
            pendingCloudFallback = nil
            isOnline = true
            realtimeRttMs = probe.rttMs
            connectionFailureReason = nil
            if (active.hostName == nil || active.hostId == nil),
               let idx = profiles.firstIndex(where: { $0.id == active.id })
            {
                profiles[idx].hostId = active.hostId ?? probe.host.hostId
                profiles[idx].hostName = active.hostName ?? probe.host.displayName
                persist()
            }
            return
        }

        // If the computer switched to or from Cloud Service and we know its hostId, try rendezvous origins
        if let hostId = active.hostId, !hostId.isEmpty {
            let candidates = await PairingClient.resolveHostRendezvous(
                hostId: hostId,
                knownOrigins: profiles.map(\.origin)
            )
            for candidate in candidates where candidate != active.origin {
                if let probe = await PairingClient.probeHostHealth(
                    originUrl: candidate,
                    timeoutSeconds: 1.5,
                    expectedHostId: hostId
                ) {
                    // If the user originally connected via LAN direct, ask before switching to Cloud Service!
                    if !active.isCloudService && probe.host.isCloudService {
                        isOnline = false
                        realtimeRttMs = nil
                        connectionFailureReason = "局域网已断开"
                        if !declinedCloudFallbackProfileIds.contains(active.id) && pendingCloudFallback == nil {
                            pendingCloudFallback = PendingCloudFallbackPrompt(
                                profileId: active.id,
                                hostName: active.displayHost,
                                cloudOrigin: probe.host.origin,
                                rttMs: probe.rttMs
                            )
                        }
                        return
                    }
                    if let idx = profiles.firstIndex(where: { $0.id == active.id }) {
                        profiles[idx].origin = probe.host.origin
                        profiles[idx].hostName = active.hostName ?? probe.host.displayName
                        persist()
                    }
                    if let updatedActive = activeProfile {
                        guard await verifyActiveTokenNotRevoked(updatedActive) else { return }
                    }
                    isOnline = true
                    realtimeRttMs = probe.rttMs
                    connectionFailureReason = nil
                    return
                }
            }
        }

        isOnline = false
        realtimeRttMs = nil
        connectionFailureReason = "电脑离线"
    }

    private func upsertProfile(_ profile: ServerProfile) {
        profiles.removeAll {
            $0.id == profile.id ||
                $0.origin == profile.origin ||
                (profile.hostId != nil && $0.hostId == profile.hostId)
        }
        profiles.append(profile)
        persist()
        if let accountStore {
            Task { @MainActor in
                await accountStore.pushLocalHosts(from: self)
            }
        }
    }

    @MainActor
    func mergeAccountCloudProfiles(_ cloudProfiles: [VibeXSyncableHostProfile], relayBase: String) {
        var didChange = false

        for remote in cloudProfiles {
            let cleanHostId = remote.hostId.map(AccountDesktop.rawHostId)
            guard let accessToken = remote.credential?.accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accessToken.isEmpty
            else { continue }

            var targetOrigin = Self.normalizeOrigin(remote.origin)
            if (targetOrigin.isEmpty || targetOrigin.contains("127.0.0.1") || targetOrigin.contains("localhost")),
               let cleanHostId, !cleanHostId.isEmpty, !relayBase.isEmpty
            {
                targetOrigin = "\(relayBase)/t/\(cleanHostId)"
            }
            guard !targetOrigin.isEmpty else { continue }

            let existing = profiles.first {
                $0.id == remote.profileId ||
                    (cleanHostId != nil && $0.hostId == cleanHostId) ||
                    $0.origin == targetOrigin
            }
            if existing == nil {
                let profileId = remote.profileId.isEmpty ? UUID().uuidString : remote.profileId
                try? KeychainStore.save(accessToken, account: profileId)
                let imported = ServerProfile(
                    id: profileId,
                    origin: targetOrigin,
                    deviceName: "iOS Cloud Sync",
                    serverVersion: "0.4.5",
                    protocolVersion: "1",
                    scopes: ["conversations.read", "conversations.write", "plugins.read"],
                    hostId: cleanHostId,
                    hostName: remote.name.isEmpty ? nil : remote.name
                )
                profiles.append(imported)
                didChange = true
            }
        }

        if didChange {
            persist()
            Task { await refreshActiveTelemetry() }
        }
    }

    func exportSyncableProfiles() -> [VibeXSyncableHostProfile] {
        let nowIso = ISO8601DateFormatter().string(from: Date())
        return profiles.compactMap { profile in
            guard let token = KeychainStore.read(account: profile.id), !token.isEmpty else {
                return nil
            }
            return VibeXSyncableHostProfile(
                syncKey: profile.hostId ?? profile.id,
                profileId: profile.id,
                hostId: profile.hostId,
                name: profile.displayHost,
                origin: profile.origin,
                provisionKind: "http",
                credential: VibeXSyncableHostCredential(
                    deviceId: profile.id,
                    accessToken: token
                ),
                lastConnectedAt: nowIso,
                updatedAt: nowIso
            )
        }
    }

    static func sanitizeError(_ error: Error) -> String {
        if let pairingError = error as? PairingError,
           let desc = pairingError.errorDescription,
           !desc.contains("http://"),
           !desc.contains("https://")
        {
            return desc
        }
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("401") || lower.contains("unauthorized") {
            return "连接码不正确或授权已失效，请重试"
        }
        if lower.contains("502") || lower.contains("503") || lower.contains("504") ||
            lower.contains("health check") || lower.contains("tenant") || lower.contains("offline")
        {
            return "电脑当前离线或未开启云服务连接"
        }
        if error is URLError || lower.contains("timed out") || lower.contains("connect") || lower.contains("network") {
            return "无法连接到电脑，请确认电脑端在线"
        }
        if raw.contains("http://") || raw.contains("https://") || raw.contains("/t/") {
            return "连接失败，请确认电脑端在线后重试"
        }
        return raw.isEmpty ? "连接失败，请重试" : raw
    }

    static func normalizeOrigin(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return text }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "http://\(text)"
        }
        if let components = URLComponents(string: text),
           components.scheme == "http",
           components.port == nil,
           let host = components.host,
           !host.isEmpty
        {
            var updated = components
            updated.port = 17891
            if let built = updated.string {
                return built
            }
        }
        return text
    }

    /// The most recently paired computer is the one the tabs read from.
    var activeProfile: ServerProfile? { profiles.last }

    func activeClient() -> HostClient? {
        activeProfile.flatMap { client(for: $0) }
    }

    func setActive(_ profileID: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let chosen = profiles.remove(at: idx)
        profiles.append(chosen)
        persist()
        Task { await refreshActiveTelemetry() }
    }

    func remove(_ profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        forget(profile)
    }

    func client(for profile: ServerProfile) -> HostClient? {
        guard let origin = try? HostOrigin.parse(profile.origin),
              let token = KeychainStore.read(account: profile.id)
        else { return nil }
        return HostClient(origin: origin, accessToken: token)
    }

    func forget(_ profile: ServerProfile) {
        KeychainStore.delete(account: profile.id)
        profiles.removeAll { $0.id == profile.id }
        persist()
        if let accountStore {
            let pid = profile.id
            let hid = profile.hostId
            let orig = profile.origin
            Task { @MainActor in
                await accountStore.deleteCloudSavedHost(profileId: pid, hostId: hid, origin: orig)
            }
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: Self.key)
    }
}
