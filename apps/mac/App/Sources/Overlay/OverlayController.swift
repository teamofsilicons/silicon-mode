import AppKit
import SwiftUI
import SiliconModeKit

/// Owns the overlay windows: the countdown strip (top of the main screen) and the full-screen
/// Silicon Mode windows (one per display, above everything).
@MainActor
final class OverlayController {
    func showCountdown() {}
    func hideCountdown() {}
    func enter() {}
    func exit() {}
}
