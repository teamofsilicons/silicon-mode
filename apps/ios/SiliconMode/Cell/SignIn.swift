import Foundation

/// The cell's hosted sign-in (docs/research/cells.md §2.3). Cells only accept http(s) redirects,
/// so the cell sends the tokens (in the URL fragment) to the https bounce page
/// `mode.teamofsilicons.com/auth/ios`, which forwards them to `ai.tos.mode://auth/callback#…`.
/// `ASWebAuthenticationSession` intercepts that custom-scheme hop; `.onOpenURL` handles it if the
/// bounce page was opened anywhere else (and it is how the simulator test delivers a session).
enum SignIn {
    static let callbackScheme = "ai.tos.mode"
    static let bounce = "https://mode.teamofsilicons.com/auth/ios"

    static var url: URL {
        var c = URLComponents(url: CellConfig.base.appending(path: "auth/sign-in"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "redirect_to", value: bounce),
                        URLQueryItem(name: "session", value: "token"),
                        URLQueryItem(name: "app", value: "silicon-mode")]
        return c.url!
    }

    enum Outcome: Equatable {
        case session(CellSession)
        case denied
        case failed(String)
    }

    static func isAuthCallback(_ url: URL) -> Bool {
        url.scheme == callbackScheme && (url.host() == "auth" || url.path().hasPrefix("/auth") || url.path().hasPrefix("auth"))
    }

    /// `ai.tos.mode://auth/callback#access_token=…&refresh_token=csr_…&expires_at=…`
    /// or `…?error=access_denied`.
    static func parse(_ url: URL) -> Outcome {
        var items: [String: String] = [:]
        func absorb(_ s: String?) {
            guard let s, !s.isEmpty else { return }
            var c = URLComponents()
            c.percentEncodedQuery = s
            for q in c.queryItems ?? [] { items[q.name] = q.value ?? "" }
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        absorb(comps?.percentEncodedQuery)
        absorb(comps?.percentEncodedFragment)
        if let e = items["error"] {
            return e == "access_denied" ? .denied : .failed(items["error_description"] ?? e)
        }
        guard let access = items["access_token"], !access.isEmpty,
              let refresh = items["refresh_token"], !refresh.isEmpty else {
            return .failed("The sign-in callback had no session.")
        }
        let expires = items["expires_at"].flatMap(Double.init) ?? Date().addingTimeInterval(1700).timeIntervalSince1970
        return .session(CellSession(accessToken: access, refreshToken: refresh, expiresAt: expires))
    }
}
