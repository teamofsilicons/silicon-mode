import Foundation

// MARK: - Markdown as plain text

/// Agents answer in Markdown; a log line is plain text. These helpers keep the words and drop the
/// syntax, so "- **Playback:** paused on *Song*" reads "Playback: paused on Song" on every surface
/// that shows the line (overlay, menu bar, phone, web).
extension EventText {
    /// One block of a Markdown message, as plain text.
    struct PlainBlock: Equatable, Sendable {
        enum Kind: Sendable { case heading, item, paragraph }
        var kind: Kind
        var text: String
    }

    /// Markdown as one line of plain text: the words stay, the syntax goes.
    ///
    /// - Emphasis, strike-through and code backticks are dropped (code keeps its text); links and
    ///   images keep their text; autolinks keep their address.
    /// - Headings, list items and paragraphs become sentences of one line: a heading or a line
    ///   that introduces a list is followed by ": ", list items by "; ", unless they already end
    ///   in punctuation. Quote markers, rules and table rulers go.
    /// - Fenced code is left out (a message that is only code keeps the code).
    /// - Stops reading once about `limit` characters of text are collected.
    public static func plain(markdown s: String, limit: Int = 2000) -> String {
        let blocks = plainBlocks(s, limit: limit)
        var out = ""
        for (i, b) in blocks.enumerated() {
            if i > 0 { out += separator(after: blocks[i - 1], before: b) }
            out += b.text
        }
        return out
    }

    /// The message's blocks as plain text (see `plain(markdown:limit:)`).
    static func plainBlocks(_ s: String, limit: Int = 2000) -> [PlainBlock] {
        var blocks: [PlainBlock] = []
        var code: [String] = []
        var current: PlainBlock?
        var fence: String?
        var total = 0

        func flush() {
            guard let c = current else { return }
            current = nil
            let text = inlinePlain(c.text)
            guard !text.isEmpty else { return }
            blocks.append(PlainBlock(kind: c.kind, text: text))
            total += text.count
        }

        var rest = s[...]
        while !rest.isEmpty, total < limit {
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            let raw = rest[..<end]
            rest = end < rest.endIndex ? rest[rest.index(after: end)...] : rest[rest.endIndex...]
            var line = raw.trimmingCharacters(in: .whitespaces)

            if let f = fence {
                if line.hasPrefix(f) { fence = nil } else if code.count < 12, !line.isEmpty { code.append(line) }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                fence = String(line.prefix(3))
                continue
            }
            // Block quotes: the markers go, the text stays.
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if line.isEmpty || isRule(line) { flush(); continue }
            if let h = heading(line) {
                flush()
                current = PlainBlock(kind: .heading, text: h)
                flush()
                continue
            }
            if let item = listItem(line) {
                flush()
                current = PlainBlock(kind: .item, text: item)
                continue
            }
            if line.hasPrefix("|") {
                // A table row: its cells, comma-separated.
                flush()
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                current = PlainBlock(kind: .item, text: cells.joined(separator: ", "))
                flush()
                continue
            }
            if current == nil, let label = boldLabel(line) {
                // "**Summary**" on a line of its own reads like a heading.
                current = PlainBlock(kind: .heading, text: label)
                flush()
                continue
            }
            if current != nil { current!.text += " " + line } else { current = PlainBlock(kind: .paragraph, text: line) }
        }
        flush()
        if blocks.isEmpty, !code.isEmpty {
            return [PlainBlock(kind: .paragraph, text: clip(code.joined(separator: " "), max: Swift.max(1, limit)))]
        }
        return blocks
    }

    private static func separator(after a: PlainBlock, before b: PlainBlock) -> String {
        if let last = a.text.last, ".!?:;,…".contains(last) { return " " }
        switch (a.kind, b.kind) {
        case (.heading, _): return ": "
        case (.item, .item): return "; "
        case (_, .item): return ": "
        default: return ". "
        }
    }

    // MARK: Block syntax

