import Testing
import Foundation
@testable import SiliconModeKit

/// Log lines as the logs panel shows them: clipped on a word with a joined ellipsis, and the
/// assistant's Markdown read as plain text.
@Suite struct EventClipTests {
    @Test func shortTextIsOnlyCollapsed() {
        #expect(EventText.clip("  Ran:\tnpm   test\n\n -- auth  ", max: 80) == "Ran: npm test -- auth")
        #expect(EventText.clip("exactly ten", max: 11) == "exactly ten")
        #expect(EventText.clip("", max: 10) == "")
        #expect(EventText.clip("anything", max: 0) == "")
    }

    @Test func clipsOnAWordBoundaryWithAJoinedEllipsis() {
        // The orphaned ellipsis: "…running as …" wrapped the "…" onto a line of its own.
        let s = "The leak hunt, the question-card QA and the code review are running as separate workflows now"
        let c = EventText.clip(s, max: 72)
        #expect(c == "The leak hunt, the question-card QA and the code review are running as…")
        #expect(c.count <= 72)
        #expect(!c.contains(" …"))
    }

    @Test func neverEndsOnSpaceOrDanglingPunctuation() {
        // prefix(max - 1) ended on a space: "Stay quiet …".
        let c = EventText.clip("Do not change playback. Stay quiet unless asked", max: 36)
        #expect(c == "Do not change playback. Stay quiet…")
        #expect(EventText.clip("one two three, four five six", max: 15) == "one two three…")
        #expect(EventText.clip("Edited the file (and more besides)", max: 18) == "Edited the file…")
        for max in 2...60 {
            let c = EventText.clip("alpha, beta; gamma: delta — epsilon (zeta) eta. theta iota kappa lambda mu nu", max: max)
            #expect(c.count <= max)
            #expect(c.hasSuffix("…"))
            let beforeEllipsis = c.dropLast().last
            #expect(beforeEllipsis != " " && beforeEllipsis != "," && beforeEllipsis != ";")
        }
    }

    @Test func cutsMidWordWhenNoWordEndsNearby() {
        let path = "Read /a/very/long/path/without/any/spaces/at/all/in/it/whatsoever.swift"
        let c = EventText.clip(path, max: 40)
        #expect(c.count == 40)
        #expect(c.hasPrefix("Read /a/very/long/path/without/any/spac"))
        #expect(c.hasSuffix("…"))
        #expect(EventText.clip(String(repeating: "x", count: 100), max: 10) == String(repeating: "x", count: 9) + "…")
        #expect(EventText.clip("ab", max: 1) == "…")
    }

    @Test func longInputsStopEarly() {
        let huge = String(repeating: "word ", count: 200_000)
        let c = EventText.clip(huge, max: 140)
        #expect(c.count <= 140)
        #expect(c.hasSuffix("word…"))
    }
}

