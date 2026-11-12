import CompanionCore
import Observation
import SwiftUI
import UIKit

enum DesktopChannel: Equatable {
    case cloud
    case lan
}

/// Drives the one-tap connection to a desktop signed into the same VibeX account, and the code-pairing fallback.
@Observable
@MainActor
final class DesktopConnectFlow {
    enum Phase: Equatable {
        case choosing
        case connecting(DesktopChannel)
        case awaitingApproval(sasCode: String)
        case failed(String)
    }

    struct ReplaceConfirmation: Identifiable {
        let id = UUID()
        let existingDeviceName: String
        let desktop: AccountDesktop
        let channel: DesktopChannel
    }

    var isPickerPresented = false
    var isCodePairingPresented = false
    var selectedHostId: String?
    var replaceConfirmation: ReplaceConfirmation?
    private(set) var phase: Phase = .choosing
    private var lastAttempt: (desktop: AccountDesktop, channel: DesktopChannel)?
    private var openCodePairingAfterPicker = false
    private var connectTask: Task<Void, Never>?

    func presentPicker(servers: ServerStore) {
        phase = .choosing
        replaceConfirmation = nil
        isPickerPresented = true
        servers.discoverHosts()
    }

    func switchToCodePairing() {
        openCodePairingAfterPicker = true
        isPickerPresented = false
    }

    /// Called when the picker sheet goes away by any route; abandons an in-flight request.
    func pickerDismissed() {
        connectTask?.cancel()
        connectTask = nil
        phase = .choosing
        if openCodePairingAfterPicker {
            openCodePairingAfterPicker = false
            isCodePairingPresented = true
        }
    }

    func selectedDesktop(in desktops: [AccountDesktop]) -> AccountDesktop? {
        desktops.first { $0.hostId == selectedHostId } ?? desktops.first
    }

    func retry(servers: ServerStore, account: VibeXAccountStore) {
        guard let lastAttempt else {
            phase = .choosing
            return
        }
        connect(lastAttempt.desktop, via: lastAttempt.channel, servers: servers, account: account)
    }

    func confirmReplace(servers: ServerStore, account: VibeXAccountStore) {
        guard let confirmation = replaceConfirmation else { return }
        replaceConfirmation = nil
        connect(confirmation.desktop, via: confirmation.channel, servers: servers, account: account, replaceExistingMobile: true)
    }

    func connect(
        _ desktop: AccountDesktop,
        via channel: DesktopChannel,
        servers: ServerStore,
        account: VibeXAccountStore,
        replaceExistingMobile: Bool = false
    ) {
        let origin: String
        switch channel {
        case .cloud:
            origin = desktop.cloudOrigin(relayBase: account.relayBase)
        case .lan:
            guard let lanOrigin = servers.lanOrigin(forHostId: desktop.hostId) else {
                phase = .choosing
                return
            }
            origin = lanOrigin
        }
        lastAttempt = (desktop, channel)
        phase = .connecting(channel)
        connectTask?.cancel()
        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !replaceExistingMobile, await servers.connectSavedCredential(hostId: desktop.hostId, origin: origin) {
                self.finish()
                return
            }
            guard let accountToken = account.token else {
                self.isPickerPresented = false
                await account.signOut()
                return
            }
            do {
                try await servers.connectViaAccountRequest(
                    origin: origin,
                    hostId: desktop.hostId,
                    hostName: desktop.displayName,
                    deviceName: UIDevice.current.name,
                    accountToken: accountToken,
                    replaceExistingMobile: replaceExistingMobile,
                    onAwaitingApproval: { sasCode in
                        self.phase = .awaitingApproval(sasCode: sasCode)
                    }
                )
                self.finish()
            } catch is CancellationError {
                return
            } catch PairingError.mobileDeviceConflict(let existingName) {
                self.phase = .choosing
                self.replaceConfirmation = ReplaceConfirmation(existingDeviceName: existingName, desktop: desktop, channel: channel)
            } catch PairingError.accountTokenInvalid {
                self.isPickerPresented = false
                await account.signOut()
            } catch {
                guard !Task.isCancelled else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    private func finish() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        isPickerPresented = false
    }

    private static func message(for error: Error) -> String {
 if let pairingError = error as? PairingError, let description = pairingError.errorDescription {
     return description
 }
        if error is URLError {
     return PairingError.unreachable.errorDescription ?? ""
 }
        return error.localizedDescription
    }
}

/// Popup listing the account's desktops with one-tap cloud / LAN connect.
struct DesktopPickerSheet: View {
    @Environment(ServerStore.self) private var servers
    @Environment(VibeXAccountStore.self) private var account
    @Environment(DesktopConnectFlow.self) private var flow

