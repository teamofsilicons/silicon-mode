import SwiftUI
import AppKit
import SiliconModeKit

/// An agent's avatar: a Silicon's profile photo (or monogram) with the TOS badge, anything else its
/// provider mark. Optional state dot at the bottom-trailing corner.
///
/// Badge and state dot sit in knocked-out rings (transparent gaps), so the avatar reads on any
/// background: the night overlay, the menu bar's glass, faces.
///
/// The photo comes from `AppModel.avatars` (memory or disk cache, never the network). Snapshot
/// renders always draw the monogram.
struct AgentAvatarView: View {
    let provider: String
    let identity: AgentIdentity?
    let state: AgentState?
    var size: CGFloat
    var showsState: Bool

    @Environment(AppModel.self) private var model

    init(session: AgentSession, size: CGFloat, showsState: Bool = true) {
        provider = session.provider
        identity = session.identity
        state = session.state
        self.size = size
        self.showsState = showsState
    }

    init(provider: String, identity: AgentIdentity?, state: AgentState? = nil, size: CGFloat, showsState: Bool = true) {
        self.provider = provider
        self.identity = identity
        self.state = state
        self.size = size
        self.showsState = showsState
    }

    /// The badge is hidden on avatars smaller than this.
    static let badgeMinSize: CGFloat = 20

    private var silicon: AgentIdentity? { identity?.isSilicon == true ? identity : nil }
    private var showsBadge: Bool { silicon != nil && size >= Self.badgeMinSize }
    private var dotState: AgentState? { showsState ? state : nil }

    // Badge and dot geometry.
    private var badgeSize: CGFloat { (size * 0.38).rounded() }
    private var dotSize: CGFloat { max(5, size * 0.32) }
    private var gap: CGFloat { max(1.25, size * 0.05) }
    private var badgeOffset: CGSize { CGSize(width: badgeSize * 0.22, height: -badgeSize * 0.22) }
    private var dotOffset: CGSize { CGSize(width: dotSize * 0.2, height: dotSize * 0.2) }

