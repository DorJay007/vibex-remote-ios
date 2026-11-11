import CompanionCore
import SwiftUI
import UIKit

/// Gate for tabs that read from the paired computer.
struct RequiresServer<Content: View>: View {
    @Environment(ServerStore.self) private var servers
    @Binding var selection: AppTab
    @ViewBuilder let content: (HostClient) -> Content

    var body: some View {
        Group {
            if let profile = servers.activeProfile {
                if !servers.isSessionConnected {
                    UnifiedServerConnectView(authExpired: false)
                } else if let client = servers.client(for: profile) {
                    content(client)
                } else {
                    UnifiedServerConnectView(authExpired: true)
                }
            } else {
                UnifiedServerConnectView(authExpired: false)
            }
        }
    }
}

struct UnifiedServerConnectView: View {
    @Environment(ServerStore.self) private var servers
    let authExpired: Bool
    var startWithScanner: Bool = false
    var initialOrigin: String? = nil
    var onPaired: (() -> Void)? = nil

    @State private var quickCode = ""
    @State private var scanning = false
    @State private var submittingCode = false
    @State private var localError: String?
    @State private var localMobileConflict: PendingMobileConflict?
    @State private var didAppear = false

    private var isLan: Bool {
        servers.preferredDiscoveryMode != "cloud"
    }

    private var displayError: String? {
        localError ?? servers.pairingError
    }

    var body: some View {
        @Bindable var bindableServers = servers
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 24)

                // Header Icon & Title
                Image(systemName: servers.pendingConnectSasCode != nil ? "laptopcomputer.and.iphone" : (authExpired ? "key.slash" : "desktopcomputer"))
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(servers.pendingConnectSasCode != nil ? Color.accentColor : Color.secondary)

                Text(headerTitle)
                    .font(.system(size: 20, weight: .bold))
                    .multilineTextAlignment(.center)

