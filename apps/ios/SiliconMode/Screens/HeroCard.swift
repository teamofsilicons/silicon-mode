import SwiftUI

/// A little window onto the Mac's screen: Silicon Mode state, since when, the live lid angle drawn
/// as a hinge, online/awake/face/locked chips, and one orbiting light per running agent.
struct HeroCard: View {
    let mac: Device
    let sessions: [AgentSessionRow]

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var status: DeviceStatus? { mac.status }
    private var state: SiliconModeState { status?.state ?? .off }
    private var online: Bool { status?.isOnline() ?? false }
    /// The card goes "night" (always dark) while Silicon Mode is on, like the Mac's screen.
    private var night: Bool { state.isOn || scheme == .dark }

    private var agentDots: [HingeGlyph.AgentDot] {
        let live = sessions.filter { $0.phase == .working || $0.phase == .needsYou }
        if live.isEmpty, let st = status {
            let n = (st.agentsWorking ?? 0) + (st.agentsWaiting ?? 0)
            return (0..<min(n, 10)).map { i in
                HingeGlyph.AgentDot(color: i < (st.agentsWaiting ?? 0) ? Theme.Night.warning : Theme.Night.accent,
                                    needsYou: i < (st.agentsWaiting ?? 0))
            }
        }
        return live.map { s in
            HingeGlyph.AgentDot(color: s.phase == .needsYou ? Theme.Night.warning : Providers.info(s.provider).color.mix(with: .white, by: 0.25),
                                needsYou: s.phase == .needsYou)
        }
    }

    private var palette: [Color] {
        switch state {
        case .panic: Aurora.panic
        case .arming: Aurora.arming
        case .active, .locked: Aurora.night
        case .off: scheme == .dark ? Aurora.paperDark : Aurora.paperLight
        }
    }

