import AppKit
import SwiftUI
import SiliconModeKit

/// Owns the NSStatusItem (icon = MenuBarIcon) and the borderless glass NSPanel that shows
/// MenuBarContent below it. Opened by clicking the icon or programmatically (`toggle()`, `show()`).
@MainActor
final class MenuBarController {
    static let shared = MenuBarController()
    private var item: NSStatusItem?

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Silicon Mode")
        self.item = item
    }

    func show() {}
    func hide() {}
    func toggle() {}
}