@Suite struct EventMarkdownTests {
    @Test func stripsInlineSyntaxKeepingTheWords() {
        let p = { EventText.plain(markdown: $0) }
        #expect(p("**Playback:** Spotify is still paused on *aas paas* by the artist.")
                == "Playback: Spotify is still paused on aas paas by the artist.")
        #expect(p("Run `npm test` and ``a `tick` inside``, then ~~skip~~ ship.") == "Run npm test and a `tick` inside, then skip ship.")
        #expect(p("See [the docs](https://example.com/a_(b)) and ![a chart](c.png \"Chart\").") == "See the docs and a chart.")
        #expect(p("Ref [the issue][12] and <https://example.com/x>.") == "Ref the issue and https://example.com/x.")
        #expect(p("___Both___ and __strong__ and _em_ and ***all***") == "Both and strong and em and all")
        #expect(p("line one<br>line two") == "line one line two")
    }

    @Test func leavesNonSyntaxAlone() {
        let p = { EventText.plain(markdown: $0) }
        #expect(p("snake_case_name and my_var_ stay") == "snake_case_name and my_var_ stay")
        #expect(p("2 * 3 * 4 = 24") == "2 * 3 * 4 = 24")
        #expect(p("Globs like *.swift and *.m") == "Globs like *.swift and *.m")
        #expect(p("Escaped \\*stars\\* and \\_under\\_") == "Escaped *stars* and _under_")
        #expect(p("Code keeps syntax: `**not bold** [x](y)`") == "Code keeps syntax: **not bold** [x](y)")
        #expect(p("Plain text, nothing to do.") == "Plain text, nothing to do.")
        #expect(p("Vec<String> and a < b > c") == "Vec<String> and a < b > c")
    }

    @Test func blocksBecomeOneLine() {
        let p = { EventText.plain(markdown: $0) }
        #expect(p("Nothing to return this tick, so I sent nothing.\n- **Playback:** paused.\n- **Queue:** empty")
                == "Nothing to return this tick, so I sent nothing. Playback: paused. Queue: empty")
        #expect(p("## Summary\n\n- Fixed the race\n- Added a test\n\nAll green.") == "Summary: Fixed the race; Added a test. All green.")
        #expect(p("Changes\n1. Moved the refresh\n2) Kept validate pure") == "Changes: Moved the refresh; Kept validate pure")
        #expect(p("> Quoted *advice*\n> continues here") == "Quoted advice continues here")
        #expect(p("- [x] Done item\n- [ ] Open item") == "Done item; Open item")
        #expect(p("Before\n\n---\n\nAfter") == "Before. After")
        #expect(p("| Name | Value |\n|---|:--:|\n| a | 1 |") == "Name, Value; a, 1")
        #expect(p("**Planning the fix**\n\nI'll move the refresh.") == "Planning the fix: I'll move the refresh.")
        #expect(p("#hashtag stays a word") == "#hashtag stays a word")
    }

    @Test func codeFencesAreLeftOutUnlessThatIsAll() {
        let p = { EventText.plain(markdown: $0) }
        #expect(p("Run this:\n```sh\nnpm test\n```\nThen ship.") == "Run this: Then ship.")
        #expect(p("```json\n{\"a\": 1}\n```") == "{\"a\": 1}")
    }

    @Test func strayMarkersFromACutGo() {
        // An earlier cut can leave half a span behind.
        #expect(EventText.plain(markdown: "Spotify is **paused on `aas") == "Spotify is paused on aas")
    }

    @Test func stopsReadingAtTheLimit() {
        let long = (0..<10_000).map { "Paragraph \($0) is here." }.joined(separator: "\n\n")
        let out = EventText.plain(markdown: long, limit: 200)
        #expect(out.count < 400)
        #expect(out.hasPrefix("Paragraph 0 is here. Paragraph 1 is here."))
    }

    @Test func saidLinesUseThePlainFirstSentence() {
        #expect(CoreText.firstSentence("**Playback:** Spotify is paused on *aas paas*. More later.", max: 72)
                == "Playback: Spotify is paused on aas paas.")
        #expect(CoreText.firstSentence("Use [the guide](https://x.dev/g) first. Then more.") == "Use the guide first.")
        #expect(CoreText.firstSentence("**Done**\n\nAll 42 tests pass. Shipping next.") == "All 42 tests pass.")
    }

    @Test func eventListReadsAssistantMarkdownOnly() {
        var list = EventList(prefix: "p")
        list.add("1", at: Date(), .assistant, "Nothing to return, so I sent nothing.\n- **Playback:** Spotify is paused on *aas paas*.")
        list.add("2", at: Date(), .user, "Keep the **literal** text I typed")
        list.add("3", at: Date(), .assistant, "```\n```")
        #expect(list.events.map(\.text) == ["Nothing to return, so I sent nothing. Playback: Spotify is paused on aas paas.",
                                             "Keep the **literal** text I typed"])
    }
}