                if let sasCode = servers.pendingConnectSasCode {
                    sasConfirmationCard(sasCode: sasCode)
                } else {
                    if let savedProfile = servers.activeProfile, !servers.isSessionConnected, !authExpired {
                        savedComputerReconnectCard(profile: savedProfile)
                    }

                    // 1. Mode Switcher (Default: 局域网直连, never auto-cloud)
                    modeSwitcherBar

                    // 2. Discovered Computers Card with inline Refresh
                    discoveredComputersCard

                    // 3. Inline Connection Code + Scan QR Card
                    inlineCodeAndScanCard

                    // 4. Auto-connect toggle
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                        Text("自动连接已配对电脑")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Toggle("", isOn: $bindableServers.autoConnect)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                            )
                    )
                }

                if let errorText = displayError, !errorText.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.red.opacity(0.08))
                    )
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .fullScreenCover(isPresented: $scanning) {
            scannerSheet
        }
        .alert(
            "选择要远程连接的手机",
            isPresented: Binding(
                get: { localMobileConflict != nil },
                set: { if !$0 { localMobileConflict = nil } }
            ),
            presenting: localMobileConflict
        ) { conflict in
            Button("使用「\(conflict.currentDeviceName)」（本机）", role: .destructive) {
                let action = conflict.retryAction
                localMobileConflict = nil
                Task { @MainActor in
                    await action()
                }
            }
            Button("保留「\(conflict.existingDeviceName)」", role: .cancel) {
                localMobileConflict = nil
            }
        } message: { conflict in
            Text("同一台电脑仅限一台手机远程连接。当前电脑已连接「\(conflict.existingDeviceName)」，若切换为本机连接，「\(conflict.existingDeviceName)」将被强制下线并清除凭据，下次需重新连接。")
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            if startWithScanner {
                scanning = true
            }
            if servers.discoveredHosts.isEmpty && !servers.discoveringHosts {
                servers.discoverHosts(modeOverride: servers.preferredDiscoveryMode)
            }
        }
    }

    private func savedComputerReconnectCard(profile: ServerProfile) -> some View {
        Button {
            localError = nil
            servers.connectSavedProfile(profile)
            onPaired?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.serverName)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("已配对电脑 · 自动连接已关闭")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("立即连接")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.green)
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var headerTitle: String {
        if servers.pendingConnectSasCode != nil {
            return "等待电脑「\(servers.pendingConnectHostName ?? "VibeX")」确认"
        }
        return authExpired ? "连接凭据已失效" : "连接电脑"
    }

    private var modeSwitcherBar: some View {
        HStack(spacing: 4) {
            Button {
                localError = nil
                servers.selectDiscoveryMode("lan")
            } label: {
                Text("局域网直连")
                    .font(.system(size: 13.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isLan ? Color.accentColor : Color.clear)
                    )
                    .foregroundStyle(isLan ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)

            Button {
                localError = nil
                servers.selectDiscoveryMode("cloud")
            } label: {
                Text("云服务 Beta")
                    .font(.system(size: 13.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(!isLan ? Color.accentColor : Color.clear)
                    )
                    .foregroundStyle(!isLan ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                )
        )
    }

    private var discoveredComputersCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isLan ? "同一 Wi-Fi 在线电脑" : "云服务在线电脑 · Beta")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    localError = nil
                    servers.discoverHosts(modeOverride: servers.preferredDiscoveryMode)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(servers.discoveringHosts ? "搜索中…" : "刷新")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(servers.discoveringHosts)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if !servers.discoveredHosts.isEmpty {
                ForEach(Array(servers.discoveredHosts.enumerated()), id: \.element.id) { index, host in
                    if index > 0 {
                        Divider().padding(.leading, 14)
                    }
                    Button {
                        localError = nil
                        servers.requestConnectToHost(
                            host,
                            deviceName: UIDevice.current.name,
                            onConflict: { conflict in
                                localMobileConflict = conflict
                            }
                        )
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.displayName)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(host.isCloudService ? "VibeX 云服务 · Beta" : host.origin)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(host.isCloudService ? Color.accentColor : .secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text("一键连接")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.accentColor)
                                )
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                VStack(spacing: 6) {
                    Text(
                        servers.discoveringHosts
                            ? (isLan ? "正在扫描同一 Wi-Fi 下的电脑…" : "正在检测本机已配对的云端电脑…")
                            : (isLan ? "当前 Wi-Fi 未发现电脑" : "云服务仅展示本机已配对过的电脑")
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                    if !servers.discoveringHosts {
                        if isLan {
                            Button {
                                localError = nil
                                servers.selectDiscoveryMode("cloud")
                            } label: {
                                Text("跨网络或未扫到？点击切换至「云服务 Beta」")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("首次跨网配对请使用下方「扫码配对」或输入 8 位连接码")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                )
        )
    }

    private var inlineCodeAndScanCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField("输入 8 位连接码或粘贴邀请", text: $quickCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                        .submitLabel(.go)
                        .onSubmit {
                            submitQuickCode()
                        }

                    if !quickCode.isEmpty {
                        Button {
                            quickCode = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(.systemGroupedBackground))
                )

                if quickCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        pasteAndPairIfInvitation()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 12, weight: .semibold))
                            Text("粘贴")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        submitQuickCode()
                    } label: {
                        if submittingCode {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        } else {
                            Text("连接")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor)
                    )
                    .buttonStyle(.plain)
                    .disabled(submittingCode)
                }
            }

            Button {
                localError = nil
                scanning = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 15, weight: .semibold))
                    Text(authExpired ? "扫码重新配对" : "扫码配对")
                        .font(.system(size: 14.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                )
        )
    }

    private func sasConfirmationCard(sasCode: String) -> some View {
        VStack(spacing: 8) {
            Text("请在电脑端顶部提示条点击「连接」")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("核对码 \(sasCode)")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.accentColor)

            if let origin = servers.pendingConnectOrigin,
               !origin.lowercased().hasPrefix("https://"),
               !origin.contains("/t/")
            {
                Text(origin)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Button("取消等待") {
                servers.cancelPendingConnectRequest()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                )
        )
    }

    private var scannerSheet: some View {
        NavigationStack {
            QRScannerView(
                onCode: { text in
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    quickCode = cleaned
                    scanning = false
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        submitQuickCode(overrideInput: cleaned)
                    }
                },
                onFailure: { message in
                    localError = message
                    scanning = false
                },
                onManualInputTap: {
                    scanning = false
                }
            )
            .ignoresSafeArea()
            .navigationTitle("扫码配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        scanning = false
                    }
                    .foregroundStyle(.white)
                }
            }
        }
    }

    private func pasteAndPairIfInvitation() {
        guard let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pasted.isEmpty
        else { return }
        quickCode = pasted
        localError = nil
        if PairingInvitation.looksLikeInvitation(pasted) {
            submitQuickCode(overrideInput: pasted)
        }
    }

    private func submitQuickCode(overrideInput: String? = nil) {
        let input = (overrideInput ?? quickCode).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !submittingCode else { return }
        submittingCode = true
        localError = nil
        servers.pairingError = nil
        Task { @MainActor in
            do {
                try await servers.pair(
                    input: input,
                    manualOrigin: initialOrigin ?? "",
                    deviceName: UIDevice.current.name,
                    onConflict: { conflict in
                        localMobileConflict = conflict
                    }
                )
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                submittingCode = false
                onPaired?()
            } catch PairingError.mobileDeviceConflict {
                submittingCode = false
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                localError = ServerStore.sanitizeError(error)
                submittingCode = false
            }
        }
    }
}

struct LoadFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("无法读取", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重试", action: retry)
        }
    }
}