    var body: some View {
        let animate = !reduceMotion && scenePhase == .active && SnapshotClock.fixed == nil
        // Only the drawings ride the clock; the text and chips above them don't re-render per frame.
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate)) { tl in
                let t = SnapshotClock.time(tl.date)
                ZStack {
                Aurora(palette: palette, t: t * (state == .panic ? 2.4 : 1), amplitude: state.isOn ? 1 : 0.6)
                    .overlay {
                        if state == .panic && !reduceMotion {
                            Theme.Night.panic.opacity(0.22 * (0.5 + 0.5 * sin(t * .pi * 2 * 2.2)))
                                .blendMode(.plusLighter)
                        }
                    }
                HingeGlyph(angle: status?.lidAngle ?? (state.isOn ? 62 : 110),
                           siliconAngle: status?.siliconAngle,
                           state: state, agents: agentDots, t: t, night: night, online: online)
                    .frame(width: 210, height: 170)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 4)
                    .padding(.bottom, 44)
                    .saturation(online ? 1 : 0.2)
                    .opacity(online ? 1 : 0.7)
                }
            }
            content
        }
        .frame(height: 292)
        .clipShape(.rect(cornerRadius: Theme.Radius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .strokeBorder(night ? Color.white.opacity(0.08) : Theme.border, lineWidth: 0.75)
        )
        .shadow(color: state.isOn ? Theme.siliconInkFrom.opacity(scheme == .dark ? 0.0 : 0.25) : Theme.shadow,
                radius: state.isOn ? 26 : 14, x: 0, y: state.isOn ? 14 : 6)
        .animation(Theme.Motion.slow, value: state)
        .animation(.spring(duration: 0.9, bounce: 0.18), value: status?.lidAngle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var fg: Color { night ? Theme.Night.foreground : Theme.foreground }
    private var fg2: Color { night ? Theme.Night.secondary : Theme.textSecondary }
    private var fg3: Color { night ? Theme.Night.muted : Theme.textMuted }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: mac.symbol).font(.system(size: 12, weight: .semibold))
                    Text("SILICON MODE")
                        .allo(11, .semibold, fixed: true)
                        .tracking(1.4)
                }
                .foregroundStyle(fg3)
                Spacer()
                onlineBadge
            }
            Text(state.title)
                .allo(46, .semibold, display: true, fixed: true)
                .foregroundStyle(titleStyle)
                .contentTransition(.interpolate)
                .padding(.top, 10)
                .shadow(color: state == .panic ? Theme.Night.panic.opacity(0.6) : .clear, radius: 12)
            sinceLine
                .padding(.top, 2)
            Spacer(minLength: 0)
            angleReadout
            Spacer(minLength: 0)
            chips
        }
        .padding(20)
    }

    private var titleStyle: AnyShapeStyle {
        switch state {
        case .active, .locked:
            AnyShapeStyle(LinearGradient(colors: [Theme.Night.lavender, Theme.Night.peach], startPoint: .leading, endPoint: .trailing))
        case .panic: AnyShapeStyle(Color(hex: "FFB4AA"))
        case .arming: AnyShapeStyle(Theme.Night.accent)
        case .off: AnyShapeStyle(fg)
        }
    }

    @ViewBuilder private var sinceLine: some View {
        if let since = status?.modeSince {
            HStack(spacing: 6) {
                Text(state.isOn ? "since \(Fmt.clock(since))" : "off since \(Fmt.clock(since))")
                if state.isOn {
                    Text("·")
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
            }
            .allo(15, .medium, fixed: true)
            .foregroundStyle(fg2)
        } else {
            Text(online ? "Waiting for the first report" : "Not reporting yet")
                .allo(15, .medium, fixed: true)
                .foregroundStyle(fg2)
        }
    }

    private var angleReadout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(status?.lidAngle.map { "\(Int($0.rounded()))" } ?? "–")
                    .allo(30, .semibold, display: true, fixed: true)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: status?.lidAngle ?? 0))
                Text("°").allo(22, .medium, fixed: true)
            }
            .foregroundStyle(fg)
            Text(status?.siliconAngle.map { "Lid · entered at \(Int($0.rounded()))°" } ?? "Lid angle")
                .allo(12, .semibold, fixed: true)
                .foregroundStyle(fg2)
        }
    }

    private var onlineBadge: some View {
        HStack(spacing: 4) {
            if online {
                LiveDot(color: night ? Theme.Night.success : Theme.success, size: 6)
                    .frame(width: 12, height: 12)
                Text("Online")
            } else {
                Circle().fill(fg3).frame(width: 6, height: 6).padding(3)
                Text(mac.lastSeenAt.map { "Seen \(Fmt.agoPhrase($0))" } ?? "Offline")
            }
        }
        .allo(12, .semibold, fixed: true)
        .foregroundStyle(online ? (night ? Theme.Night.success : Theme.success) : fg3)
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .glassEffect(night ? .clear : .regular, in: .capsule)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if state == .panic {
                NightChip(symbol: "exclamationmark.triangle.fill", text: "Lid closing", tint: Color(hex: "FFB4AA"))
            }
            if state == .locked {
                NightChip(symbol: "lock.fill", text: "Locked", tint: Theme.Night.lavender)
            }
            if status?.caffeinated == true {
                NightChip(symbol: "cup.and.heat.waves.fill", text: "Awake", tint: night ? Theme.Night.peach : Theme.siliconInkTo)
            }
            if state.isOn, let face = Fmt.faceName(status?.face) {
                NightChip(symbol: "face.smiling", text: face, tint: night ? Theme.Night.lavender : Theme.textSecondary)
            }
            if !state.isOn && online {
                Text("Tilt the lid down to start Silicon Mode")
                    .allo(13, .medium, fixed: true)
                    .foregroundStyle(fg3)
                    .lineLimit(1)
            }
        }
        .environment(\.colorScheme, night ? .dark : scheme)
    }

    private var accessibilityText: String {
        var s = "Silicon Mode \(state.title) on \(mac.name)"
        if let a = status?.lidAngle { s += ", lid at \(Int(a)) degrees" }
        s += online ? ", online" : ", offline"
        return s
    }
}