@Suite struct ModeLogTabsTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func s(_ id: String, _ state: AgentState, started: Double?, updated: Double) -> AgentSession {
        AgentSession(provider: "p", nativeID: id, title: id, state: state,
                     startedAt: started.map { t0.addingTimeInterval($0) }, updatedAt: t0.addingTimeInterval(updated))
    }

    @Test func orderFollowsStartTimeAndNeverReshuffles() {
        var tabs = ModeLogTabs()
        let a = s("a", .working, started: 10, updated: 50), b = s("b", .finished, started: 0, updated: 90)
        tabs.update([a, b])
        #expect(tabs.order == ["p:b", "p:a"])
        // State and activity changes don't move tabs (the agent list sorts by urgency, tabs don't).
        var a2 = a; a2.state = .needsYou; a2.updatedAt = t0.addingTimeInterval(200)
        var b2 = b; b2.state = .working
        tabs.update([a2, b2])
        #expect(tabs.order == ["p:b", "p:a"])
        // A newer agent opens at the end; one without a start time counts as starting when first seen.
        let c = s("c", .working, started: nil, updated: 300)
        tabs.update([c, a2, b2], now: t0.addingTimeInterval(300))
        #expect(tabs.order == ["p:b", "p:a", "p:c"])
        #expect(tabs.ordered([c, a2, b2]).map(\.id) == ["p:b", "p:a", "p:c"])
        // A start time revised later doesn't move a tab.
        var b3 = b2; b3.startedAt = t0.addingTimeInterval(500)
        tabs.update([c, a2, b3])
        #expect(tabs.order == ["p:b", "p:a", "p:c"])
    }

    @Test func firstSelectionPrefersWhoNeedsYou() {
        var tabs = ModeLogTabs()
        let busy = s("busy", .working, started: 0, updated: 100)
        let asks = s("asks", .needsYou, started: 10, updated: 50)
        #expect(tabs.selection(in: [busy, asks]) == "p:asks")
        tabs.update([busy, asks])
        #expect(tabs.selected == "p:asks")

        var quiet = ModeLogTabs()
        quiet.update([busy, s("old", .finished, started: 5, updated: 20)])
        #expect(quiet.selected == "p:busy")
    }

    @Test func autoSelectsOncePerNeedAndKeepsTheUsersPick() {
        var tabs = ModeLogTabs()
        var a = s("a", .working, started: 0, updated: 10)
        var b = s("b", .working, started: 5, updated: 20)
        tabs.update([a, b])
        #expect(tabs.selected == "p:b")
        tabs.select("p:a")
        tabs.update([a, b])
        #expect(tabs.selected == "p:a")

        // b starts needing you: selected once.
        b.state = .needsYou
        let changed = tabs.update([a, b])
        #expect(changed)
        #expect(tabs.selected == "p:b")
        // The user goes back to a while b still waits: b doesn't take it again.
        tabs.select("p:a")
        tabs.update([a, b])
        tabs.update([a, b])
        #expect(tabs.selected == "p:a")
        // b is answered, then asks again: a new need, selected again.
        b.state = .working
        tabs.update([a, b])
        #expect(tabs.selected == "p:a")
        b.state = .needsYou
        tabs.update([a, b])
        #expect(tabs.selected == "p:b")

        // While the selected agent needs you, another one's need doesn't pull the tab away.
        a.state = .needsYou
        tabs.update([a, b])
        #expect(tabs.selected == "p:b")
    }

    @Test func aLeavingSelectionPassesToTheTabThatTakesItsPlace() {
        var tabs = ModeLogTabs()
        let a = s("a", .working, started: 0, updated: 10)
        let b = s("b", .working, started: 1, updated: 30)
        let c = s("c", .working, started: 2, updated: 20)
        tabs.update([a, b, c])
        #expect(tabs.selected == "p:b")
        tabs.update([a, c])
        #expect(tabs.selected == "p:c")
        tabs.update([a])
        #expect(tabs.selected == "p:a")
        tabs.update([])
        #expect(tabs.selection(in: []) == nil)
        let d = s("d", .working, started: 3, updated: 40)
        tabs.update([d])
        #expect(tabs.selected == "p:d")
    }
}