    var body: some View {
        base
            .frame(width: size, height: size)
            .mask {
                Rectangle()
                    .overlay(alignment: .topTrailing) {
                        if showsBadge {
                            Circle().frame(width: badgeSize + gap * 2, height: badgeSize + gap * 2)
                                .offset(badgeOffset).blendMode(.destinationOut)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if dotState != nil {
                            Circle().frame(width: dotSize + gap * 2, height: dotSize + gap * 2)
                                .offset(dotOffset).blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
            }
            .overlay(alignment: .topTrailing) {
                if showsBadge {
                    TOSBadge(size: badgeSize)
                        .frame(width: badgeSize + gap * 2, height: badgeSize + gap * 2)
                        .offset(badgeOffset)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let s = dotState {
                    Circle().fill(Theme.stateColor(s, night: false))
                        .frame(width: dotSize, height: dotSize)
                        .frame(width: dotSize + gap * 2, height: dotSize + gap * 2)
                        .offset(dotOffset)
                }
            }
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(accessibilityName)
    }

    @ViewBuilder
    private var base: some View {
        if let silicon {
            SiliconAvatar(identity: silicon, image: SnapshotHarness.isRendering ? nil : model.avatars.image(for: silicon), size: size)
        } else {
            ProviderMark(provider: provider, size: size)
        }
    }

    private var accessibilityName: String {
        let name = silicon?.name ?? ProviderCatalog.info(for: provider).name
        guard showsState, let state else { return name }
        return "\(name), \(state.label)"
    }
}

/// A Silicon's photo in a rounded square, or its monogram on the silicon gradient.
struct SiliconAvatar: View {
    let identity: AgentIdentity
    let image: NSImage?
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                shape.fill(LinearGradient(colors: [FaceA.lavender.color(), FaceA.peach.color()],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                let mono = identity.monogram
                Text(mono)
                    .font(Theme.allo(size * (mono.count > 1 ? 0.36 : 0.44), .semibold))
                    .tracking(-size * 0.01)
                    .foregroundStyle(Color(hex: "1B1B1B"))
                    .minimumScaleFactor(0.5)
                    .offset(y: -size * 0.01)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(image == nil ? 0.35 : 0.14), lineWidth: max(0.5, size * 0.015)))
    }
}

/// The TOS mark, light on a dark disc (the badge on a Silicon's avatar).
struct TOSBadge: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: "181818"))
            Circle().strokeBorder(.white.opacity(0.14), lineWidth: max(0.5, size * 0.04))
            TOSMark()
                .fill(Color(hex: "EDE8E0"))
                .padding(size * 0.19)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The Team of Silicons mark: eight squares around a diamond, in a unit box aspect-fit and centered
/// in the rect. One path, every part wound the same way, so overlaps fill.
struct TOSMark: Shape {
    /// Side of each square, as a fraction of the mark's box.
    static let square: CGFloat = 0.2571
    /// Top-left corners of the eight squares.
    static let squares: [CGPoint] = [
        CGPoint(x: 0, y: 0.3715), CGPoint(x: 0.3714, y: 0), CGPoint(x: 0.7429, y: 0.3715), CGPoint(x: 0.3714, y: 0.7429),
        CGPoint(x: 0.1143, y: 0.1143), CGPoint(x: 0.6286, y: 0.1143), CGPoint(x: 0.1143, y: 0.6286), CGPoint(x: 0.6286, y: 0.6286),
    ]
    /// Half diagonal of the center diamond.
    static let diamond: CGFloat = 0.2774

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let ox = rect.midX - side / 2, oy = rect.midY - side / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * side, y: oy + y * side) }
        var path = Path()
        for o in Self.squares {
            // Clockwise (on screen): top-left, top-right, bottom-right, bottom-left.
            path.move(to: p(o.x, o.y))
            path.addLine(to: p(o.x + Self.square, o.y))
            path.addLine(to: p(o.x + Self.square, o.y + Self.square))
            path.addLine(to: p(o.x, o.y + Self.square))
            path.closeSubpath()
        }
        // Clockwise too: top, right, bottom, left.
        let d = Self.diamond
        path.move(to: p(0.5, 0.5 - d))
        path.addLine(to: p(0.5 + d, 0.5))
        path.addLine(to: p(0.5, 0.5 + d))
        path.addLine(to: p(0.5 - d, 0.5))
        path.closeSubpath()
        return path
    }
}

/// Every avatar flavour at several sizes (snapshot `agent-avatars`).
struct AgentAvatarSheet: View {
    static let silicon = AgentIdentity(kind: AgentIdentity.siliconKind, handle: "si:demo_scout", displayName: "Scout",
                                       members: [.init(name: "digest", state: .working)])
    static let duo = AgentIdentity(kind: AgentIdentity.siliconKind, handle: "si:night_owl", members: [])

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            row("Silicon · state", provider: "silicon", identity: Self.silicon, states: [.working, .needsYou, .finished, .error, .idle])
            row("Silicon · no state", provider: "silicon", identity: Self.duo, states: [nil])
            row("Providers", provider: "claude-code", identity: nil, states: [.working, .needsYou])
            HStack(spacing: 18) {
                TOSMark().fill(Theme.foreground).frame(width: 96, height: 96)
                TOSBadge(size: 64)
                TOSBadge(size: 24)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    private func row(_ title: String, provider: String, identity: AgentIdentity?, states: [AgentState?]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.allo(12, .medium)).foregroundStyle(Theme.textMuted)
            HStack(alignment: .bottom, spacing: 18) {
                ForEach([96, 64, 40, 28, 20, 16, 13] as [CGFloat], id: \.self) { size in
                    HStack(spacing: 8) {
                        ForEach(Array(states.enumerated()), id: \.offset) { _, st in
                            AgentAvatarView(provider: provider, identity: identity, state: st, size: size, showsState: st != nil)
                        }
                    }
                }
            }
        }
    }
}
