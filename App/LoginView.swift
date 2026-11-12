import CompanionCore
import SwiftUI

/// In-app VibeX account login, mirroring the site's login card. Shown as the entry page while signed out
/// and pushed from account settings.
struct LoginView: View {
    var allowsCodePairing = true

    @Environment(VibeXAccountStore.self) private var account
    @Environment(DesktopConnectFlow.self) private var connectFlow
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case password = "密码登录"
        case code = "验证码登录"
        var id: Self { self }
    }

    private enum Field: Hashable {
        case login, password, codeTarget, code
    }

    private enum Action: Equatable {
        case form
        case oauth(AccountOAuthProvider)
    }

    @State private var mode: Mode = .password
    @State private var login = ""
    @State private var password = ""
    @State private var codeTarget = ""
    @State private var code = ""
    @State private var agreed = false
    @State private var errorMessage: String?
    @State private var activeAction: Action?
    @State private var sendingCode = false
    @State private var codeSent = false
    @State private var resendAvailableAt: Date?
    @State private var link: InAppLink?
    @FocusState private var focus: Field?

    private var trimmedLogin: String { login.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCodeTarget: String { codeTarget.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var credential: AccountLoginCredential? {
        switch mode {
        case .password:
            guard !trimmedLogin.isEmpty, !password.isEmpty else { return nil }
            return .password(login: trimmedLogin, password: password)
        case .code:
            guard !trimmedCodeTarget.isEmpty, !trimmedCode.isEmpty else { return nil }
            return .code(login: trimmedCodeTarget, code: trimmedCode)
        }
    }

    private var busy: Bool { activeAction != nil || account.signingIn }

    private var agreementText: AttributedString {
        let terms = VibeXAccountStore.siteURL(VibeXAccountStore.termsPath)?.absoluteString ?? ""
        let privacy = VibeXAccountStore.siteURL(VibeXAccountStore.privacyPolicyPath)?.absoluteString ?? ""
        let markdown = "我已阅读并同意[《用户协议》](\(terms))和[《隐私政策》](\(privacy))"
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    card
                    Spacer(minLength: 28)
                    if allowsCodePairing {
                        Button("使用连接码配对") {
                            connectFlow.isCodePairingPresented = true
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                    }
                }
                .frame(maxWidth: 380)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(.systemGroupedBackground))
        .environment(
            \.openURL,
            OpenURLAction { url in
                link = InAppLink(url: url)
                return .handled
            }
        )
        .sheet(item: $link) { link in
            SafariSheet(url: link.url)
                .ignoresSafeArea()
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
    }

    private var card: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image("vibex_logo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("欢迎回来")
                    .font(.system(size: 24, weight: .bold))
                Text("登录你的 VibeX 账号")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Picker("登录方式", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, _ in
                errorMessage = nil
                focus = nil
            }

            VStack(spacing: 14) {
                switch mode {
                case .password: passwordFields
                case .code: codeFields
                }
            }

            if let errorMessage {
                errorBanner(errorMessage)
            }

            primaryButton("登录", inProgress: activeAction == .form, enabled: agreed && credential != nil && !busy) {
                submit()
            }

            HStack(spacing: 10) {
                dividerLine
                Text("或")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                dividerLine
            }

            VStack(spacing: 10) {
                oauthButton(.google, title: "使用 Google 登录", mark: Image("brand_google"))
                oauthButton(.github, title: "使用 GitHub 登录", mark: Image("brand_github"))
            }

            agreementRow

            HStack(spacing: 2) {
                Text("还没有账号？")
                    .foregroundStyle(.secondary)
                Button("注册") { open("/register") }
                    .foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 13))
        }
    }

    private var passwordFields: some View {
        Group {
            labeledField("邮箱 / 手机号 / 用户名") {
                TextField("", text: $login)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .login)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
            }
            VStack(alignment: .trailing, spacing: 8) {
                labeledField("密码") {
                    SecureField("", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(submit)
                }
                Button("忘记密码") { open("/recover") }
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var codeFields: some View {
        Group {
            labeledField("邮箱或手机号") {
                HStack(spacing: 8) {
                    TextField("", text: $codeTarget)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .codeTarget)
                        .submitLabel(.next)
                        .onSubmit { focus = .code }
                        .onChange(of: codeTarget) { _, _ in codeSent = false }
                    sendCodeButton
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                labeledField("验证码") {
                    TextField("", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .focused($focus, equals: .code)
                        .monospacedDigit()
                }
                if codeSent {
                    Text("验证码已发送，10 分钟内有效")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sendCodeButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = resendAvailableAt.map { Int($0.timeIntervalSince(context.date).rounded(.up)) } ?? 0
            Button {
                sendCode()
            } label: {
                Group {
                    if sendingCode {
                        ProgressView()
                            .controlSize(.small)
                    } else if remaining > 0 {
                        Text("\(remaining)s 后重发")
                            .monospacedDigit()
                    } else {
                        Text("发送验证码")
                    }
                }
                .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(remaining > 0 ? Color.secondary : Color.accentColor)
            .disabled(remaining > 0 || sendingCode || trimmedCodeTarget.isEmpty)
            .opacity(trimmedCodeTarget.isEmpty && remaining <= 0 ? 0.45 : 1)
        }
        .fixedSize()
    }

    private var agreementRow: some View {
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

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 0.75)
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            content()
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                        )
                )
        }
    }

    private func primaryButton(
        _ title: String,
        inProgress: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if inProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(title)
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
        .disabled(!enabled)
        .opacity(enabled || inProgress ? 1 : 0.45)
    }

    private func oauthButton(_ provider: AccountOAuthProvider, title: String, mark: Image) -> some View {
        let inProgress = activeAction == .oauth(provider)
        let enabled = agreed && !busy
        return Button {
            run(.oauth(provider)) { try await account.signIn(with: provider) }
        } label: {
            HStack(spacing: 8) {
                if inProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    mark
                        .resizable()
                        .scaledToFit()
                        .frame(width: 17, height: 17)
                }
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled || inProgress ? 1 : 0.45)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .multilineTextAlignment(.leading)
        }
        .font(.footnote)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
    }

    private func open(_ path: String) {
        guard let url = VibeXAccountStore.siteURL(path) else { return }
        link = InAppLink(url: url)
    }

    private func submit() {
        guard agreed, !busy, let credential else { return }
        focus = nil
        run(.form) { try await account.signIn(credential) }
    }

    private func run(_ action: Action, _ work: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil
        activeAction = action
        Task { @MainActor in
            defer { activeAction = nil }
            do {
                try await work()
            } catch is CancellationError {
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func sendCode() {
        let target = trimmedCodeTarget
        guard !target.isEmpty, !sendingCode else { return }
        errorMessage = nil
        sendingCode = true
        Task { @MainActor in
            defer { sendingCode = false }
            do {
                try await account.sendLoginCode(to: target)
                codeSent = true
                resendAvailableAt = Date().addingTimeInterval(TimeInterval(AccountLoginClient.codeResendSeconds))
                focus = .code
            } catch {
                errorMessage = Self.message(for: error)
                if let retryAfter = (error as? AccountAuthError)?.retryAfter, retryAfter > 0 {
                    resendAvailableAt = Date().addingTimeInterval(TimeInterval(retryAfter))
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? AccountAuthError ?? AccountAuthError(code: "unknown")).message
    }
}
