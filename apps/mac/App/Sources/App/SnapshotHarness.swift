import SwiftUI
import AppKit
import SiliconModeKit

/// Headless rendering of registered views to PNG, for design checks without touching the screen:
///
///     "Silicon Mode.app/Contents/MacOS/Silicon Mode" --snapshot <id> <out.png> [width height] [--time <seconds>]
///     "Silicon Mode.app/Contents/MacOS/Silicon Mode" --snapshot list
///
/// Each module contributes its own items (`<Module>Snapshots.items`). Liquid Glass can't sample a
/// backdrop offscreen, so glass renders flat here; check real glass in the running app.
struct SnapshotItem {
    let id: String
    var size: CGSize = CGSize(width: 1512, height: 982)   // 16" MBP default-scaled screen
    var dark = true
    let view: @MainActor () -> AnyView
}

@MainActor
enum SnapshotHarness {
    static var all: [SnapshotItem] {
        OverlaySnapshots.items + HUDSnapshots.items + FaceSnapshots.items + FaceSnapshotsB.items
            + MenuBarSnapshots.items + SettingsSnapshots.items
    }

    /// Seconds offset for time-based animations (faces read `SnapshotHarness.time` if set).
    static var time: Double?

    /// Returns true if a snapshot was requested (the app should exit afterwards).
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot") else { return false }
        FontRegistry.registerBundledFonts()
        if let t = args.firstIndex(of: "--time"), t + 1 < args.count { time = Double(args[t + 1]) }
        let id = i + 1 < args.count ? args[i + 1] : "list"
        if id == "list" {
            print(all.map(\.id).joined(separator: "\n"))
            return true
        }
        guard let item = all.first(where: { $0.id == id }) else {
            FileHandle.standardError.write(Data("unknown snapshot \(id)\n".utf8))
            return true
        }
        let out = i + 2 < args.count ? args[i + 2] : "/tmp/\(id).png"
        var size = item.size
        if i + 4 < args.count, let w = Double(args[i + 3]), let h = Double(args[i + 4]) { size = CGSize(width: w, height: h) }
        let content = item.view()
            .environment(AppModel.shared)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, item.dark ? .dark : .light)
            .background(item.dark ? Color.black : Color.white)
        let r = ImageRenderer(content: content)
        r.scale = 2
        guard let cg = r.cgImage else { FileHandle.standardError.write(Data("render failed\n".utf8)); return true }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        print(out)
        return true
    }
}
