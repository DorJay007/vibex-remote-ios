import CompanionCore
import SwiftUI
import UIKit

struct PairView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(\.dismiss) private var dismiss

    var startWithScanner: Bool = false
    var initialOrigin: String? = nil

    @State private var didApplyInitialState = false
    @State private var initialSuccessCount = 0

    var body: some View {
        NavigationStack {
            UnifiedServerConnectView(
                authExpired: false,
                startWithScanner: startWithScanner,
                initialOrigin: initialOrigin,
                onPaired: {
                    dismiss()
                }
            )
            .navigationTitle("配对电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        servers.cancelPendingConnectRequest()
                        dismiss()
                    }
                }
            }
            .onAppear {
                servers.isPresentingPairSheet = true
                guard !didApplyInitialState else { return }
                didApplyInitialState = true
                initialSuccessCount = servers.connectionSuccessCount
            }
            .onDisappear {
                servers.isPresentingPairSheet = false
            }
            .onChange(of: servers.connectionSuccessCount) { _, newCount in
                if didApplyInitialState && newCount > initialSuccessCount {
                    dismiss()
                }
            }
        }
    }
}

#Preview {
    PairView().environment(ServerStore(defaults: UserDefaults(suiteName: "preview")!))
}
