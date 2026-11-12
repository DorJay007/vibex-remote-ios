import CompanionCore
import SwiftUI
import UIKit

enum AppTab: Hashable, CaseIterable, Identifiable {
    case conversations
    case board
    case space
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .conversations: return "对话"
        case .board: return "看板"
        case .space: return "协作空间"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .conversations: return "message"
        case .board: return "square.grid.2x2"
        case .space: return "person.2"
        case .settings: return "gearshape"
        }
    }

    var selectedIcon: String {
        switch self {
        case .conversations: return "message.fill"
        case .board: return "square.grid.2x2.fill"
        case .space: return "person.2.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootTabView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(AppAppearanceStore.self) private var appearance
    @Namespace private var tabNamespace
    @State private var selection: AppTab = .conversations
    @State private var attentionCenter = CompanionAttentionCenter()
    @State private var isConversationsChromeHidden = false
    @State private var isBoardChromeHidden = false
    @State private var isSpaceChromeHidden = false
    @State private var isLaunchRevealed = false
    @State private var isKeyboardVisible = false

    private var activeClient: HostClient? {
        guard let profile = servers.activeProfile else { return nil }
        return servers.client(for: profile)
    }

    private var shouldShowBottomBar: Bool {
        if isKeyboardVisible { return false }
        switch selection {
        case .conversations:
            return !isConversationsChromeHidden
        case .board:
            return !isBoardChromeHidden
        case .space:
            return !isSpaceChromeHidden
        case .settings:
            return true
        }
    }

    private var isBottomBarRevealed: Bool {
        isLaunchRevealed || servers.activeProfile == nil || selection != .conversations
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                RequiresServer(selection: $selection) { client in
                    ConversationsView(
                        client: client,
                        onChromeHiddenChange: { hidden in
                            withAnimation(.smooth(duration: 0.2)) {
                                isConversationsChromeHidden = hidden
                            }
                        },
                        onLaunchRevealedChange: { revealed in
                            withAnimation(.spring(response: 1.05, dampingFraction: 0.86, blendDuration: 0.2)) {
                                isLaunchRevealed = revealed
                            }
                        },
                        onSelectTab: { targetTab in
                            withAnimation(.smooth(duration: 0.16)) {
                                selection = targetTab
                            }
                        }
                    )
                }
                .opacity(selection == .conversations ? 1 : 0)
                .allowsHitTesting(selection == .conversations)

                if selection == .board {
                    RequiresServer(selection: $selection) {
                        BoardView(
                            client: $0,
                            onChromeHiddenChange: { hidden in
                                withAnimation(.smooth(duration: 0.2)) {
                                    isBoardChromeHidden = hidden
                                }
                            }
                        )
                    }
                    .transition(.opacity)
                } else if selection == .space {
                    RequiresServer(selection: $selection) {
                        CollaborationSpaceView(
                            client: $0,
                            onChromeHiddenChange: { hidden in
                                withAnimation(.smooth(duration: 0.2)) {
                                    isSpaceChromeHidden = hidden
                                }
                            }
                        )
                    }
                    .transition(.opacity)
                } else if selection == .settings {
                    SettingsView()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shouldShowBottomBar {
                    Color.clear.frame(height: 66)
                }
            }

            if shouldShowBottomBar {
                bottomNavigationBar
                    .opacity(isBottomBarRevealed ? 1 : 0)
                    .offset(y: isBottomBarRevealed ? 0 : 36)
                    .blur(radius: isBottomBarRevealed ? 0 : 3)
                    .allowsHitTesting(isBottomBarRevealed)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environment(attentionCenter)
        .overlay(alignment: .top) {
            if let client = activeClient {
                CompanionToastOverlay(
                    client: client,
                    center: attentionCenter,
                    onOpenConversation: { conversation in
                        selection = .conversations
                        attentionCenter.openConversation(conversation)
                    }
                )
            }
        }
        .task(id: servers.activeProfile?.id) {
            guard let client = activeClient else { return }
            while !Task.isCancelled {
                await attentionCenter.poll(client: client)
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) {
                isKeyboardVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) {
                isKeyboardVisible = false
            }
        }
        .dynamicTypeSize(appearance.fontSizePreset.dynamicTypeSize)
        .fontDesign(appearance.fontStylePreset.fontDesign)
        .preferredColorScheme(appearance.themeMode.colorScheme)
        .onAppear {
            appearance.applyInterfaceStyleToAllWindows(appearance.themeMode.uiInterfaceStyle)
        }
        .onChange(of: selection) { _, newTab in
            dismissKeyboard()
            if newTab == .conversations {
                NotificationCenter.default.post(name: Notification.Name("vibex.didReturnToConversationsTab"), object: nil)
            }
        }
        .background(
            GlobalInteractionInstaller()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }

    private var bottomNavigationBar: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = selection == tab
                Button {
                    if selection != tab {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            selection = tab
                        }
                    }
                } label: {
                    VStack(spacing: 2.5) {
                        Image(systemName: isSelected ? tab.selectedIcon : tab.icon)
                            .font(.system(size: 16.5, weight: isSelected ? .semibold : .regular))
                            .frame(height: 19)

                        Text(tab.title)
                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(0.11))
                                .matchedGeometryEffect(id: "activeTabPill", in: tabNamespace)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            .ultraThinMaterial,
            in: Capsule(style: .continuous)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.24),
                            Color.primary.opacity(0.08),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
    }
}

#Preview {
    RootTabView()
        .environment(ServerStore(defaults: UserDefaults(suiteName: "preview")!))
        .environment(AppAppearanceStore(defaults: UserDefaults(suiteName: "preview")!))
}
