import SwiftUI

/// Entry page while signed out with no paired computer, or after an explicit sign-out.
struct LoginView: View {
    @Environment(VibeXAccountStore.self) private var account
    @Environment(DesktopConnectFlow.self) private var connectFlow
    @State private var agreed = false

    private var agreementText: AttributedString {
        let terms = VibeXAccountStore.siteURL("/terms")?.absoluteString ?? ""
        let privacy = VibeXAccountStore.siteURL("/privacy")?.absoluteString ?? ""
        let markdown = "我已阅读并同意[《用户协议》](\(terms))和[《隐私政策》](\(privacy))"
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Image("vibex_logo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("VibeX")
                    .font(.system(size: 26, weight: .bold))
            }

            Spacer()

            VStack(spacing: 14) {
                if account.loginState != nil {
                    waitingForBrowser
                } else {
                    Button {
                        Task { await account.startLogin() }
                    } label: {
                        HStack(spacing: 8) {
                            if account.startingLogin {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text("登录 VibeX 账号")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.accentColor)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!agreed || account.startingLogin)
                    .opacity(agreed ? 1 : 0.45)
                }

                if let error = account.authError, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button {
                        agreed.toggle()
                    } label: {
                        Image(systemName: agreed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(agreed ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("同意用户协议和隐私政策")
                    .accessibilityAddTraits(agreed ? .isSelected : [])
                    Text(agreementText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .tint(Color.accentColor)
                }
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 28)

            Spacer()

            Button("使用连接码配对") {
                connectFlow.isCodePairingPresented = true
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var waitingForBrowser: some View {
        VStack(spacing: 10) {
            LoadingState(label: "请在浏览器中完成登录")
            if let code = account.loginState?.userCode, !code.isEmpty {
                Text("设备验证码 \(code)")
                    .font(.system(size: 13, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("取消") {
                    account.cancelLogin()
                }
                .buttonStyle(.bordered)
                Button("重新打开授权页") {
                    account.reopenVerifyURL()
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
    }
}
