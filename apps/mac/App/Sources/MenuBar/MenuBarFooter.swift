import SwiftUI
import AppKit
import SiliconModeKit

/// Pause menu · account · Settings · Quit.
struct MenuBarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuBarDemo) private var demo
    @Environment(\.openSettings) private var openSettings
    @State private var pauseFrame: CGRect = .zero
    @State private var accountFrame: CGRect = .zero

    var body: some View {
        let paused: Date? = demo != nil ? demo?.pausedUntil : model.autoPausedUntil
        let autoOn = demo?.autoEnter ?? model.settings.autoEnterEnabled
        let accountName: String? = demo != nil ? demo?.accountName : model.account.account?.displayName

        HStack(spacing: 2) {
            Button { showPauseMenu(paused: paused, autoOn: autoOn) } label: {
                HStack(spacing: 6) {
                    Image(systemName: !autoOn ? "pause.circle" : (paused != nil ? "pause.circle.fill" : "pause.circle"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(paused != nil || !autoOn ? Theme.warning : Theme.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(!autoOn ? "Auto-entry off" : (paused != nil ? "Paused" : "Pause"))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .buttonStyle(MBPillButtonStyle(kind: .quiet, height: 28, fontSize: 12.5))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pauseFrame = $0 }
            .help("Pause automatic entry")

            Spacer(minLength: 4)

            if let name = accountName {
                Button { showAccountMenu(name: name) } label: { Avatar(name: name) }
                    .buttonStyle(MBIconButtonStyle(size: 30))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { accountFrame = $0 }
                    .help("Signed in as \(name)")
            } else {
                Button { if demo == nil { model.account.signIn() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.circle").font(.system(size: 12.5, weight: .medium))
                        Text("Sign in")
                    }
                }
                .buttonStyle(MBPillButtonStyle(kind: .quiet, height: 28, fontSize: 12.5))
                .help("Sign in with your Silicon account for faces and the phone app")
            }

            Button { if demo == nil { MenuBarController.shared.openSettings() } } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(MBIconButtonStyle())
            .help("Settings… (⌘,)")
            .accessibilityLabel("Settings")

            Button { if demo == nil { NSApp.terminate(nil) } } label: {
                Image(systemName: "power")
            }
            .buttonStyle(MBIconButtonStyle())
            .help("Quit Silicon Mode (⌘Q)")
            .accessibilityLabel("Quit Silicon Mode")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(MB.hairline).frame(height: 0.5).padding(.horizontal, 16)
        }
        .animation(MB.Motion.chip, value: paused)
        .onAppear {
            if demo == nil { MenuBarController.shared.openSettingsAction = openSettings }
        }
    }

    private func showPauseMenu(paused: Date?, autoOn: Bool) {
        guard demo == nil else { return }
        let c = MenuBarController.shared
        let model = self.model
        let menu = NSMenu()
        if !autoOn {
            menu.addItem(c.menuItem("Turn On Auto-Entry", symbol: "play.circle") { model.settings.autoEnterEnabled = true })
        } else {
            if let paused {
                menu.addItem(c.menuItem("Paused until \(MBFormat.until(paused))", enabled: false) {})
                menu.addItem(c.menuItem("Resume Auto-Entry", symbol: "play.fill") { model.pauseAutoEntry(for: nil) })
                menu.addItem(.separator())
            }
            menu.addItem(NSMenuItem.sectionHeader(title: paused == nil ? "Pause auto-entry" : "Pause instead"))
            menu.addItem(c.menuItem("For 30 Minutes", symbol: "clock") { model.pauseAutoEntry(for: 30 * 60) })
            menu.addItem(c.menuItem("For 1 Hour", symbol: "clock") { model.pauseAutoEntry(for: 60 * 60) })
            menu.addItem(c.menuItem("Until Tomorrow", symbol: "moon") { model.pauseAutoEntry(for: MBFormat.untilTomorrowMorning()) })
        }
        c.popUp(menu, below: pauseFrame)
    }

    private func showAccountMenu(name: String) {
        guard demo == nil else { return }
        let c = MenuBarController.shared
        let account = model.account
        let menu = NSMenu()
        menu.addItem(c.menuItem("Signed in as \(name)", enabled: false) {})
        menu.addItem(.separator())
        menu.addItem(c.menuItem("Sign Out", symbol: "rectangle.portrait.and.arrow.right") { account.signOut() })
        c.popUp(menu, below: accountFrame)
    }
}

/// Initials on the silicon gradient.
private struct Avatar: View {
    let name: String
    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(initials.isEmpty ? "?" : initials)
            .font(Theme.allo(10, .bold))
            .foregroundStyle(Theme.siliconInkFrom)
            .frame(width: 22, height: 22)
            .background(Circle().fill(LinearGradient(colors: [Theme.siliconFrom, Theme.siliconTo],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
