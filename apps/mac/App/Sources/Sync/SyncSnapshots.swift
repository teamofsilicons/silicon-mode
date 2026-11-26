#if !SYNC_HARNESS || SYNC_HARNESS_UI
import SwiftUI

/// Sample states of the account card (snapshot checks; also handy for previews).
@MainActor
enum SyncPreviews {
    static let tos = AccountManager.Account(uuid: "0080c488-a9e9-4c22-aa91-1c7a639f1d7b", id: "si:tos",
                                            displayName: "TOS", pfpURL: nil, kind: "silicon")
    static let ada = AccountManager.Account(uuid: "7e3bd279-da39-417f-b6dc-8ad0924990e4", id: "c:ada",
                                            displayName: "Ada Lovelace", pfpURL: nil, kind: "carbon")

    /// (id, view) pairs; ids are prefixed "account-".
    static var variants: [(String, AnyView)] {
        [
            ("account-signed-out", card(nil, .signedOut, .off)),
            ("account-signing-in", card(nil, .signingIn, .off)),
            ("account-live", card(ada, .signedIn, .synced, live: true)),
            ("account-synced", card(tos, .signedIn, .synced, last: Date().addingTimeInterval(-42))),
            ("account-offline", card(ada, .signedIn, .offline("Waiting for the network"))),
            ("account-paused", card(ada, .signedIn, .paused("This Mac was removed from your account."))),
            ("account-sync-off", card(ada, .signedIn, .off, enabled: false)),
            ("account-error", card(nil, .error("Couldn't reach Silicon Accounts. Check your connection and try again."), .off)),
        ]
    }

    static func card(_ a: AccountManager.Account?, _ s: AccountManager.State, _ sync: CloudSync.Status,
                     live: Bool = false, last: Date? = nil, enabled: Bool = true) -> AnyView {
        AnyView(
            SiliconAccountCard(account: a, state: s, sync: sync, lastSynced: last, live: live,
                               syncEnabled: .constant(enabled))
                .frame(width: 520)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        )
    }
}

#if !SYNC_HARNESS
/// Register with `SnapshotHarness.all` (`+ SyncSnapshots.items`).
@MainActor
enum SyncSnapshots {
    static var items: [SnapshotItem] {
        SyncPreviews.variants.flatMap { id, view in
            [SnapshotItem(id: "\(id)-light", size: CGSize(width: 568, height: 200), dark: false) { view },
             SnapshotItem(id: "\(id)-dark", size: CGSize(width: 568, height: 200), dark: true) { view }]
        }
    }
}
#endif
#endif
