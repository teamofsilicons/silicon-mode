import Foundation
import AppKit
import SiliconModeKit

/// Silicon Accounts sign-in (optional; needed for marketplace faces and the phone/web apps).
///
/// `signIn()` opens the cell's hosted sign-in in the default browser with
/// `redirect_to=http://127.0.0.1:47291/auth/callback`; a loopback server (alive only while
/// signing in, 10 min max) receives the tokens. `ai.tos.mode://auth/callback#access_token=…`
/// (web bounce page) is accepted through `handleCallback(_:)` while a sign-in is in progress.
/// The session lives in the Keychain (`ai.tos.mode.session`) and is owned by `CellClient`.
@MainActor @Observable
final class AccountManager {
    struct Account: Codable, Equatable {
        var uuid: String
        var id: String
        var displayName: String
        var pfpURL: String?
        var kind: String? = nil

        init(uuid: String, id: String, displayName: String, pfpURL: String?, kind: String? = nil) {
            self.uuid = uuid; self.id = id; self.displayName = displayName; self.pfpURL = pfpURL; self.kind = kind
        }
        init(_ u: CellUser) { self.init(uuid: u.uuid, id: u.id, displayName: u.displayName, pfpURL: u.pfpURL, kind: u.kind) }

        var isSilicon: Bool { kind == "silicon" || id.hasPrefix("si:") }
        /// One or two letters for the avatar fallback.
        var initials: String {
            let words = displayName.split(separator: " ").prefix(2)
            let s = words.compactMap(\.first).map(String.init).joined()
            return (s.isEmpty ? String(id.drop { $0 != ":" }.dropFirst().prefix(1)) : s).uppercased()
        }
    }

    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn
        case error(String)
    }

    private(set) var account: Account?
    private(set) var state: State = .signedOut
    var isSignedIn: Bool { account != nil }
    var isSigningIn: Bool { state == .signingIn }
    var errorMessage: String? { if case .error(let m) = state { return m }; return nil }

    @ObservationIgnored let client: CellClient
    /// Opens the sign-in page (overridable for tests).
    @ObservationIgnored var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Awaited before the session is revoked (CloudSync marks this Mac offline).
    @ObservationIgnored var willSignOut: (@MainActor () async -> Void)?

    @ObservationIgnored private var server: LoopbackAuthServer?
    /// A finished sign-in's listener, kept a moment so the page's POST response flushes.
    @ObservationIgnored private var retiringServer: LoopbackAuthServer?
    @ObservationIgnored private var signInDeadline: Task<Void, Never>?
    @ObservationIgnored private var signInURL: URL?
    @ObservationIgnored private var observers: [UUID: @MainActor (Bool) -> Void] = [:]
    @ObservationIgnored private var restoring = false
    /// Sign-in window (the cell's own flow cookie also lives 10 min).
    @ObservationIgnored var signInTimeout: Duration = .seconds(600)

    init(client: CellClient = .shared) {
        self.client = client
        Task { [client, weak self] in
            await client.onSessionEnded { reason in
                Task { @MainActor in self?.sessionEnded(reason) }
            }
        }
    }

    // MARK: Observers (CloudSync)

    /// Called with `true` when a session becomes available and `false` when it goes away.
    @discardableResult
    func addSessionObserver(_ f: @escaping @MainActor (Bool) -> Void) -> UUID {
        let id = UUID()
        observers[id] = f
        return id
    }

    func removeSessionObserver(_ id: UUID) { observers[id] = nil }

    private func notify(_ signedIn: Bool) { for f in observers.values { f(signedIn) } }

    // MARK: Lifecycle

    /// Load the Keychain session (off the main thread) and refresh the profile in the background.
    func restore() {
        guard !restoring, account == nil else { return }
        restoring = true
        Task {
            defer { restoring = false }
            guard let stored = await client.restore() else { return }
            if let u = stored.user {
                account = Account(u)
                state = .signedIn
                notify(true)
            }
            do {
                let u = try await client.fetchUser()
                let fresh = Account(u)
                let wasSignedIn = account != nil
                if account != fresh { account = fresh }
                state = .signedIn
                if !wasSignedIn { notify(true) }
            } catch let e as CellError {
                if case .sessionEnded = e { return }   // sessionEnded() already updated state
                if account == nil {
                    // No cached profile and offline: keep trying quietly via CloudSync later.
                    SyncLog.info("profile load failed: \(e)")
                }
            } catch {}
        }
    }

    /// Opens the hosted sign-in in the default browser. Calling again while signing in re-opens it.
    func signIn() {
        if state == .signingIn, let u = signInURL { openURL(u); return }
        state = .signingIn
        Task { await startSignIn(openBrowser: true) }
    }

    /// Starts a sign-in (loopback listener + deadline). `openBrowser: false` is for tests.
    func startSignIn(openBrowser: Bool) async {
        state = .signingIn
        stopServer()
        retiringServer?.stop(); retiringServer = nil
        let server = LoopbackAuthServer { [weak self] fragment, query in
            await self?.complete(fragment: fragment, query: query)
                ?? LoopbackResult(ok: false, title: "Silicon Mode quit", message: "Open Silicon Mode and try again.")
        }
        var redirect = CellConfig.loopbackRedirect
        do {
            try await server.start()
            self.server = server
        } catch {
            // Port busy (another copy of the app?): fall back to the web bounce page → ai.tos.mode://
            SyncLog.error("loopback listener failed (\(error)); using the web bounce page")
            redirect = CellConfig.bounceRedirect
        }
        guard state == .signingIn else { stopServer(); return }   // cancelled meanwhile
        let url = CellConfig.signInURL(redirectTo: redirect)
        signInURL = url
        signInDeadline?.cancel()
        let timeout = signInTimeout
        signInDeadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.state == .signingIn else { return }
            self.stopServer()
            self.state = .error("Sign-in timed out. Try again.")
        }
        if openBrowser { openURL(url) }
    }

    func cancelSignIn() {
        guard state == .signingIn else { return }
        finishSignInWindow()
        state = account == nil ? .signedOut : .signedIn
    }

    func signOut() {
        finishSignInWindow()
        let had = account != nil
        account = nil
        state = .signedOut
        let hook = willSignOut
        Task {
            // CloudSync is still running here: it marks this Mac offline with the live token.
            if had, let hook { await hook() }
            await client.signOut()
            if had { notify(false) }
        }
    }

    /// `ai.tos.mode://auth/callback#access_token=…&refresh_token=…&expires_at=…`
    func handleCallback(_ url: URL) {
        guard url.scheme?.lowercased() == CellConfig.urlScheme else { return }
        let host = url.host()?.lowercased() ?? ""
        guard host == "auth" || url.path().hasPrefix("/auth") || url.path().hasPrefix("auth") else { return }
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let fragment = c?.percentEncodedFragment ?? ""
        let query = c?.percentEncodedQuery ?? ""
        // Only accept tokens for a sign-in this Mac started (blocks login-CSRF via crafted links).
        guard state == .signingIn else {
            SyncLog.error("ignored auth callback: no sign-in in progress")
            return
        }
        Task { _ = await complete(fragment: fragment, query: query) }
    }

    // MARK: Completion

    /// Adopt the tokens from the redirect, load the profile, persist, notify.
    func complete(fragment: String, query: String) async -> LoopbackResult {
        guard state == .signingIn else {
            if let a = account {
                return LoopbackResult(ok: true, title: "You're signed in",
                                      message: "You can close this tab and head back to Silicon Mode.",
                                      name: a.displayName, handle: a.id)
            }
            return LoopbackResult(ok: false, title: "Sign-in expired", message: "Start again from the Silicon Mode menu bar.")
        }
        switch CallbackPayload.parse(fragment: fragment, query: query) {
        case .denied(let why):
            finishSignInWindow()
            state = account == nil ? .signedOut : .signedIn
            let cancelled = why.hasPrefix("access_denied")
            return LoopbackResult(ok: false, title: cancelled ? "Sign-in cancelled" : "Sign-in didn't finish",
                                  message: cancelled ? "Nothing changed. You can start again from the Silicon Mode menu bar."
                                                     : "The account service said: \(why). Try again from the menu bar.")
        case .invalid:
            return LoopbackResult(ok: false, title: "Sign-in didn't finish",
                                  message: "The sign-in response was incomplete. Start again from the Silicon Mode menu bar.")
        case .tokens(let session):
            do {
                let previous = account
                try await client.adopt(session)
                let user = try await client.fetchUser()
                let acc = Account(user)
                finishSignInWindow()
                account = acc
                state = .signedIn
                if previous == nil || previous?.uuid != acc.uuid { notify(true) }
                return LoopbackResult(ok: true, title: "You're signed in",
                                      message: "You can close this tab. Silicon Mode will keep your phone and the web up to date.",
                                      name: acc.displayName, handle: acc.id)
            } catch {
                await client.clear()
                finishSignInWindow()
                let msg = (error as? CellError).map {
                    $0.isRetryable ? "Couldn't reach Silicon Accounts. Check your connection and try again."
                                   : "Silicon Accounts didn't accept this sign-in. Try again."
                } ?? "Something went wrong. Try again."
                state = .error(msg)
                if account != nil { account = nil; notify(false) }
                return LoopbackResult(ok: false, title: "Sign-in didn't finish", message: msg)
            }
        }
    }

    private func sessionEnded(_ reason: String) {
        guard account != nil || state == .signedIn else { return }
        account = nil
        state = .error("You were signed out. Sign in again to keep syncing.")
        notify(false)
    }

    private func finishSignInWindow() {
        signInDeadline?.cancel(); signInDeadline = nil
        signInURL = nil
        // Let the page's POST response flush before the listener goes away.
        guard let s = server else { return }
        server = nil
        retiringServer = s
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            s.stop()
            if self?.retiringServer === s { self?.retiringServer = nil }
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
    }
}
