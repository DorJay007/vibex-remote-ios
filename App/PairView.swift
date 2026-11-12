import CompanionCore
import SwiftUI
import UIKit

struct PairView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(\.dismiss) private var dismiss

    var startWithScanner: Bool = false
    var initialOrigin: String? = nil

    var body: some View {
        NavigationStack {
            PairingCodeForm(
                startWithScanner: startWithScanner,
                initialOrigin: initialOrigin,
                onPaired: { dismiss() }
            )
            .navigationTitle("使用连接码配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { servers.isPresentingPairSheet = true }
            .onDisappear { servers.isPresentingPairSheet = false }
        }
    }
}

/// Pairs with a desktop through its one-time connection code or QR invitation; works without a VibeX account.
struct PairingCodeForm: View {
    @Environment(ServerStore.self) private var servers
    var startWithScanner: Bool = false
    var initialOrigin: String? = nil
    var onPaired: () -> Void

    @State private var quickCode = ""
    @State private var scanning = false
    @State private var submittingCode = false
    @State private var localError: String?
    @State private var localMobileConflict: PendingMobileConflict?
    @State private var didAppear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 24)

                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(Color.secondary)

                inlineCodeAndScanCard

                if let errorText = localError, !errorText.isEmpty {
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
        .onChange(of: servers.connectionSuccessCount) { _, _ in
            onPaired()
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            if startWithScanner {
                scanning = true
            }
        }
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
                    Text("扫码配对")
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