    private var desktops: [AccountDesktop] { account.desktops }

    var body: some View {
        VStack(spacing: 16) {
            if account.desktops.isEmpty && (account.isLoading || account.isSyncingHosts) {
                LoadingState(label: "正在同步你的电脑")
                    .padding(.vertical, 24)
            } else if account.desktops.isEmpty && account.desktopsSyncFailed {
         errorRow("同步失败，请重试")
  actionButton("重试", prominent: true, enabled: true) {
      Task { await account.syncHosts(with: servers) }
         }
  codePairingLink
     } else if let desktop = flow.selectedDesktop(in: desktops) {
                Text("发现你的电脑")
                    .font(.system(size: 17, weight: .semibold))
                content(for: desktop)
            } else {
                noDesktopGuide
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemGroupedBackground))
        .alert(
            "这台电脑已连接手机「\(flow.replaceConfirmation?.existingDeviceName ?? "")」，要替换吗？",
            isPresented: Binding(
                get: { flow.replaceConfirmation != nil },
                set: { if !$0 { flow.replaceConfirmation = nil } }
            )
        ) {
            Button("替换", role: .destructive) {
                flow.confirmReplace(servers: servers, account: account)
            }
            Button("取消", role: .cancel) {
                flow.replaceConfirmation = nil
            }
        }
    }

    @ViewBuilder
    private func content(for desktop: AccountDesktop) -> some View {
        switch flow.phase {
        case .awaitingApproval(let sasCode):
            VStack(spacing: 8) {
                Text("请在电脑上点击“连接”确认")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                Text("核对码 \(sasCode)")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(cardBackground)
        case .failed(let message):
            errorRow(message)
            HStack(spacing: 10) {
                actionButton("重试", prominent: true, enabled: true) {
                    flow.retry(servers: servers, account: account)
                }
            }
            codePairingLink
        case .choosing, .connecting:
            desktopList
            channelButtons(for: desktop)
        }
    }

    private var desktopList: some View {
        VStack(spacing: 0) {
            ForEach(Array(desktops.enumerated()), id: \.element.id) { index, desktop in
                if index > 0 {
                    Divider().padding(.leading, 14)
                }
                let isSelected = flow.selectedDesktop(in: desktops)?.id == desktop.id
                Button {
                    flow.selectedHostId = desktop.hostId
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Text(desktop.displayName)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let badge = desktop.osBadge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if desktops.count > 1 && isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(desktops.count < 2 || flow.phase != .choosing)
            }
        }
        .background(cardBackground)
    }

    private func channelButtons(for desktop: AccountDesktop) -> some View {
        let lanAvailable = servers.lanOrigin(forHostId: desktop.hostId) != nil
        let busy = flow.phase != .choosing
        var notes: [String] = []
        if !account.canUseCloudRelay {
            notes.append("账号未开通云服务")
        }
        if !lanAvailable {
            notes.append(servers.discoveringHosts ? "正在搜索局域网…" : "当前 Wi-Fi 未发现这台电脑")
        }
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                actionButton("使用云服务", prominent: true, enabled: account.canUseCloudRelay && !busy, inProgress: flow.phase == .connecting(.cloud)) {
                    flow.connect(desktop, via: .cloud, servers: servers, account: account)
                }
                actionButton("局域网", prominent: false, enabled: lanAvailable && !busy, inProgress: flow.phase == .connecting(.lan)) {
                    flow.connect(desktop, via: .lan, servers: servers, account: account)
                }
            }
            if !notes.isEmpty {
                Text(notes.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var noDesktopGuide: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color.secondary)
            Text("在电脑上安装 VibeX 并登录同一账号")
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
            Button("下载 VibeX") {
                VibeXAccountStore.openSitePath("/download")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            codePairingLink
        }
        .padding(.vertical, 8)
    }

    private var codePairingLink: some View {
        Button("使用连接码配对") {
            flow.switchToCodePairing()
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
            Text(message)
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

    private func actionButton(
        _ title: String,
        prominent: Bool,
        enabled: Bool,
        inProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if inProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(prominent ? .white : .secondary)
                } else {
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                }
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(prominent ? Color.accentColor : Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled || inProgress ? 1 : 0.45)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )
    }
}
