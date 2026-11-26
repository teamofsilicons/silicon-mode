import SwiftUI
import SiliconModeKit

struct SettingsPanicPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let s = model.settings
        let baseline = model.siliconModeAngle ?? 70
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsRow(icon: "light.beacon.max", title: "Panic mode",
                            detail: "If agents are running and someone closes your Mac after Silicon Mode started, it flashes and sounds an alarm. Only while closing, never when opening.") {
                    Toggle("Panic mode", isOn: $model.settings.panicEnabled).settingsSwitch()
                }
            }

            Group {
                SettingsSectionLabel(text: "Trigger")
                SettingsCard {
                    HStack(alignment: .center, spacing: 8) {
                        // The wedge is the Silicon Mode angle; the red ray is where panic fires.
                        SettingsLidGauge(angle: baseline * s.panicRatio - 8, threshold: baseline,
                                         panicAngle: baseline * s.panicRatio, showsReadout: false)
                            .frame(width: 230, height: 170)
                            .padding(.leading, 4)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Closes below").alloText(13, .medium).foregroundStyle(Theme.foreground)
                                Spacer()
                                SettingsValueChip(text: SettingsFormat.percent(s.panicRatio), tint: Theme.danger)
                            }
                            SettingsSlider(value: $model.settings.panicRatio, range: 0.5...0.98, step: 0.01, tint: Theme.danger)
                            Text("of the angle Silicon Mode started at. Started at \(SettingsFormat.degrees(baseline))? Panic below \(SettingsFormat.degrees(baseline * s.panicRatio)). Opening the lid further never moves this up. Started above \(SettingsFormat.degrees(s.thresholdAngle)), e.g. with ⌃⌥S? Panic waits until \(SettingsFormat.degrees(s.thresholdAngle * (1 - ModeEngine.panicHighDrop))).")
                                .alloText(12)
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.trailing, 16)
                    }
                    .padding(.vertical, 10)
                }

                SettingsSectionLabel(text: "Sound")
                SettingsCard {
                    SettingsRow(icon: "speaker.wave.3", title: "Play a sound", detail: "Loud enough to stop a closing lid.") {
                        Toggle("Play a sound", isOn: $model.settings.panicSoundEnabled).settingsSwitch()
                    }
                    if s.panicSoundEnabled {
                        SettingsDivider(inset: 54)
                        VStack(spacing: 2) {
                            ForEach(SoundPlayer.panicSounds) { snd in
                                soundRow(snd, selected: snd.id == s.panicSoundID)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .padding(.leading, 46)
                        SettingsDivider(inset: 54)
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                            SettingsSlider(value: $model.settings.panicVolume, range: 0...1, step: 0.05)
                            Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                            SettingsValueChip(text: SettingsFormat.percent(s.panicVolume))
                                .frame(width: 52)
                            Button {
                                model.sounds.preview(panicSoundID: s.panicSoundID, volume: s.panicVolume)
                            } label: { Label("Preview", systemImage: "play.fill") }
                                .settingsButton(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .padding(.leading, 40)
                    }
                }
                .animation(Theme.Motion.moderate, value: s.panicSoundEnabled)

                SettingsSectionLabel(text: "Look")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(PanicStyle.all) { style in
                        styleTile(style, selected: style.id == s.panicStyleID)
                    }
                }
            }
            .disabled(!s.panicEnabled)
            .opacity(s.panicEnabled ? 1 : 0.45)
            .animation(Theme.Motion.moderate, value: s.panicEnabled)
        }
    }

    private func soundRow(_ snd: SoundPlayer.PanicSound, selected: Bool) -> some View {
        Button {
            withAnimation(Theme.Motion.fast) { model.settings.panicSoundID = snd.id }
            model.sounds.preview(panicSoundID: snd.id, volume: model.settings.panicVolume)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(selected ? Theme.accent : SettingsTint.borderStrong, lineWidth: selected ? 5 : 1.5)
                }
                .frame(width: 16, height: 16)
                Text(snd.name).alloText(13, selected ? .semibold : .medium).foregroundStyle(Theme.foreground)
                Spacer()
                Image(systemName: "play.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(selected ? Theme.foreground.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func styleTile(_ style: PanicStyle, selected: Bool) -> some View {
        Button {
            withAnimation(Theme.Motion.moderate) { model.settings.panicStyleID = style.id }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                SettingsPanicStylePreview(styleID: style.id, animating: selected)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Theme.danger : Theme.border, lineWidth: selected ? 2 : 1))
                Text(style.name).alloText(12, selected ? .semibold : .medium)
                    .foregroundStyle(selected ? Theme.foreground : Theme.textSecondary)
                    .padding(.leading, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A tiny animated impression of a panic style (the real one is PanicView). Animates only while
/// selected or hovered, and calmly: it's a preview, not an alarm.
struct SettingsPanicStylePreview: View {
    let styleID: String
    var animating: Bool
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let live = (animating || hover) && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live || SettingsRender.isSnapshot)) { tl in
            let t = SnapshotHarness.time ?? (live ? tl.date.timeIntervalSinceReferenceDate : 0.35)
            Canvas { ctx, size in
                draw(ctx, size: size, t: t)
            }
        }
        .background(Theme.Night.background)
        .onHover { hover = $0 }
    }

    private var kind: String {
        let id = styleID.lowercased()
        for k in ["strobe", "siren", "glitch", "shake", "pulse", "alarm", "flash", "scream", "red"] where id.contains(k) { return k }
        return "pulse"
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let red = Color(hex: "F4968C")
        let deep = Color(hex: "B42318")
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        switch kind {
        case "strobe", "flash":
            let on = Int(t * 3) % 2 == 0
            ctx.fill(Path(rect), with: .color(on ? deep : Theme.Night.background))
            if on { ctx.fill(Path(rect.insetBy(dx: size.width * 0.12, dy: size.height * 0.18)), with: .color(Color.white.opacity(0.12))) }
        case "siren":
            let a = t * 2.4
            let ray = Path { p in
                p.move(to: c)
                p.addArc(center: c, radius: size.width, startAngle: .radians(a), endAngle: .radians(a + 0.9), clockwise: false)
            }
            ctx.fill(ray, with: .color(deep.opacity(0.85)))
            let ray2 = Path { p in
                p.move(to: c)
                p.addArc(center: c, radius: size.width, startAngle: .radians(a + .pi), endAngle: .radians(a + .pi + 0.9), clockwise: false)
            }
            ctx.fill(ray2, with: .color(Color(hex: "7D9BFF").opacity(0.7)))
        case "glitch":
            for i in 0..<7 {
                let y = (Double(i) / 7 + sin(t * 3 + Double(i)) * 0.03) * size.height
                let dx = sin(t * 9 + Double(i) * 1.7) * size.width * 0.06
                let r = CGRect(x: dx, y: y, width: size.width, height: size.height / 9)
                ctx.fill(Path(r), with: .color((i % 2 == 0 ? deep : red).opacity(0.55)))
            }
        default:
            let k = (sin(t * 4) + 1) / 2
            ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [deep.opacity(0.15 + 0.55 * k), Theme.Night.background]),
                                                     center: c, startRadius: 0, endRadius: size.width * (0.35 + 0.3 * k)))
        }
        // The little alarmed face on top.
        let shake = kind == "shake" ? sin(t * 40) * 3 : 0
        let eyeW = size.width * 0.075, eyeH = size.height * 0.22
        for dx in [-1.0, 1.0] {
            let r = CGRect(x: c.x + dx * size.width * 0.08 - eyeW / 2 + shake, y: c.y - eyeH / 2, width: eyeW, height: eyeH)
            ctx.fill(Path(roundedRect: r, cornerRadius: eyeW / 2), with: .color(.white))
        }
        let mouth = CGRect(x: c.x - size.width * 0.04 + shake, y: c.y + eyeH * 0.75, width: size.width * 0.08, height: size.width * 0.05)
        ctx.fill(Path(ellipseIn: mouth), with: .color(.white.opacity(0.9)))
    }
}
