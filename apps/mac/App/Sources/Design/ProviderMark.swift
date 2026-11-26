import SwiftUI
import SiliconModeKit

/// A provider's mark (logo if bundled in Resources/Logos/<id>.png|pdf, else a monogram disc
/// in the provider's color). Used by faces, HUD and the menu bar.
struct ProviderMark: View {
    let provider: String
    var size: CGFloat = 24

    var body: some View {
        let info = ProviderCatalog.info(for: provider)
        Circle()
            .fill(info.color)
            .overlay(Text(info.monogram).font(Theme.allo(size * 0.42, .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}
