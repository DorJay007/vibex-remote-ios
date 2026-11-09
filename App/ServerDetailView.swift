import SwiftUI

struct ServerDetailView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(\.dismiss) private var dismiss
    let profile: ServerProfile
    @State private var confirmingForget = false
    @State private var showingRepairSheet = false

    private var isActive: Bool {
        servers.activeProfile?.id == profile.id
    }

    private var isCloudService: Bool {
        profile.isCloudService
    }

    var body: some View {
        List {
            Section {
                LabeledContent("当前状态") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(statusLabel)
                            .foregroundStyle(statusColor)
                            .fontWeight(.medium)
                    }
                }
                LabeledContent("传输通道") {
                    HStack(spacing: 6) {
                        Text(isCloudService ? "VibeX 云服务" : "LAN 局域网直连")
                            .foregroundStyle(isCloudService ? Color.accentColor : .secondary)
                        if isCloudService {
                            Text("Beta")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                LabeledContent("实时延迟") {
                    Text(latencyLabel)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(isActive && servers.isOnline ? Color.green : .secondary)
                }
            } header: {
                HStack(spacing: 6) {
                    Text("连接诊断")
                    if isCloudService {
                        Text("Beta")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Section {
                if isActive {
                    Button {
                        Task { await servers.refreshActiveTelemetry() }
                    } label: {
                        Label("重新检测连接", systemImage: "arrow.clockwise")
                    }
                } else {
                    Button {
                        servers.setActive(profile.id)
                        dismiss()
                    } label: {
                        Label("设为当前连接电脑", systemImage: "checkmark.circle")
                    }
                }

                Button {
                    showingRepairSheet = true
                } label: {
                    Label("重新配对更新凭据", systemImage: "qrcode.viewfinder")
                }

                Button(role: .destructive) {
                    confirmingForget = true
                } label: {
                    Label("移除此电脑", systemImage: "trash")
                }
            }
        }
        .navigationTitle(profile.displayHost)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if isActive {
                await servers.refreshActiveTelemetry()
            }
        }
        .sheet(isPresented: $showingRepairSheet) {
            PairView(startWithScanner: false, initialOrigin: profile.origin)
        }
        .confirmationDialog("移除此电脑？", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                servers.forget(profile)
                dismiss()
            }
        } message: {
            Text("移除后需重新扫码或输入连接码才能再次连接")
        }
    }

    private var statusColor: Color {
        if !isActive { return .secondary }
        return servers.isOnline ? .green : .orange
    }

    private var statusLabel: String {
        if !isActive { return "已保存" }
        if servers.isOnline { return "在线" }
        return servers.connectionFailureReason ?? "电脑离线"
    }

    private var latencyLabel: String {
        guard isActive, servers.isOnline, let rtt = servers.realtimeRttMs else {
            return "—"
        }
        return "\(rtt) ms"
    }
}
