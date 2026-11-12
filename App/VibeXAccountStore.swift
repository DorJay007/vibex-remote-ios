import CompanionCore
import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - VibeX Account Models (1:1 with Desktop frontend/src/features/model-router/account.ts)

enum VibeXAccountTier: String, Codable, Sendable {
    case regular
    case sponsor
    case subscriber
    case beta
    case admin
}

struct VibeXAccountUser: Codable, Equatable, Sendable {
    var id: String?
    var email: String?
    var username: String?
    var displayName: String?
    var avatarUrl: String?
    var tier: VibeXAccountTier?
    var createdAt: String?

    var resolvedDisplayName: String {
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let uname = username?.trimmingCharacters(in: .whitespacesAndNewlines), !uname.isEmpty {
            return uname
        }
        if let mail = email?.split(separator: "@").first?.trimmingCharacters(in: .whitespacesAndNewlines), !mail.isEmpty {
            return mail
        }
        return "VibeX User"
    }

    var avatarInitial: String {
        let name = resolvedDisplayName
        return name.first.map { String($0).uppercased() } ?? "V"
    }

    var accountIdentifier: String {
        if let uname = username?.trimmingCharacters(in: .whitespacesAndNewlines), !uname.isEmpty {
            return uname
        }
        return email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct VibeXCreditGrant: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var source: String?
    var orderNo: String?
    var note: String?
    var amountMicro: Int64
    var remainingMicro: Int64
    var createdAt: String?
    var expiresAt: String?
    var voided: Bool?

    func isActive(nowIso: String) -> Bool {
        if voided == true { return false }
        if let exp = expiresAt, !exp.isEmpty, exp <= nowIso {
            return false
        }
        return remainingMicro > 0
    }
}

struct VibeXModelUsage: Codable, Identifiable, Equatable, Sendable {
    var modelId: String
    var costMicro: Int64
    var requests: Int
    var tokens: Int64

    var id: String { modelId }
}

struct VibeXDailyUsage: Codable, Identifiable, Equatable, Sendable {
    var day: String
    var costMicro: Int64
    var requests: Int
    var tokens: Int64

    var id: String { day }
}

struct VibeXUsage30d: Codable, Equatable, Sendable {
    var byModel: [VibeXModelUsage]?
    var daily: [VibeXDailyUsage]?
    var totalRecords: Int?
    var modelNames: [String: String]?
}

struct VibeXRouterModel: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var vendor: String?
    var inputMicro: Int64?
    var outputMicro: Int64?
    var discountPermille: Int?
}

struct VibeXAssignedRelayServer: Codable, Equatable, Sendable {
    var id: String?
    var name: String?
    var region: String?
    var relayHost: String?
    var relayPort: Int?
    var publicOrigin: String?
}

struct VibeXAccountOverview: Codable, Equatable, Sendable {
    var user: VibeXAccountUser
    var balanceMicro: Int64?
    var serverNow: String?
    var grants: [VibeXCreditGrant]?
    var usage30d: VibeXUsage30d?
    var models: [VibeXRouterModel]?
    var relayPermission: Bool?
    var assignedRelayServer: VibeXAssignedRelayServer?
}

struct VibeXSyncableHostCredential: Codable, Equatable, Sendable {
    var deviceId: String?
    var accessToken: String
}

struct VibeXSyncableHostProfile: Codable, Identifiable, Equatable, Sendable {
    var syncKey: String?
    var profileId: String
    var hostId: String?
    var name: String
    var origin: String
    var provisionKind: String?
    var credential: VibeXSyncableHostCredential?
    var lastConnectedAt: String?
    var updatedAt: String?

    var id: String { syncKey ?? profileId }
}

// MARK: - VibeX Account Store

@Observable
@MainActor
final class VibeXAccountStore {
    static let siteBaseURL = "https://vibex.xforever.xin"
    static let termsPath = "/docs/service"
    /// The site has no privacy page yet; this is where it will be published.
    static let privacyPolicyPath = "/docs/privacy"
    private static let tokenAccountKey = "vibex.account.token"
    private static let cachedOverviewKey = "vibex.account.cached_overview"
    private static let requiresLoginKey = "vibex.account.requires_login"

