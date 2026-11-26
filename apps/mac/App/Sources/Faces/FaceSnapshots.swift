import SwiftUI
import SiliconModeKit

/// Snapshot-harness entries for the Bounce, Orbit and Clock faces and provider marks
/// (see App/SnapshotHarness.swift). Each face renders at a few fixed moments so the
/// output is deterministic; `--time` overrides the fixed moment.
@MainActor
enum FaceSnapshots {
    static var items: [SnapshotItem] {
        bounce + orbit + clock + marks + silicon
    }

    /// Silicon avatars (monogram + TOS badge in snapshots) on every face.
    private static var silicon: [SnapshotItem] {
        let s = FaceASamples.silicons
        return [
            SnapshotItem(id: "face-bounce-silicon", view: { AnyView(BounceFaceView(ctx: ctx(s), fixedTime: 4)) }),
            SnapshotItem(id: "face-orbit-silicon", view: { AnyView(OrbitFaceView(ctx: ctx(s), fixedTime: 6)) }),
            SnapshotItem(id: "face-clock-silicon", view: { AnyView(ClockFaceView(ctx: ctx(s), fixedTime: 2)) }),
            // The live path: far planets drawn from pre-blurred images instead of a per-frame blur.
            SnapshotItem(id: "face-orbit-blurcache", view: {
                let sessions = FaceASamples.sessions
                let u = FaceA.unit(for: CGSize(width: 1512, height: 982))
                let r = 19 * u
                OrbitBlurCache.shared.prepare(.init(planets: OrbitPlanet.make(sessions, preview: false),
                                                    spec: .init(size: r * 2 * 1.4, pad: r * 0.6, radius: r * 0.22, scale: 2)))
                return AnyView(OrbitFaceView(ctx: ctx(sessions), fixedTime: 37, blurCache: true))
            }),
        ]
    }

    private static let preview = CGSize(width: 320, height: 200)

    private static func ctx(_ sessions: [AgentSession], preview: Bool = false, showClock: Bool = true,
                            options: [String: FaceOptionValue] = [:], panic: Bool = false) -> FaceContext {
        FaceContext(sessions: sessions, counts: AgentCounts(sessions), options: options, showClock: showClock,
                    isPreview: preview, isPanicking: panic)
    }

    private static var bounce: [SnapshotItem] {
        [
            SnapshotItem(id: "face-bounce", view: { AnyView(BounceFaceView(ctx: ctx(SampleAgents.sessions), fixedTime: 3.2)) }),
            SnapshotItem(id: "face-bounce-corner", view: {
                AnyView(BounceFaceView(ctx: ctx(SampleAgents.sessions), fixedTime: 5.9))
            }),
            SnapshotItem(id: "face-bounce-many", view: {
                AnyView(BounceFaceView(ctx: ctx(FaceASamples.sessions, options: ["size": .string("small")]), fixedTime: 21))
            }),
            SnapshotItem(id: "face-bounce-large-notrails", view: {
                AnyView(BounceFaceView(ctx: ctx(SampleAgents.sessions, options: ["size": .string("large"), "trails": .bool(false)]),
                                       fixedTime: 12))
            }),
            SnapshotItem(id: "face-bounce-empty", view: { AnyView(BounceFaceView(ctx: ctx([]), fixedTime: 2.5)) }),
            SnapshotItem(id: "face-bounce-empty-corner", view: { AnyView(BounceFaceView(ctx: ctx([]), fixedTime: 6.3)) }),
            SnapshotItem(id: "face-bounce-panic", view: {
                AnyView(BounceFaceView(ctx: ctx(SampleAgents.sessions, panic: true), fixedTime: 9))
            }),
            SnapshotItem(id: "face-bounce-preview", size: preview, view: {
                AnyView(BounceFaceView(ctx: ctx(SampleAgents.sessions, preview: true), fixedTime: 4))
            }),
        ]
    }

