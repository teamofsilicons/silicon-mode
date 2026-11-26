import Foundation
import AppKit
import SiliconModeKit

/// Silicon Accounts sign-in (optional; needed for marketplace faces and the phone/web apps).
///
/// `signIn()` starts a loopback server (alive only while signing in, 10 min max) and opens
/// `http://127.0.0.1:47291/auth/start#<flow key>` in the default browser; that page continues to
/// the cell's hosted sign-in with `redirect_to=http://127.0.0.1:47291/auth/callback`.
///
/// Only tokens tied to *this* attempt are adopted without asking (login-CSRF: otherwise any web page
/// or local process could sign this Mac into its own account during the window, then receive the
/// agents' logs and answer their questions):
/// - **bound**: the callback carried the attempt's flow key, which reached the browser only inside
///   the start URL this Mac opened and lives in that tab's sessionStorage (LoopbackAuthServer);
/// - **unbound**: anything else, i.e. another tab or browser, a local process, or the web bounce page's
///   `ai.tos.mode://auth/callback#…` (used only when port 47291 is taken). The tokens are checked
///   in memory (`/auth/user`) and adopted only after the person confirms that account.
/// A sign-out finishes (offline marker, revoke, Keychain wipe) before a new sign-in can complete.
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

    /// How a sign-in callback reached the app.
    enum CallbackBinding: Sendable, Equatable {
        /// Carried this attempt's flow key: it comes from the browser tab this Mac opened.
        case bound
        /// Can't be tied to this attempt: the person has to confirm the account first.
        case unbound
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
    /// Asks the person whether to sign in as an account whose callback can't be tied to the attempt
    /// this Mac started (overridable for tests). `true` = sign in.
    @ObservationIgnored var confirmUnboundSignIn: @MainActor (Account) async -> Bool = { await SignInConfirmation.ask($0) }
    /// Loopback port. The cell only accepts the default; tests use another one.
    @ObservationIgnored var loopbackPort: UInt16 = CellConfig.loopbackPort
    /// Sign-in window (the cell's own flow cookie also lives 10 min).
    @ObservationIgnored var signInTimeout: Duration = .seconds(600)

    /// The URL the current attempt opened in the browser (start page, or the cell's sign-in when the
    /// web bounce is used). Re-opened by `signIn()` while signing in.
    @ObservationIgnored private(set) var signInURL: URL?

    private struct Attempt {
        enum Mode { case loopback, bounce }
        let id = UUID()
        let mode: Mode
    }

    @ObservationIgnored private var attempt: Attempt?
    /// Identifies the newest `startSignIn` call (a cancel or a newer call makes older ones stand down).
    @ObservationIgnored private var startTicket: UUID?
    @ObservationIgnored private var server: LoopbackAuthServer?
    /// A finished sign-in's listener, kept a moment so the page's POST response flushes.
    @ObservationIgnored private var retiringServer: LoopbackAuthServer?
    @ObservationIgnored private var signInDeadline: Task<Void, Never>?
    @ObservationIgnored private var signOutTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [UUID: @MainActor (Bool) -> Void] = [:]
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var completing = false
    @ObservationIgnored private var confirming = false

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
            if let t = signOutTask { await t.value }
            guard account == nil, let stored = await client.restore() else { return }
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
        if state == .signingIn {
            if let u = signInURL { openURL(u) }
            return   // still starting: the browser opens in a moment
        }
        state = .signingIn
        Task { await startSignIn(openBrowser: true) }
    }

    /// Starts a sign-in (loopback listener + deadline). `openBrowser: false` is for tests.
    func startSignIn(openBrowser: Bool) async {
        state = .signingIn
        let ticket = UUID()
        startTicket = ticket
        // A sign-out still revoking/wiping the old session must finish first, or it could wipe the new one.
        if let t = signOutTask { await t.value }
        guard state == .signingIn, startTicket == ticket else { return }
        closeAttempt()
        // The previous attempt's listener still holds the port while its last response flushes.
        retiringServer?.stop(); retiringServer = nil

        let port = loopbackPort
        let flowKey = LoopbackAuthServer.randomKey()
        let handler: LoopbackAuthServer.Handler = { [weak self] fragment, query, bound in
            await self?.complete(fragment: fragment, query: query, binding: bound ? .bound : .unbound)
                ?? LoopbackResult(ok: false, title: "Silicon Mode quit", message: "Open Silicon Mode and try again.")
        }
        var server: LoopbackAuthServer?
        for tries in 1...3 {
            let s = LoopbackAuthServer(port: port, flowKey: flowKey,
                                       signInURL: CellConfig.signInURL(redirectTo: CellConfig.loopbackRedirect(port: port)),
                                       handler: handler)
            do {
                try await s.start()
                server = s
                break
            } catch {
                s.stop()
                if tries == 3 {
                    // Port busy (another copy of the app?): fall back to the web bounce page → ai.tos.mode://
                    SyncLog.error("loopback listener failed (\(error)); using the web bounce page")
                } else {
                    try? await Task.sleep(for: .milliseconds(150))   // a just-stopped listener releasing it
                }
            }
        }
        let mode: Attempt.Mode = server == nil ? .bounce : .loopback
        let url = server?.startURL ?? CellConfig.signInURL(redirectTo: CellConfig.bounceRedirect)
        guard state == .signingIn, startTicket == ticket else { server?.stop(); return }   // cancelled meanwhile
        self.server = server
        let a = Attempt(mode: mode)
        attempt = a
        signInURL = url
        signInDeadline?.cancel()
        let timeout = signInTimeout
        signInDeadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.state == .signingIn, self.attempt?.id == a.id else { return }
            self.closeAttempt()
            self.state = .error("Sign-in timed out. Try again.")
        }
        if openBrowser { openURL(url) }
    }

    func cancelSignIn() {
        guard state == .signingIn else { return }
        startTicket = nil
        closeAttempt()
        state = account == nil ? .signedOut : .signedIn
    }

    func signOut() {
        startTicket = nil
        closeAttempt()
        let had = account != nil
        account = nil
        state = .signedOut
        let hook = willSignOut
        let previous = signOutTask
        signOutTask = Task { [client] in
            await previous?.value
            // CloudSync is still running here: it marks this Mac offline with the live token.
            if had, let hook { await hook() }
            await client.signOut()
            if had { self.notify(false) }
        }
    }

    /// CloudSync found no stored session while an account is shown (it was lost underneath us).
    func sessionLost() { sessionEnded("session_missing") }

    /// `ai.tos.mode://auth/callback#access_token=…&refresh_token=…&expires_at=…` (web bounce page).
    func handleCallback(_ url: URL) {
        guard url.scheme?.lowercased() == CellConfig.urlScheme else { return }
        let host = url.host()?.lowercased() ?? ""
        guard host == "auth" || url.path().hasPrefix("/auth") || url.path().hasPrefix("auth") else { return }
        // Only while a sign-in this Mac started is using the bounce page (blocks crafted links while the
        // loopback is in use), and even then the account must be confirmed: any app or web page can open
        // this URL.
        guard state == .signingIn, attempt?.mode == .bounce else {
            SyncLog.error("ignored auth callback: no web sign-in in progress")
            return
        }
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let fragment = c?.percentEncodedFragment ?? ""
        let query = c?.percentEncodedQuery ?? ""
        Task { _ = await complete(fragment: fragment, query: query, binding: .unbound) }
    }

    // MARK: Completion

    /// Check the tokens from the redirect (in memory), confirm unbound ones with the person, then
    /// persist, publish and notify.
    func complete(fragment: String, query: String, binding: CallbackBinding) async -> LoopbackResult {
        guard state == .signingIn, let current = attempt else {
            return LoopbackResult(ok: false, title: "This sign-in already finished",
                                  message: "Check Silicon Mode. To sign in again, start from its menu bar.")
        }
        switch CallbackPayload.parse(fragment: fragment, query: query) {
        case .denied(let why):
            // Only the tab this Mac opened may cancel its sign-in.
            guard binding == .bound else {
                return LoopbackResult(ok: false, title: "Sign-in didn't finish",
                                      message: "Start again from the Silicon Mode menu bar.")
            }
            closeAttempt()
            state = account == nil ? .signedOut : .signedIn
            let cancelled = why.hasPrefix("access_denied")
            return LoopbackResult(ok: false, title: cancelled ? "Sign-in cancelled" : "Sign-in didn't finish",
                                  message: cancelled ? "Nothing changed. You can start again from the Silicon Mode menu bar."
                                                     : "The account service said: \(why). Try again from the menu bar.")
        case .invalid:
            return LoopbackResult(ok: false, title: "Sign-in didn't finish",
                                  message: "The sign-in response was incomplete. Start again from the Silicon Mode menu bar.")
        case .tokens(let session):
            return await adopt(session, binding: binding, attempt: current)
        }
    }

    private func adopt(_ session: CellSession, binding: CallbackBinding, attempt current: Attempt) async -> LoopbackResult {
        let expired = LoopbackResult(ok: false, title: "This sign-in already finished",
                                     message: "Check Silicon Mode. To sign in again, start from its menu bar.")
        if binding == .unbound, confirming {
            return LoopbackResult(ok: false, title: "Check Silicon Mode",
                                  message: "Silicon Mode is already asking you to confirm a sign-in.", pending: true)
        }
        guard !completing else {
            return LoopbackResult(ok: false, title: "Already finishing",
                                  message: "Silicon Mode is finishing this sign-in in another tab.")
        }
        // Whose tokens are these? Nothing is stored until we know (and, if unbound, the person agrees).
        let user: CellUser
        do {
            user = try await client.fetchUser(accessToken: session.accessToken)
        } catch {
            let msg = (error as? CellError).map {
                $0.isRetryable ? "Couldn't reach Silicon Accounts. Check your connection and try again."
                               : "Silicon Accounts didn't accept this sign-in. Try again."
            } ?? "Something went wrong. Try again."
            // A bad callback from elsewhere must not end the person's own sign-in.
            if binding == .bound, attempt?.id == current.id, state == .signingIn {
                closeAttempt()
                state = .error(msg)
            }
            return LoopbackResult(ok: false, title: "Sign-in didn't finish", message: msg)
        }
        guard attempt?.id == current.id, state == .signingIn else { return expired }
        let acc = Account(user)

        if binding == .unbound {
            guard !confirming else {
                return LoopbackResult(ok: false, title: "Check Silicon Mode",
                                      message: "Silicon Mode is already asking you to confirm a sign-in.", pending: true)
            }
            confirming = true
            Task {
                let yes = await confirmUnboundSignIn(acc)
                confirming = false
                guard yes else {
                    SyncLog.error("sign-in as \(acc.id) not confirmed (callback not tied to this Mac's sign-in tab)")
                    return
                }
                guard attempt?.id == current.id, state == .signingIn else { return }
                _ = await store(session, user: user, account: acc, attempt: current)
            }
            return LoopbackResult(ok: false, title: "Confirm in Silicon Mode",
                                  message: "Silicon Mode is asking whether to sign in as \(acc.displayName) (\(acc.id)). Switch to it to finish.",
                                  pending: true)
        }
        return await store(session, user: user, account: acc, attempt: current)
    }

    /// Persist the checked session and publish the account.
    private func store(_ session: CellSession, user: CellUser, account acc: Account, attempt current: Attempt) async -> LoopbackResult {
        let expired = LoopbackResult(ok: false, title: "This sign-in already finished",
                                     message: "Check Silicon Mode. To sign in again, start from its menu bar.")
        guard !completing else {
            return LoopbackResult(ok: false, title: "Already finishing",
                                  message: "Silicon Mode is finishing this sign-in in another tab.")
        }
        completing = true
        defer { completing = false }
        if let t = signOutTask { await t.value }   // never adopt underneath a pending sign-out's wipe
        guard attempt?.id == current.id, state == .signingIn else { return expired }
        do {
            let previous = account
            try await client.adopt(session, user: user)
            closeAttempt()
            account = acc
            state = .signedIn
            if previous?.uuid != acc.uuid { notify(true) }
            return LoopbackResult(ok: true, title: "You're signed in",
                                  message: "You can close this tab. Silicon Mode will keep your phone and the web up to date.",
                                  name: acc.displayName, handle: acc.id)
        } catch {
            // Keychain write failed: whatever was stored before is untouched.
            closeAttempt()
            let msg = "Couldn't save your session in the Keychain. Try again."
            state = account == nil ? .error(msg) : .signedIn
            return LoopbackResult(ok: false, title: "Sign-in didn't finish", message: msg)
        }
    }

    private func sessionEnded(_ reason: String) {
        guard account != nil || state == .signedIn else { return }
        account = nil
        state = .error("You were signed out. Sign in again to keep syncing.")
        notify(false)
    }

    /// End the current attempt: deadline, URL, pending confirmation, listener (kept a moment so the
    /// page's POST response flushes, but refusing new completions right away).
    private func closeAttempt() {
        signInDeadline?.cancel(); signInDeadline = nil
        signInURL = nil
        attempt = nil
        if confirming { SignInConfirmation.dismiss() }
        guard let s = server else { return }
        server = nil
        s.retire()
        retiringServer = s
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            s.stop()
            if self?.retiringServer === s { self?.retiringServer = nil }
        }
    }
}

/// "Sign in as …?" for a sign-in Silicon Mode can't tie to the browser tab it opened.
@MainActor
enum SignInConfirmation {
    private static var showing = false

    static func ask(_ a: AccountManager.Account) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sign in as \(a.displayName)?"
        alert.informativeText = "A sign-in for \(a.id) reached Silicon Mode from outside the browser tab it opened. "
            + "Continue only if this is your account and you just signed in: Silicon Mode will send your agents' "
            + "activity to this account and accept answers from it."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Sign In as \(a.displayName)")
        NSApp.activate()
        showing = true
        defer { showing = false }
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The attempt ended while asking (e.g. the bound callback finished it): take the question away.
    static func dismiss() {
        if showing { NSApp.abortModal() }
    }
}