    private let defaults: UserDefaults
    private(set) var token: String?
    private(set) var overview: VibeXAccountOverview?
    private(set) var desktops: [AccountDesktop] = []
    private(set) var cloudSavedHosts: [VibeXSyncableHostProfile] = []
    private(set) var isLoading: Bool = false
    private(set) var isSyncingHosts: Bool = false
    /// Set when loading the account's desktops failed, so an empty list is not mistaken for an
    /// account without desktops.
    private(set) var desktopsSyncFailed: Bool = false
    private(set) var signingIn: Bool = false
    private(set) var signingOut: Bool = false
    private(set) var authError: String?
    private(set) var lastSyncedAt: Date?
    /// Increments when a device login finishes and the account's desktops are synced.
    private(set) var completedSignIns = 0
    /// Set by an explicit sign-out so the login page returns even while paired computers remain.
    private(set) var requiresLogin: Bool {
        didSet { defaults.set(requiresLogin, forKey: Self.requiresLoginKey) }
    }

    weak var attachedServerStore: ServerStore?

    var isSignedIn: Bool {
        guard let token, !token.isEmpty else { return false }
        return true
    }

    var user: VibeXAccountUser? {
        overview?.user
    }

    /// Relay assigned to the account; accounts without an assignment use the official relay.
    var relayBase: String {
        let relay = overview?.assignedRelayServer
        if let origin = relay?.publicOrigin?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty {
            return origin
        }
        if let host = relay?.relayHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            return "https://\(host)"
        }
        return PairingClient.defaultOfficialRelayBase
    }

    var canUseCloudRelay: Bool {
        overview?.relayPermission != false
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.requiresLogin = defaults.bool(forKey: Self.requiresLoginKey)
        let savedToken = KeychainStore.read(account: Self.tokenAccountKey)
            ?? defaults.string(forKey: Self.tokenAccountKey)
        self.token = savedToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = defaults.data(forKey: Self.cachedOverviewKey),
           let cached = try? JSONDecoder().decode(VibeXAccountOverview.self, from: data)
        {
            self.overview = cached
        }
        if isSignedIn {
            Task { await refreshAll() }
        }
    }

    func attach(serverStore: ServerStore) {
        self.attachedServerStore = serverStore
        serverStore.accountStore = self
        if isSignedIn {
            Task { await syncHosts(with: serverStore) }
        }
    }

    private func saveToken(_ newToken: String?) {
        let clean = newToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        token = (clean?.isEmpty == false) ? clean : nil
        if let valid = token {
            try? KeychainStore.save(valid, account: Self.tokenAccountKey)
            defaults.set(valid, forKey: Self.tokenAccountKey)
        } else {
            KeychainStore.delete(account: Self.tokenAccountKey)
            defaults.removeObject(forKey: Self.tokenAccountKey)
            defaults.removeObject(forKey: Self.cachedOverviewKey)
        }
    }

    static func siteURL(_ path: String) -> URL? {
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: "\(siteBaseURL)\(cleanPath)")
    }

    static func openSitePath(_ path: String) {
        guard let url = siteURL(path) else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    // MARK: - In-App Login

    private static var deviceName: String {
        let name = UIDevice.current.name
        return name.isEmpty ? "VibeX iOS" : name
    }

    func sendLoginCode(to target: String) async throws {
        try await AccountLoginClient(siteBase: Self.siteBaseURL).sendLoginCode(to: target)
    }

    /// Signs into the site on a private cookie session and approves this device's token with it.
    func signIn(_ credential: AccountLoginCredential) async throws {
        signingIn = true
        defer { signingIn = false }
        let client = AccountLoginClient(siteBase: Self.siteBaseURL)
        try await client.signIn(credential)
        let login = try await client.startDeviceLogin(deviceName: Self.deviceName)
        try await client.approve(login)
        let token = try await client.approvedToken(for: login, maxAttempts: 5)
        await completeSignIn(token: token)
    }

    /// The provider signs in inside the auth sheet and lands on the site's authorize page; the token is polled
    /// meanwhile. Closing the sheet abandons the login without an error.
    func signIn(with provider: AccountOAuthProvider) async throws {
        signingIn = true
        defer { signingIn = false }
        let client = AccountLoginClient(siteBase: Self.siteBaseURL)
        let login = try await client.startDeviceLogin(deviceName: Self.deviceName)
        guard let url = client.oauthStartURL(provider, for: login) else {
            throw AccountAuthError(code: "oauth_failed")
        }
        let attempts = max(login.expiresIn / max(login.interval, 1), 1)
        let poll = Task { try await client.approvedToken(for: login, maxAttempts: attempts) }
        let sheet = OAuthSheet()
        guard sheet.present(url, onUserClose: { poll.cancel() }) else {
            poll.cancel()
            throw AccountAuthError(code: "oauth_failed")
        }
        let result = await poll.result
        sheet.dismiss()
        switch result {
        case .success(let token):
            await completeSignIn(token: token)
        case .failure(let error):
            if error is CancellationError { return }
            throw error
        }
    }

    private func completeSignIn(token: String) async {
        saveToken(token)
        authError = nil
        requiresLogin = false
        await refreshAll()
        completedSignIns += 1
    }

    /// A computer paired with a connection code lets the user in without an account.
    func waiveLoginRequirement() {
        requiresLogin = false
    }

    func signOut() async {
        signingOut = true
        defer { signingOut = false }
        let oldToken = token
        saveToken(nil)
        overview = nil
        desktops = []
        cloudSavedHosts = []
        lastSyncedAt = nil
        requiresLogin = true

        if let oldToken, !oldToken.isEmpty {
            _ = try? await performRawRequest(
                path: "/api/auth/logout",
                method: "POST",
                bodyData: nil,
                tokenOverride: oldToken
            )
        }
    }

    // MARK: - Refresh Overview & Host Sync

    func refreshAll() async {
        guard isSignedIn else { return }
        isLoading = (overview == nil)
        authError = nil
        defer { isLoading = false }

        do {
            let fetched: VibeXAccountOverview = try await requestJSON(
                path: "/api/modelrouter/desktop",
                method: "GET",
                body: nil as [String: String]?,
                authenticated: true
            )
            overview = fetched
            if let encoded = try? JSONEncoder().encode(fetched) {
                defaults.set(encoded, forKey: Self.cachedOverviewKey)
            }
        } catch let err as AccountHTTPError where err.code == "signed_out" {
            saveToken(nil)
            overview = nil
            desktops = []
            cloudSavedHosts = []
            return
        } catch {
            authError = describeAccountError(error)
        }

        if let servers = attachedServerStore {
            await syncHosts(with: servers, forcePush: true)
        } else {
            await fetchAccountHostsOnly()
        }
    }

    private func fetchAccountHostsOnly() async {
        guard isSignedIn else { return }
        await loadDesktops()
        if let saved = try? await fetchSavedHosts() {
            self.cloudSavedHosts = saved
        }
    }

    private func loadDesktops() async {
 do {
     desktops = try await fetchDesktops()
     desktopsSyncFailed = false
        } catch {
     desktopsSyncFailed = true
 }
    }

    func syncHosts(with servers: ServerStore, forcePush: Bool = false) async {
        guard isSignedIn else { return }
        isSyncingHosts = true
        defer { isSyncingHosts = false }

        await loadDesktops()

        if let remoteSaved = try? await fetchSavedHosts() {
            self.cloudSavedHosts = remoteSaved
            servers.mergeAccountCloudProfiles(remoteSaved, relayBase: relayBase)
        }

        let localExport = servers.exportSyncableProfiles()
        if !localExport.isEmpty && (forcePush || localExport.count != cloudSavedHosts.count) {
            if let updated = try? await putSavedHosts(localExport) {
                self.cloudSavedHosts = updated
            }
        }
        lastSyncedAt = Date()
    }

    func pushLocalHosts(from servers: ServerStore) async {
        guard isSignedIn else { return }
        let localExport = servers.exportSyncableProfiles()
        guard !localExport.isEmpty else { return }
        if let updated = try? await putSavedHosts(localExport) {
            self.cloudSavedHosts = updated
            self.lastSyncedAt = Date()
        }
    }

    func deleteCloudSavedHost(profileId: String, hostId: String?, origin: String) async {
        guard isSignedIn else { return }
        var payload: [String: String] = [
            "profileId": profileId,
            "origin": origin
        ]
        if let hostId, !hostId.isEmpty {
            payload["hostId"] = hostId
        }
        struct DeleteResp: Decodable {
            var savedHosts: [VibeXSyncableHostProfile]?
        }
        if let resp: DeleteResp = try? await requestJSON(
            path: "/api/account/desktop/saved-hosts",
            method: "DELETE",
            body: payload,
            authenticated: true
        ), let remaining = resp.savedHosts {
            self.cloudSavedHosts = remaining
        }
    }

    private func fetchDesktops() async throws -> [AccountDesktop] {
        let data = try await performRawRequest(
            path: "/api/account/desktop/host-configs",
            method: "GET",
            bodyData: nil,
            tokenOverride: token
        )
        return AccountDesktop.parseDirectory(data)
    }

    private func fetchSavedHosts() async throws -> [VibeXSyncableHostProfile] {
        struct SavedHostsResponse: Decodable {
            var savedHosts: [VibeXSyncableHostProfile]?
        }
        let resp: SavedHostsResponse = try await requestJSON(
            path: "/api/account/desktop/saved-hosts",
            method: "GET",
            body: nil as [String: String]?,
            authenticated: true
        )
        return resp.savedHosts ?? []
    }

    private func putSavedHosts(_ profiles: [VibeXSyncableHostProfile]) async throws -> [VibeXSyncableHostProfile] {
        struct PutRequest: Encodable {
            var profiles: [VibeXSyncableHostProfile]
        }
        struct PutResponse: Decodable {
            var savedHosts: [VibeXSyncableHostProfile]?
        }
        let resp: PutResponse = try await requestJSON(
            path: "/api/account/desktop/saved-hosts",
            method: "PUT",
            body: PutRequest(profiles: profiles),
            authenticated: true
        )
        return resp.savedHosts ?? profiles
    }

    // MARK: - HTTP Client Helpers

    private struct AccountHTTPError: Error {
        let code: String
    }

    private func describeAccountError(_ error: Error) -> String {
        if let httpErr = error as? AccountHTTPError {
            switch httpErr.code {
            case "network": return "无法连接到 VibeX 账号服务，请检查网络后重试"
            case "signed_out": return "登录状态已失效，请重新登录"
            default: return "账号服务请求失败（\(httpErr.code)）"
            }
        }
        return error.localizedDescription
    }

    private func requestJSON<Req: Encodable, Resp: Decodable>(
        path: String,
        method: String,
        body: Req?,
        authenticated: Bool
    ) async throws -> Resp {
        let bodyData = try body.map { try JSONEncoder().encode($0) }
        let tok: String?
        if authenticated {
            guard let current = token, !current.isEmpty else {
                throw AccountHTTPError(code: "signed_out")
            }
            tok = current
        } else {
            tok = nil
        }
        let data = try await performRawRequest(
            path: path,
            method: method,
            bodyData: bodyData,
            tokenOverride: tok
        )
        do {
            return try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw AccountHTTPError(code: "decode_failed")
        }
    }

    private func performRawRequest(
        path: String,
        method: String,
        bodyData: Data?,
        tokenOverride: String?
    ) async throws -> Data {
        guard let url = Self.siteURL(path) else {
            throw AccountHTTPError(code: "invalid_url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let tokenOverride, !tokenOverride.isEmpty {
            request.setValue("Bearer \(tokenOverride)", forHTTPHeaderField: "Authorization")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AccountHTTPError(code: "network")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AccountHTTPError(code: "network")
        }
        if http.statusCode == 401 {
            if tokenOverride != nil {
                saveToken(nil)
            }
            throw AccountHTTPError(code: "signed_out")
        }
        if http.statusCode == 404 || http.statusCode == 405 || http.statusCode == 501 {
            throw AccountHTTPError(code: "unsupported")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errCode = obj["error"] as? String
            {
                throw AccountHTTPError(code: errCode)
            }
            throw AccountHTTPError(code: "http_\(http.statusCode)")
        }
        return data
    }
}

// MARK: - VibeX Account Settings View (1:1 with Desktop AccountSettings.tsx)

struct VibeXAccountSettingsView: View {
    @Environment(VibeXAccountStore.self) private var account
    @Environment(ServerStore.self) private var servers
    @Environment(AppAppearanceStore.self) private var appearance
    @State private var copiedId = false
    @State private var showsLogin = false

    private var nowIso: String {
        account.overview?.serverNow ?? ISO8601DateFormatter().string(from: Date())
    }

    private var activeGrants: [VibeXCreditGrant] {
        (account.overview?.grants ?? []).filter { $0.isActive(nowIso: nowIso) }
    }

    private var balanceMicro: Int64 {
        account.overview?.balanceMicro ?? 0
    }

    private var activeTotalMicro: Int64 {
        activeGrants.reduce(0) { $0 + $1.amountMicro }
    }

    private var activeRemainingMicro: Int64 {
        activeGrants.reduce(0) { $0 + $1.remainingMicro }
    }

    private var remainingPercent: Double {
        if activeTotalMicro > 0 {
            return min(1.0, max(0.0, Double(activeRemainingMicro) / Double(activeTotalMicro)))
        }
        return balanceMicro > 0 ? 1.0 : 0.0
    }

    private var hasActiveCreditsOrTier: Bool {
        let tier = account.user?.tier ?? .regular
        return tier != .regular || balanceMicro > 0 || !activeGrants.isEmpty
    }

    private var planDisplayName: String {
        switch account.user?.tier ?? .regular {
        case .subscriber: return "VibeX 订阅会员"
        case .sponsor: return "VibeX 赞助会员"
        case .beta: return "VibeX Beta 计划"
        case .admin: return "VibeX 管理员"
        case .regular:
            return hasActiveCreditsOrTier ? "按量付费 · 已激活" : "VibeX 免费版"
        }
    }

    var body: some View {
        List {
            // 1. 账号资料 / 登录卡片
            Section {
                if account.isLoading && !account.isSignedIn {
                    AccountCardSkeletonView()
                } else if account.isSignedIn, let user = account.user {
                    signedInProfileCard(user: user)
                } else {
                    signedOutCard
                }

                if let err = account.authError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // 2. 订阅与模型路由额度
            if account.isSignedIn, let overview = account.overview {
                Section("订阅与额度") {
                    subscriptionAndCreditsCard(overview: overview)
                }

                // 3. 近 30 天模型路由用量
                Section("近 30 天模型路由用量") {
                    usage30dCard(overview: overview)
                }
            }

            // 4. 云端同步电脑入口（去重：统一在「已配对的电脑」中管理与连接）
            if account.isSignedIn {
                Section("跨设备电脑同步") {
                    let syncedCount = max(account.desktops.count, account.cloudSavedHosts.count)
                    NavigationLink {
                        PairedComputersSettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.12))
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("管理已配对与云端同步的电脑")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(
                                    syncedCount > 0
                                        ? "已云端同步 \(syncedCount) 台电脑，点击前往切换或连接"
                                        : "在桌面端登录同一账号后自动同步配对记录"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    Button {
                        Task { await account.syncHosts(with: servers, forcePush: true) }
                    } label: {
                        HStack {
                            if account.isSyncingHosts {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(account.isSyncingHosts ? "正在同步电脑配置…" : "立即同步账号下的电脑")
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    .disabled(account.isSyncingHosts)
                }
            }

            // 5. 协作空间个人形象与昵称设置
            Section("本机协作形象") {
                NavigationLink {
                    ProfileSettingsDetailView()
                } label: {
                    HStack(spacing: 12) {
                        MemberBotAvatarView(
                            config: appearance.avatarConfig,
                            size: 36,
                            animated: true
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("协作空间个人形象与昵称")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("\(appearance.userName) (\(appearance.userHandle)) · \(appearance.userRoleTitle)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // 5. 安全、席位与账单入口
            Section("安全与账单") {
                Button {
                    VibeXAccountStore.openSitePath("/account/security")
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("通行密钥与账号安全")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("管理 Passkey、登录设备与双重验证")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    VibeXAccountStore.openSitePath("/account")
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("团队与协作席位")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("管理团队成员席位与共享额度")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    VibeXAccountStore.openSitePath("/account/billing")
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.purple)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("账单与兑换码记录")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("查看历史订单、充值明细与额度兑换")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if account.isSignedIn {
                Section {
                    Button(role: .destructive) {
                        Task { await account.signOut() }
                    } label: {
                        HStack {
                            Spacer()
                            if account.signingOut {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("退出 VibeX 账号")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(account.signingOut)
                }
            }
        }
        .navigationTitle("VibeX 账号")
        .navigationDestination(isPresented: $showsLogin) {
            LoginView(allowsCodePairing: false)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if account.isSignedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await account.refreshAll() }
                    } label: {
                        if account.isLoading || account.isSyncingHosts {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(account.isLoading || account.isSyncingHosts)
                }
            }
        }
        .task {
            if account.isSignedIn {
                await account.refreshAll()
            }
        }
    }

    // MARK: - Subviews

    private func signedInProfileCard(user: VibeXAccountUser) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 52, height: 52)
                    Text(user.avatarInitial)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(user.resolvedDisplayName)
                            .font(.headline.weight(.bold))
                        Text(hasActiveCreditsOrTier ? "已激活" : "免费版")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    hasActiveCreditsOrTier
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.secondary.opacity(0.14)
                                )
                            )
                            .foregroundStyle(hasActiveCreditsOrTier ? Color.accentColor : .secondary)
                    }
                    if let email = user.email, !email.isEmpty {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let accId = user.accountIdentifier
                    if !accId.isEmpty {
                        HStack(spacing: 6) {
                            Text("ID: \(accId)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Button {
                                #if canImport(UIKit)
                                UIPasteboard.general.string = accId
                                #endif
                                copiedId = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    copiedId = false
                                }
                            } label: {
                                Image(systemName: copiedId ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundStyle(copiedId ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private var signedOutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("登录 VibeX 账号")
                        .font(.subheadline.weight(.bold))
                    Text("跨设备自动同步已配对电脑、查看订阅计划与模型路由额度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                showsLogin = true
            } label: {
                Text("登录")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 6)
    }

    private func subscriptionAndCreditsCard(overview: VibeXAccountOverview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.accentColor)
                        Text(planDisplayName)
                            .font(.subheadline.weight(.bold))
                    }
                    if !activeGrants.isEmpty {
                        Text("\(activeGrants.count) 个额度包生效中")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("支持 Claude / OpenAI / Gemini 等多模型路由与云中继")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    VibeXAccountStore.openSitePath("/account/plan")
                } label: {
                    Text("充值 / 订阅")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("可用模型路由余额")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("$\(Self.formatCredits(balanceMicro))")
                        .font(.title2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.primary)
                }
                Spacer()
                if activeTotalMicro > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("总额度 $\(Self.formatCredits(activeTotalMicro))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("剩余 \(Int((remainingPercent * 100).rounded()))%")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            if activeTotalMicro > 0 {
                ProgressView(value: remainingPercent)
                    .tint(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    private func usage30dCard(overview: VibeXAccountOverview) -> some View {
        let rows = overview.usage30d?.byModel ?? []
        let spent30d = rows.reduce(Int64(0)) { $0 + $1.costMicro }
        let reqs30d = rows.reduce(0) { $0 + $1.requests }
        let tokens30d = rows.reduce(Int64(0)) { $0 + $1.tokens }
        let nameMap = overview.usage30d?.modelNames ?? [:]

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                metricBox(title: "30天消耗", value: "$\(Self.formatCredits(spent30d))")
                metricBox(title: "请求次数", value: "\(reqs30d)")
                metricBox(title: "总 Token", value: Self.formatCompact(tokens30d))
            }

            if !rows.isEmpty {
                Divider()
                ForEach(rows.prefix(6)) { row in
                    HStack {
                        Text(nameMap[row.modelId] ?? row.modelId)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Text("\(row.requests) 次 · \(Self.formatCompact(row.tokens)) tok")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("$\(Self.formatCredits(row.costMicro))")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .frame(minWidth: 54, alignment: .trailing)
                    }
                }
            } else {
                Text("近 30 天暂无模型路由调用记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func metricBox(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    static func formatCredits(_ micro: Int64) -> String {
        let value = Double(micro) / 1_000_000.0
        return String(format: "%.2f", value)
    }

    static func formatCompact(_ value: Int64) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000.0)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000.0)
        }
        return "\(value)"
    }
}
