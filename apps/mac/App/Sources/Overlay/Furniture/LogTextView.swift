import SwiftUI
import AppKit
import SiliconModeKit

/// The live log body: a native, non-editable text view in an `NSScrollView` (overlay scrollers),
/// one paragraph per event: time, the kind's SF Symbol, the text (commands and paths in SF Mono).
///
/// Why AppKit: a SwiftUI `ScrollView` + `LazyVStack` here makes SwiftUI rebuild its key-view loop
/// (`FocusBridge`) for every responder in the scroll view whenever its content changes, and with a
/// long log that rebuild pinned the main thread. A text view is a single view with its own,
/// exact TextKit 1 layout: no lazy re-estimation, no per-line SwiftUI views.
///
/// - Its size is fixed by the furniture plan (from line counts), never by its content.
/// - Appends are incremental: only paragraphs after the first changed event are rewritten, and
///   events dropped from the front (the log book's cap) are removed from the front.
/// - It follows the tail while the view rests at the bottom; scrolling up pauses that, counts the
///   unseen lines into `unseen`, and scrolling back down (or `jump`) resumes it. Only the user's
///   own scrolling (wheel, trackpad, scroller) decides that: layout and resizes never do.
struct LogTextView: NSViewRepresentable {
    let events: [AgentEvent]
    @Binding var following: Bool
    @Binding var unseen: Int
    /// Changes when the "Latest" button is pressed: scroll to the end and follow again.
    let jump: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> LogScrollView {
        let c = context.coordinator
        let scroll = LogScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        // TextKit 1: exact layout, so "scroll to the end" lands at the end.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let text = LogNSTextView(frame: .zero, textContainer: container)
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = false
        text.isRichText = true
        text.textContainerInset = NSSize(width: 16, height: 12)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text

        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.liveScrolled(_:)),
                                               name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.liveScrolled(_:)),
                                               name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        scroll.onResize = { [weak c] in c?.keepTail() }
        scroll.onUserScroll = { [weak c] in c?.userScrolled() }
        c.attach(scroll: scroll, text: text)
        c.lastJump = jump
        c.apply(events, initial: true)
        return scroll
    }

    func updateNSView(_ scroll: LogScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.apply(events, initial: false)
        if jump != c.lastJump {
            c.lastJump = jump
            c.scrollToEnd()
        }
    }

    static func dismantleNSView(_ scroll: LogScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        scroll.onResize = nil
        scroll.onUserScroll = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: LogTextView
        var lastJump = 0
        private weak var scroll: NSScrollView?
        private weak var text: NSTextView?
        /// What each paragraph shows, and where it starts in the text storage.
        private var rendered: [Rendered] = []
        private var offsets: [Int] = []

        private struct Rendered: Equatable {
            var id: String
            var at: Date
            var kind: AgentEvent.Kind
            var text: String
            init(_ e: AgentEvent) { id = e.id; at = e.at; kind = e.kind; text = e.text }
        }

        init(_ parent: LogTextView) { self.parent = parent }

        func attach(scroll: NSScrollView, text: NSTextView) {
            self.scroll = scroll
            self.text = text
        }

        // MARK: Content

        func apply(_ events: [AgentEvent], initial: Bool) {
            guard let storage = text?.textStorage else { return }
            let new = events.map(Rendered.init)
            if new == rendered { return }

            storage.beginEditing()
            // The log book drops its oldest lines once full: drop them here too.
            if let first = new.first, rendered.first?.id != first.id,
               let k = rendered.firstIndex(where: { $0.id == first.id }), k > 0 {
                // Paragraph k starts with the newline that separated it from k - 1: remove that too.
                let cut = offsets[k] + 1
                storage.deleteCharacters(in: NSRange(location: 0, length: min(cut, storage.length)))
                rendered.removeFirst(k)
                offsets = offsets.dropFirst(k).map { max(0, $0 - cut) }
                if !offsets.isEmpty { offsets[0] = 0 }
            }
            var common = 0
            while common < rendered.count, common < new.count, rendered[common] == new[common] { common += 1 }
            if common < rendered.count {
                let cut = offsets[common]
                storage.deleteCharacters(in: NSRange(location: cut, length: storage.length - cut))
                rendered.removeSubrange(common...)
                offsets.removeSubrange(common...)
            }
            let added = new.count - common
            for (i, e) in events[common...].enumerated() {
                offsets.append(storage.length)
                storage.append(LogParagraph.make(e, first: common + i == 0))
                rendered.append(new[common + i])
            }
            storage.endEditing()

            if initial || parent.following {
                scrollToEnd()
            } else if added > 0 {
                let n = parent.unseen + added
                Task { @MainActor [weak self] in self?.parent.unseen = n }
            }
        }

        // MARK: Scrolling

        private var atBottom: Bool {
            guard let scroll, let doc = scroll.documentView else { return true }
            return scroll.contentView.bounds.maxY >= doc.frame.height - 8
        }

        func scrollToEnd() {
            guard let scroll, let text, let layout = text.layoutManager, let container = text.textContainer else { return }
            layout.ensureLayout(for: container)
            text.sizeToFit()
            let y = max(0, text.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            if !parent.following || parent.unseen != 0 {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.parent.following { self.parent.following = true }
                    if self.parent.unseen != 0 { self.parent.unseen = 0 }
                }
            }
        }

        /// The view was resized (minimise, a new plan): stay on the tail while following.
        func keepTail() {
            if parent.following { scrollToEnd() }
        }

        /// The scroller was dragged (live scroll): same as a wheel scroll.
        @objc func liveScrolled(_ note: Notification) { userScrolled() }

        /// The user scrolled: resting at the bottom follows the tail again, anywhere else pauses it.
        func userScrolled() {
            let bottom = atBottom
            let following = parent.following, unseen = parent.unseen
            guard bottom != following || (bottom && unseen != 0) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.parent.following != bottom { self.parent.following = bottom }
                if bottom, self.parent.unseen != 0 { self.parent.unseen = 0 }
            }
        }
    }
}

