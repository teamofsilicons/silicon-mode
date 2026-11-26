import SwiftUI
import SiliconModeKit

/// System activity: CPU with a one-minute sparkline, memory with its pressure colour, battery (on
/// Macs that have one) and network rates; thermal state only when it isn't nominal.
///
/// AppModel samples every 2 s off the main thread while the overlay is up and a system piece is
/// placed; only this view observes the readings. Snapshots show `SystemActivity.preview`.
struct SystemPiece: View {
    @Environment(AppModel.self) private var model
    let options: [String: FaceOptionValue]
    let width: CGFloat
    var preview: FurnitureSource?

    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12
    static let headerHeight: CGFloat = 18
    static let cpuHeight: CGFloat = 56
    static let memoryHeight: CGFloat = 38
    static let lineHeight: CGFloat = 18

    private struct Rows {
        var cpu, memory, battery, network: Bool
        init(_ o: [String: FaceOptionValue]) {
            typealias K = FurnitureOptions.System
            cpu = FurnitureOptions.bool(o, K.cpu, true)
            memory = FurnitureOptions.bool(o, K.memory, true)
            battery = FurnitureOptions.bool(o, K.battery, true)
            network = FurnitureOptions.bool(o, K.network, true)
        }
    }

    /// Fixed by the rows shown (the battery row counts even on Macs without one: a little slack).
    static func height(options: [String: FaceOptionValue]) -> CGFloat {
        let r = Rows(options)
        let rows: [CGFloat] = [headerHeight] + (r.cpu ? [cpuHeight] : []) + (r.memory ? [memoryHeight] : [])
            + (r.battery ? [lineHeight] : []) + (r.network ? [lineHeight] : [])
        return padding * 2 + rows.reduce(0, +) + spacing * CGFloat(rows.count - 1)
    }

    var body: some View {
        let rows = Rows(options)
        let a: SystemActivity? = preview.map { $0.system } ?? (HUDRender.isSnapshot ? .preview : model.systemActivity)
        VStack(alignment: .leading, spacing: Self.spacing) {
            header(a)
            if rows.cpu { cpu(a) }
            if rows.memory { memory(a) }
            if rows.battery, let b = a?.battery { battery(b) }
            if rows.network { network(a) }
        }
        .padding(Self.padding)
        .frame(width: width, alignment: .leading)
        .hudPanel(radius: 22)
        .accessibilityElement(children: .combine)
    }

    // MARK: Rows

    private func header(_ a: SystemActivity?) -> some View {
        HStack(spacing: 8) {
            HUDSectionLabel(title: "System")
            Spacer(minLength: 0)
            if let a, let t = Self.thermal(a.thermal) {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.medium").font(.system(size: 9, weight: .bold))
                    Text(t.label).font(Theme.allo(10.5, .semibold))
                }
                .foregroundStyle(t.color)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(t.color.opacity(0.14)))
            }
        }
        .frame(height: Self.headerHeight)
    }

    private func cpu(_ a: SystemActivity?) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CPU")
                    .font(Theme.allo(11.5, .medium))
                    .foregroundStyle(Theme.Night.muted)
                Text(a.map { Self.percent($0.cpu) } ?? "—")
                    .font(Theme.allo(26, .light))
                    .tracking(Theme.tracking(26, display: true))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Night.foreground)
            }
            .frame(width: 78, alignment: .leading)
            SystemSparkline(values: a?.cpuHistory ?? [])
                .frame(height: 36)
        }
        .frame(height: Self.cpuHeight)
    }

    private func memory(_ a: SystemActivity?) -> some View {
        let tint: Color = switch a?.pressure ?? .normal {
        case .normal: Theme.Night.accent
        case .warning: Theme.Night.warning
        case .critical: Theme.Night.danger
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory")
                    .font(Theme.allo(11.5, .medium))
                    .foregroundStyle(Theme.Night.muted)
                Spacer(minLength: 6)
                Text(a.map { "\(Self.gigabytes($0.memUsed)) of \(Self.gigabytes($0.memTotal))" } ?? "—")
                    .font(Theme.allo(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Night.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(tint)
                        .frame(width: max(6, geo.size.width * CGFloat(a?.memFraction ?? 0)))
                }
            }
            .frame(height: 6)
        }
        .frame(height: Self.memoryHeight)
        .accessibilityLabel(a.map { "Memory \(Self.gigabytes($0.memUsed)) of \(Self.gigabytes($0.memTotal)), pressure \($0.pressure.rawValue)" } ?? "Memory")
    }

    private func battery(_ b: SystemActivity.Battery) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.batterySymbol(b))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(b.level < 0.15 && !b.pluggedIn ? Theme.Night.danger : Theme.Night.secondary)
                .frame(width: 26, alignment: .leading)
            Text(Self.percent(b.level))
                .font(Theme.allo(12.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.Night.foreground)
            Text(b.charging ? "Charging" : (b.pluggedIn ? "Plugged in" : "On battery"))
                .font(Theme.allo(12, .regular))
                .foregroundStyle(Theme.Night.muted)
            Spacer(minLength: 0)
        }
        .frame(height: Self.lineHeight)
    }

    private func network(_ a: SystemActivity?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "network")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Night.secondary)
                .frame(width: 26, alignment: .leading)
            rate("arrow.down", a?.netIn)
            rate("arrow.up", a?.netOut)
            Spacer(minLength: 0)
        }
        .frame(height: Self.lineHeight)
    }

    private func rate(_ symbol: String, _ v: Double?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Night.muted)
            Text(v.map(Self.rate) ?? "—")
                .font(Theme.allo(12.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.Night.foreground)
        }
    }

    // MARK: Formatting

    static func percent(_ f: Double) -> String { "\(Int((min(1, max(0, f)) * 100).rounded()))%" }

    static func gigabytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    /// Bytes per second: "0 KB/s", "86 KB/s", "1.4 MB/s".
    static func rate(_ bps: Double) -> String {
        let b = max(0, bps)
        if b >= 1_000_000_000 { return String(format: "%.1f GB/s", b / 1_000_000_000) }
        if b >= 1_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
        return String(format: "%.0f KB/s", b / 1_000)
    }

    static func batterySymbol(_ b: SystemActivity.Battery) -> String {
        if b.charging { return "battery.100percent.bolt" }
        switch b.level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func thermal(_ t: ProcessInfo.ThermalState) -> (label: String, color: Color)? {
        switch t {
        case .nominal: nil
        case .fair: ("Warm", Theme.Night.warning)
        case .serious: ("Hot", Theme.Night.danger)
        case .critical: ("Throttling", Theme.Night.danger)
        @unknown default: nil
        }
    }
}

/// The last minute of CPU use: a line with a soft fill, drawn once per reading.
private struct SystemSparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else {
                var base = Path()
                base.move(to: CGPoint(x: 0, y: size.height - 1))
                base.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                ctx.stroke(base, with: .color(Color.white.opacity(0.1)), lineWidth: 1)
                return
            }
            // 60 samples fill the width; fewer start from the right.
            let n = max(values.count, 60)
            let step = size.width / CGFloat(n - 1)
            let x0 = size.width - step * CGFloat(values.count - 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: x0 + step * CGFloat(i), y: size.height - 1 - CGFloat(min(1, max(0, v))) * (size.height - 3))
            }
            var line = Path()
            line.addLines(pts)
            var fill = line
            fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            fill.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [Theme.Night.accent.opacity(0.28), Theme.Night.accent.opacity(0)]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(Theme.Night.accent), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
