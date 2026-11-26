import SwiftUI
import SiliconModeKit

/// Snapshot-harness entries for this module (see App/SnapshotHarness.swift).
///
///   overlay.countdown         countdown strip at ~3 s left over a stand-in desktop
///   overlay.enter             enter shockwave mid-frame (--time = seconds into the animation)
///   overlay.enter.bang        the flash at impact
///   overlay.root              Silicon Mode, "bounce" face, grace period
///   overlay.root.locked       after the grace period
///   overlay.root.unlock       unlock sheet presented
///   overlay.exit              implode mid-frame
///   overlay.panic.<style>     each panic style (--time picks the moment)
@MainActor
enum OverlaySnapshots {
    static var items: [SnapshotItem] {
        var items: [SnapshotItem] = [
            SnapshotItem(id: "overlay.countdown") { AnyView(countdown(elapsed: SnapshotHarness.time ?? 2.35)) },
            SnapshotItem(id: "overlay.countdown.strip", size: CGSize(width: 1512, height: 442)) {
                AnyView(countdownStrip(elapsed: SnapshotHarness.time ?? 2.35))
            },
            SnapshotItem(id: "overlay.enter") { AnyView(enter(at: pin(0.55))) },
            SnapshotItem(id: "overlay.enter.gather") { AnyView(enter(at: pin(0.2))) },
            SnapshotItem(id: "overlay.enter.bang") { AnyView(enter(at: pin(0.34))) },
            SnapshotItem(id: "overlay.enter.late") { AnyView(enter(at: pin(0.85))) },
            SnapshotItem(id: "overlay.root") { AnyView(root(SiliconModePreview(faceID: "bounce"))) },
            SnapshotItem(id: "overlay.root.locked") {
                AnyView(root(SiliconModePreview(graceRemaining: nil, locked: true, faceID: "bounce")))
            },
            SnapshotItem(id: "overlay.root.unlock") {
                AppModel.shared.unlockPresented = true
                return AnyView(root(SiliconModePreview(graceRemaining: nil, locked: true, unlockPresented: true, faceID: "bounce")))
            },
            SnapshotItem(id: "overlay.exit") { AnyView(exit(at: pin(0.4))) },
        ]
        for style in PanicStyle.all {
            items.append(SnapshotItem(id: "overlay.panic.\(style.id)") {
                AnyView(root(SiliconModePreview(graceRemaining: nil, locked: true, panicking: true,
                                                panicStyleID: style.id, faceID: "bounce")))
            })
        }
        return items
    }

    // MARK: Builders

    private static let screen = CGSize(width: 1512, height: 982)

    /// Fix the animation clock (rendering happens a beat after the view is built, so wall-clock
    /// offsets drift). `--time` still wins.
    private static func pin(_ t: Double) -> Double {
        if SnapshotHarness.time == nil { SnapshotHarness.time = t }
        return SnapshotHarness.time ?? t
    }

    private static func countdownStrip(elapsed: Double, visible: Bool = true,
                                       exit: OverlayStage.CountdownExit = .retract) -> some View {
        let stripH = (screen.height * 0.45).rounded()
        let backdrop = FakeDesktop()
            .frame(width: screen.width, height: screen.height)
        return CountdownView(stage: OverlayStage(), preview: CountdownPreview(
            remaining: max(0, 5 - elapsed), duration: 5,
            counts: AgentCounts(SampleAgents.sessions),
            backdrop: AnyView(backdrop), showsButton: true, visible: visible, exit: exit))
        .frame(width: screen.width, height: stripH)
    }

    private static func countdown(elapsed: Double) -> some View {
        ZStack(alignment: .top) {
            FakeDesktop()
            countdownStrip(elapsed: elapsed)
        }
        .frame(width: screen.width, height: screen.height)
    }

    private static func enter(at t: Double) -> some View {
        let stage = OverlayStage()
        stage.enterStartedAt = Date().addingTimeInterval(-t)
        return ZStack(alignment: .top) {
            FakeDesktop()
            countdownStrip(elapsed: 5, visible: t < 0.3, exit: .handoff)
                .opacity(t < 0.5 ? 1 : max(0, 1 - (t - 0.5) / 0.4))
            SiliconModeRootView(stage: stage, displayID: 1, preview: SiliconModePreview(faceID: "bounce"))
        }
        .frame(width: screen.width, height: screen.height)
    }