    private static var orbit: [SnapshotItem] {
        [
            SnapshotItem(id: "face-orbit", view: { AnyView(OrbitFaceView(ctx: ctx(SampleAgents.sessions), fixedTime: 4)) }),
            SnapshotItem(id: "face-orbit-many", view: { AnyView(OrbitFaceView(ctx: ctx(FaceASamples.sessions), fixedTime: 37)) }),
            SnapshotItem(id: "face-orbit-flat", view: {
                AnyView(OrbitFaceView(ctx: ctx(FaceASamples.sessions, showClock: false, options: ["tilt": .number(30)]), fixedTime: 12))
            }),
            SnapshotItem(id: "face-orbit-empty", view: { AnyView(OrbitFaceView(ctx: ctx([]), fixedTime: 9)) }),
            SnapshotItem(id: "face-orbit-panic", view: {
                AnyView(OrbitFaceView(ctx: ctx(SampleAgents.sessions, panic: true), fixedTime: 7))
            }),
            SnapshotItem(id: "face-orbit-preview", size: preview, view: {
                AnyView(OrbitFaceView(ctx: ctx(SampleAgents.sessions, preview: true), fixedTime: 6))
            }),
        ]
    }

    private static var clock: [SnapshotItem] {
        [
            SnapshotItem(id: "face-clock", view: { AnyView(ClockFaceView(ctx: ctx(SampleAgents.sessions), fixedTime: 0.5)) }),
            SnapshotItem(id: "face-clock-roll", view: {
                AnyView(ClockFaceView(ctx: ctx(FaceASamples.sessions, options: ["use24h": .bool(false)]), fixedTime: 8.12))
            }),
            SnapshotItem(id: "face-clock-minimal", view: {
                AnyView(ClockFaceView(ctx: ctx(SampleAgents.sessions, options: ["style": .string("minimal"), "use24h": .bool(true)]), fixedTime: 30))
            }),
            SnapshotItem(id: "face-clock-flap", view: {
                AnyView(ClockFaceView(ctx: ctx(SampleAgents.sessions, options: ["style": .string("flap"), "use24h": .bool(true)]), fixedTime: 5))
            }),
            SnapshotItem(id: "face-clock-flap-flip", view: {
                AnyView(ClockFaceView(ctx: ctx(FaceASamples.sessions, options: ["style": .string("flap"), "use24h": .bool(true)]), fixedTime: 8.18))
            }),
            SnapshotItem(id: "face-clock-flap-flip2", view: {
                AnyView(ClockFaceView(ctx: ctx(FaceASamples.sessions, options: ["style": .string("flap"), "use24h": .bool(true)]), fixedTime: 8.42))
            }),
            SnapshotItem(id: "face-clock-empty", view: { AnyView(ClockFaceView(ctx: ctx([]), fixedTime: 3.3)) }),
            SnapshotItem(id: "face-clock-preview", size: preview, view: {
                AnyView(ClockFaceView(ctx: ctx(SampleAgents.sessions, preview: true), fixedTime: 2))
            }),
        ]
    }

    private static var marks: [SnapshotItem] {
        [
            SnapshotItem(id: "provider-marks", size: CGSize(width: 1240, height: 220), view: { AnyView(ProviderMarkSheet()) }),
        ]
    }
}

/// Every provider mark at a few sizes, for checking logos and fallbacks.
struct ProviderMarkSheet: View {
    static let providers = ["claude-code", "codex", "gemini-cli", "antigravity", "opencode", "cursor-cli", "copilot-cli",
                            "grok", "qwen-code", "pi", "hermes", "openclaw", "silicon", "omni", "amp", "mystery"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach([56.0, 28.0, 16.0], id: \.self) { size in
                HStack(spacing: size * 0.3) {
                    ForEach(Self.providers, id: \.self) { p in
                        ProviderMark(provider: p, size: size)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Night.background)
    }
}
