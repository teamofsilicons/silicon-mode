import Foundation

/// The cell's hosted sign-in (docs/research/cells.md §2.3). Cells only accept http(s) redirects,
/// so the cell sends the tokens (in the URL fragment) to the https bounce page
/// `mode.teamofsilicons.com/auth/ios`, which forwards them to `ai.tos.mode://auth/callback#…`.
/// `ASWebAuthenticationSession` intercepts that custom-scheme hop. `.onOpenURL` also sees it when the
/// bounce page was opened anywhere else (say the sign-in finished in Safari), but only while a sign-in
/// this app started is pending ([PendingSignIn]): any web page can link to `ai.tos.mode://auth/…`.
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
        /// An app-authored message (never text taken from the callback URL).
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
            if e == "access_denied" { return .denied }
            // `error_description` is free text anyone can put in a link: don't show it. A short
            // error code is safe to name and helps support.
            let code = e.range(of: #"^[a-z0-9_]{1,40}$"#, options: .regularExpression) != nil ? " (\(e))" : ""
            return .failed("Silicon Accounts couldn't sign you in\(code). Try again.")
        }
        guard let access = items["access_token"], !access.isEmpty,
              let refresh = items["refresh_token"], !refresh.isEmpty else {
            return .failed("The sign-in callback had no session.")
        }
        let expires = items["expires_at"].flatMap(Double.init) ?? Date().addingTimeInterval(1700).timeIntervalSince1970
        return .session(CellSession(accessToken: access, refreshToken: refresh, expiresAt: expires))
    }
}

/// "This app started a sign-in": set when the person taps Sign in, cleared when that sign-in ends.
/// A callback that arrives through `.onOpenURL` is only accepted while this is fresh, and only once.
/// Kept in UserDefaults so a sign-in that finishes in Safari still works after the app was relaunched.
struct PendingSignIn {
    static let window: TimeInterval = 15 * 60
    private static let key = "SMPendingSignInAt"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func begin(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    func isPending(now: Date = Date()) -> Bool {
        guard let started = defaults.object(forKey: Self.key) as? Double else { return false }
        let age = now.timeIntervalSince1970 - started
        return age >= 0 && age < Self.window
    }

    /// True once for a sign-in started within `window`; always clears the marker.
    func consume(now: Date = Date()) -> Bool {
        let pending = isPending(now: now)
        clear()
        return pending
    }
}