    private static func exit(at t: Double) -> some View {
        let stage = OverlayStage()
        stage.exitStartedAt = Date().addingTimeInterval(-t)
        return ZStack {
            FakeDesktop()
            SiliconModeRootView(stage: stage, displayID: 1, preview: SiliconModePreview(faceID: "bounce"))
        }
        .frame(width: screen.width, height: screen.height)
    }

    private static func root(_ p: SiliconModePreview) -> some View {
        SiliconModeRootView(stage: OverlayStage(), displayID: 1, preview: p)
            .frame(width: screen.width, height: screen.height)
    }
}

/// A stand-in macOS desktop (wallpaper, menu bar, a couple of windows) so the progressive blur
/// and the shockwave read the way they will over a real desktop.
struct FakeDesktop: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                // Wallpaper
                LinearGradient(colors: [Color(hex: "1B2A6B"), Color(hex: "5B3C8F"), Color(hex: "E07A4F")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hex: "F7C873").opacity(0.75), .clear], center: UnitPoint(x: 0.78, y: 0.18),
                               startRadius: 0, endRadius: w * 0.4)
                RadialGradient(colors: [Color(hex: "3FA7D6").opacity(0.6), .clear], center: UnitPoint(x: 0.1, y: 0.85),
                               startRadius: 0, endRadius: w * 0.45)

                // Editor window
                fakeWindow(dark: true, title: "auth/middleware.ts — api")
                    .frame(width: w * 0.5, height: h * 0.62)
                    .offset(x: w * 0.06, y: h * 0.1)
                // Browser window
                fakeWindow(dark: false, title: "Pull request #482 · fix flaky checkout test")
                    .frame(width: w * 0.42, height: h * 0.5)
                    .offset(x: w * 0.5, y: h * 0.2)

                // Menu bar
                HStack(spacing: 18) {
                    Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                    Text("Code").fontWeight(.bold)
                    Text("File"); Text("Edit"); Text("Selection"); Text("View"); Text("Go")
                    Spacer()
                    Image(systemName: "wifi"); Image(systemName: "battery.75percent")
                    Text("Thu 26 Nov  1:24 AM")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(width: w, height: 34)
                .background(.black.opacity(0.18))

                // Dock
                HStack(spacing: 10) {
                    ForEach(0..<9, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hue: Double(i) / 9, saturation: 0.55, brightness: 0.95),
                                                          Color(hue: Double(i) / 9 + 0.05, saturation: 0.7, brightness: 0.7)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 52, height: 52)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.22)))
                .frame(width: w, height: h - 10, alignment: .bottom)
            }
        }
    }

    private func fakeWindow(dark: Bool, title: String) -> some View {
        let fg: Color = dark ? .white : .black
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: "FF5F57")).frame(width: 12, height: 12)
                Circle().fill(Color(hex: "FEBC2E")).frame(width: 12, height: 12)
                Circle().fill(Color(hex: "28C840")).frame(width: 12, height: 12)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(fg.opacity(0.7))
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<16, id: \.self) { i in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill((dark ? Color(hex: "C792EA") : Color(hex: "3460F0")).opacity(0.8))
                            .frame(width: CGFloat(30 + (i * 37) % 60), height: 9)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(fg.opacity(0.35))
                            .frame(width: CGFloat(80 + (i * 53) % 220), height: 9)
                        RoundedRectangle(cornerRadius: 3)
                            .fill((dark ? Color(hex: "89DDFF") : Color(hex: "B42318")).opacity(0.7))
                            .frame(width: CGFloat(20 + (i * 29) % 90), height: 9)
                    }
                    .padding(.leading, CGFloat((i % 4) * 18))
                }
            }
            .padding(18)
            Spacer(minLength: 0)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(dark ? Color(hex: "1E1E24") : Color(hex: "F6F6F7")))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(dark ? 0.12 : 0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
    }
}