    /// "---", "***", "___", "===" and table rulers ("|---|:--:|").
    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3 else { return false }
        if chars.allSatisfy({ "-*_=".contains($0) }) { return Set(chars).count == 1 }
        return chars.contains("-") && chars.allSatisfy { "|:-".contains($0) }
    }

    /// "## Title ##" → "Title".
    private static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// "- x", "* x", "+ x", "1. x", "1) x" (and task boxes "- [ ] x") → "x".
    private static func listItem(_ line: String) -> String? {
        var rest: Substring
        if let f = line.first, "-*+".contains(f), line.dropFirst().first == " " {
            rest = line.dropFirst(2)
        } else {
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            guard (1...3).contains(digits.count) else { return nil }
            let after = line.dropFirst(digits.count)
            guard let m = after.first, m == "." || m == ")", after.dropFirst().first == " " else { return nil }
            rest = after.dropFirst(2)
        }
        rest = rest.drop { $0 == " " }
        for box in ["[ ] ", "[x] ", "[X] "] where rest.hasPrefix(box) { rest = rest.dropFirst(box.count) }
        return String(rest)
    }

    /// A line that is only strong text ("**Summary**", "__Next:__") → its text, without a trailing colon.
    private static func boldLabel(_ line: String) -> String? {
        for m in ["**", "__"] where line.hasPrefix(m) {
            var inner = line.dropFirst(2)
            if inner.hasSuffix(m) { inner = inner.dropLast(2) } else if inner.hasSuffix(m + ":") { inner = inner.dropLast(3) } else { continue }
            guard !inner.isEmpty, !inner.contains("*"), !inner.contains("_"), inner.first != " ", inner.last != " " else { continue }
            var text = String(inner)
            if text.hasSuffix(":") { text.removeLast() }
            return text
        }
        return nil
    }

    // MARK: Inline syntax

    /// Inline Markdown as plain text (one line, whitespace collapsed).
    static func inlinePlain(_ s: String) -> String {
        guard s.contains(where: { Self.inlineMarks.contains($0) }) else { return collapse(s) }
        // Code spans and backslash escapes are set aside first, so nothing inside them reads as
        // syntax. Their stand-ins are private-use characters; text that already has some (a rare
        // icon font) skips that step.
        let protect = !s.unicodeScalars.contains { $0.value >= 0xF0000 }
        var spans: [String] = []
        var text = protect ? setAside(s, spans: &spans) : s
        for (re, template) in inlineRules {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        // Syntax left unmatched (often by an earlier cut): stray strong markers and backticks.
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        if protect { text = restore(text, spans: spans) }
        return collapse(text)
    }

    private static let inlineMarks: Set<Character> = ["*", "_", "`", "[", "<", "~", "\\"]

    /// Escapes become U+F0000 + their ASCII code; code spans U+F0100 + their index.
    private static let escapeBase: UInt32 = 0xF0000
    private static let spanBase: UInt32 = 0xF0100

    private static func setAside(_ s: String, spans: inout [String]) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\", i + 1 < scalars.count, scalars[i + 1].isASCII,
               "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars.contains(scalars[i + 1]) {
                out.append(Unicode.Scalar(escapeBase + scalars[i + 1].value)!)
                i += 2
                continue
            }
            if c == "`" {
                var n = 0
                while i + n < scalars.count, scalars[i + n] == "`" { n += 1 }
                // The closing run: exactly as many backticks.
                var j = i + n, close: Int?
                while j < scalars.count {
                    if scalars[j] == "`" {
                        var m = 0
                        while j + m < scalars.count, scalars[j + m] == "`" { m += 1 }
                        if m == n { close = j; break }
                        j += m
                    } else {
                        j += 1
                    }
                }
                if let close, spans.count < 0xFF00 {
                    var body = String.UnicodeScalarView()
                    body.append(contentsOf: scalars[(i + n)..<close])
                    spans.append(String(body).trimmingCharacters(in: .whitespaces))
                    out.append(Unicode.Scalar(spanBase + UInt32(spans.count - 1))!)
                    i = close + n
                    continue
                }
                out.append(contentsOf: scalars[i..<(i + n)])
                i += n
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    private static func restore(_ s: String, spans: [String]) -> String {
        guard s.unicodeScalars.contains(where: { $0.value >= escapeBase }) else { return s }
        var out = ""
        for c in s.unicodeScalars {
            if c.value >= spanBase, Int(c.value - spanBase) < spans.count {
                out += spans[Int(c.value - spanBase)]
            } else if c.value >= escapeBase, c.value < escapeBase + 0x80 {
                out.unicodeScalars.append(Unicode.Scalar(c.value - escapeBase)!)
            } else {
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// Applied in order: images and links first (their text may hold emphasis), then emphasis,
    /// strongest first.
    private static let inlineRules: [(NSRegularExpression, String)] = [
        // ![alt](url "title") → alt; [text](url "title") → text (one level of parentheses in the url).
        (#"!\[([^\]]*)\]\((?:[^()\s]|\([^()\s]*\))*(?:\s+"[^"]*")?\)"#, "$1"),
        (#"\[([^\]]+)\]\((?:[^()\s]|\([^()\s]*\))*(?:\s+"[^"]*")?\)"#, "$1"),
        // [text][ref] → text; <https://…> → https://…; <br> → space.
        (#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),
        (#"<((?:https?|mailto|ftp):[^>\s]+)>"#, "$1"),
        (#"<br\s*/?>"#, " "),
        // ***x***, **x**, __x__ (not inside a word), ~~x~~.
        (#"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#, "$1"),
        (#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "$1"),
        (#"(?<![\p{L}\p{N}_])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}_])"#, "$1"),
        (#"~~(?=\S)(.+?)(?<=\S)~~"#, "$1"),
        // *x* and _x_, not inside a word ("a*b*c", snake_case_names) or around spaces ("2 * 3").
        (#"(?<![\p{L}\p{N}*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\p{L}\p{N}*])"#, "$1"),
        (#"(?<![\p{L}\p{N}_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\p{L}\p{N}_])"#, "$1"),
    ].compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }

    /// Whitespace runs as single spaces, trimmed.
    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
