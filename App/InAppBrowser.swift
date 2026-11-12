import AuthenticationServices
import SafariServices
import SwiftUI
import UIKit

/// A site page shown in an in-app Safari sheet.
struct InAppLink: Identifiable {
    let url: URL
    var id: URL { url }
}

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Shows a provider sign-in page in the system auth sheet. No callback scheme is registered, so the sheet
/// only closes when the user closes it or the caller calls `dismiss()`.
@MainActor
final class OAuthSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func present(_ url: URL, onUserClose: @escaping @MainActor () -> Void) -> Bool {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in
            Task { @MainActor in onUserClose() }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        self.session = session
        return session.start()
    }

    func dismiss() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
