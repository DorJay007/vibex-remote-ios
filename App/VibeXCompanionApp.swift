import SwiftUI

@main
struct VibeXCompanionApp: App {
    @State private var servers = ServerStore()
    @State private var appearance = AppAppearanceStore()
    @State private var account = VibeXAccountStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(servers)
                .environment(appearance)
                .environment(account)
                .task {
                    account.attach(serverStore: servers)
                }
                .alert(
                    "局域网已断开，是否切换至云服务？",
                    isPresented: Binding(
                        get: { servers.pendingCloudFallback != nil && !servers.isPresentingPairSheet },
                        set: { if !$0 { servers.declineSwitchToCloudFallback() } }
                    ),
                    presenting: servers.pendingCloudFallback
                ) { _ in
                    Button("切换至云服务") {
                        servers.confirmSwitchToCloudFallback()
                    }
                    Button("保持局域网", role: .cancel) {
                        servers.declineSwitchToCloudFallback()
                    }
                } message: { prompt in
                    Text("当前与电脑「\(prompt.hostName)」的局域网直连已断开，但检测到可通过「VibeX 云服务 · Beta」继续连接。是否切换至云服务？")
                }
        }
    }
}
