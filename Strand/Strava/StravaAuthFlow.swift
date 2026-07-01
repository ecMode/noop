import Foundation
import AuthenticationServices
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Drives the Strava OAuth consent screen with `ASWebAuthenticationSession` and returns the authorization
/// `code`. The session captures its own redirect via `callbackURLScheme`, so no custom URL scheme needs
/// registering in Info.plist and no `onOpenURL` plumbing is required.
///
/// Redirect is `noopstrava://localhost` — so in their BYO Strava app the user sets **Authorization
/// Callback Domain = `localhost`** (Strava matches the redirect's host). The `noopstrava` scheme is
/// intercepted by the auth session itself.
@MainActor
final class StravaAuthFlow: NSObject, ASWebAuthenticationPresentationContextProviding {

    static let redirectScheme = "noopstrava"
    static let redirectURI = "noopstrava://localhost"
    /// The value the user must enter in their Strava app's "Authorization Callback Domain" field.
    static let callbackDomain = "localhost"

    private var session: ASWebAuthenticationSession?

    enum AuthError: LocalizedError {
        case deniedOrCancelled
        case cantStart
        var errorDescription: String? {
            switch self {
            case .deniedOrCancelled: return "Strava authorization was cancelled or denied."
            case .cantStart: return "Couldn't open the Strava login."
            }
        }
    }

    /// Present the consent screen and resolve with the one-time authorization code, or throw on
    /// cancel / denial / failure.
    func authorize(clientId: String) async throws -> String {
        let url = StravaClient.authorizeURL(clientId: clientId, redirectURI: Self.redirectURI)
        return try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.redirectScheme) { callback, error in
                if error != nil { cont.resume(throwing: AuthError.deniedOrCancelled); return }
                guard let callback,
                      let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                      let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                    cont.resume(throwing: AuthError.deniedOrCancelled); return
                }
                cont.resume(returning: code)
            }
            s.presentationContextProvider = self
            self.session = s
            if !s.start() { cont.resume(throwing: AuthError.cantStart) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        let anchor = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return anchor ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}