/// Reports size changes (so a following log stays on its tail) and the user's own scrolling.
final class LogScrollView: NSScrollView {
    var onResize: (() -> Void)?
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScroll?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }
}

/// A text view that never takes keyboard focus (any key in Silicon Mode belongs to the PIN pad).
final class LogNSTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
}

/// One event as a paragraph: "12:04:31  [symbol]  text", wrapped lines indented under the text.
@MainActor
enum LogParagraph {
    static let textFont = NSFont.preferredFont(forTextStyle: .callout)
    static let userFont = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .medium)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
    static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)
    /// Where the symbol and the text start (the time column is as wide as "00:00:00" plus a gap).
    static let iconX: CGFloat = ceil(("00:00:00" as NSString).size(withAttributes: [.font: timeFont]).width) + 10
    static let textX: CGFloat = iconX + 22

    private static let style: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.tabStops = [NSTextTab(textAlignment: .left, location: iconX), NSTextTab(textAlignment: .left, location: textX)]
        p.defaultTabInterval = 0
        p.headIndent = textX
        p.lineSpacing = 2
        p.paragraphSpacingBefore = 0
        p.paragraphSpacing = 8
        p.lineBreakMode = .byWordWrapping
        return p
    }()

    private static var symbols: [String: NSImage] = [:]

    static func make(_ e: AgentEvent, first: Bool) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.paragraphStyle: style, .font: textFont]
        if !first { s.append(NSAttributedString(string: "\n", attributes: base)) }
        s.append(NSAttributedString(string: HUDFormat.clock(e.at) + "\t", attributes: [
            .paragraphStyle: style, .font: timeFont, .foregroundColor: LogInk.time,
        ]))
        let icon = NSTextAttachment()
        if let img = symbol(LogLineRow.symbol(e.kind, e.text), color: iconColor(e.kind)) {
            icon.image = img
            // Centred on the text's x-height.
            let y = (textFont.capHeight - img.size.height) / 2
            icon.bounds = CGRect(x: 0, y: y.rounded(), width: img.size.width, height: img.size.height)
        }
        s.append(NSAttributedString(attachment: icon))
        s.addAttributes(base, range: NSRange(location: s.length - 1, length: 1))
        s.append(NSAttributedString(string: "\t", attributes: base))

        let color = textColor(e.kind)
        let font = e.kind == .user ? userFont : textFont
        let body = EventText.clip(e.text, max: 280)
        if e.kind == .tool || e.kind == .permission, let parts = LogCode.split(body) {
            s.append(NSAttributedString(string: parts.lead, attributes: base.merging([.foregroundColor: color, .font: font]) { $1 }))
            s.append(NSAttributedString(string: parts.code, attributes: base.merging([.foregroundColor: color, .font: codeFont]) { $1 }))
            s.append(NSAttributedString(string: parts.tail, attributes: base.merging([.foregroundColor: color, .font: font]) { $1 }))
        } else {
            s.append(NSAttributedString(string: body, attributes: base.merging([.foregroundColor: color, .font: font]) { $1 }))
        }
        return s
    }

    static func textColor(_ k: AgentEvent.Kind) -> NSColor {
        switch k {
        case .permission, .question: .systemOrange
        case .error: .systemRed
        case .assistant, .user: LogInk.primary
        case .tool: LogInk.secondary
        case .thinking, .status, .toolResult: LogInk.quiet
        }
    }

    static func iconColor(_ k: AgentEvent.Kind) -> NSColor {
        switch k {
        case .permission, .question: .systemOrange
        case .error: .systemRed
        case .user: .systemBlue
        case .assistant, .tool: LogInk.icon
        case .thinking, .status, .toolResult: LogInk.quiet
        }
    }

    private static func symbol(_ name: String, color: NSColor) -> NSImage? {
        let key = "\(name)|\(color.description)"
        if let img = symbols[key] { return img }
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        symbols[key] = img
        return img
    }
}

/// Log ink on the dimmed glass panel. The system's tertiary label (25% white) vanishes over a busy
/// face; these keep the same hierarchy (text, tools, plan and status, times) with every level legible.
enum LogInk {
    static let primary = NSColor(white: 1, alpha: 0.92)
    static let secondary = NSColor(white: 1, alpha: 0.72)
    static let quiet = NSColor(white: 1, alpha: 0.52)
    static let icon = NSColor(white: 1, alpha: 0.6)
    static let time = NSColor(white: 1, alpha: 0.46)
}
