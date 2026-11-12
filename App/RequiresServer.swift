import CompanionCore
import SwiftUI

/// Gate for tabs that read from the paired computer.
struct RequiresServer<Content: View>: View {
    @Environment(ServerStore.self) private var servers
    @Binding var selection: AppTab
    @ViewBuilder let content: (HostClient) -> Content

    var body: some View {
        if let profile = servers.activeProfile, servers.isSessionConnected, let client = servers.client(for: profile) {
            content(client)
        } else {
            ConnectComputerEmptyState()
        }
    }
}

/// Shown while no computer is connected; one button resumes the account picker, a saved computer, or code pairing.
struct ConnectComputerEmptyState: View {
    @Environment(ServerStore.self) private var servers
    @Environment(VibeXAccountStore.self) private var account
    @Environment(DesktopConnectFlow.self) private var connectFlow

    private var isSyncingAccount: Bool {
        account.isSignedIn && account.desktops.isEmpty && (account.isLoading || account.isSyncingHosts)
    }

    var body: some View {
        VStack(spacing: 16) {
            if isSyncingAccount {
                LoadingState(label: "正在同步你的电脑")
            } else {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(Color.secondary)

                if let message = servers.pairingError, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    connect()
                } label: {
                    Text("连接电脑")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 220)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func connect() {
        servers.pairingError = nil
        if account.isSignedIn {
            connectFlow.presentPicker(servers: servers)
        } else if let profile = servers.activeProfile, servers.client(for: profile) != nil {
            servers.connectSavedProfile(profile)
        } else {
            connectFlow.isCodePairingPresented = true
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
