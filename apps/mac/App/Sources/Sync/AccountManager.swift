import Foundation
import SiliconModeKit

/// Silicon Accounts sign-in (optional; needed for marketplace faces and the phone/web apps).
@MainActor @Observable
final class AccountManager {
    struct Account: Codable, Equatable { var uuid: String; var id: String; var displayName: String; var pfpURL: String? }
    private(set) var account: Account?
    var isSignedIn: Bool { account != nil }

    func restore() {}
    func signIn() {}
    func signOut() {}
    func handleCallback(_ url: URL) {}
}
