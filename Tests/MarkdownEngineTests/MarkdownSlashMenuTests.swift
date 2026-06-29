//
//  MarkdownSlashMenuTests.swift
//  MarkdownEngineTests
//
//  Cross-platform tests for the `/` slash-command menu core (plan 3.2): trigger detection,
//  filtering, and the block-insert edits. Pure logic — no live text view.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Slash menu")
struct MarkdownSlashMenuTests {

    // MARK: - Trigger detection

    private func trigger(_ text: String, _ caret: Int) -> (query: String, sourceRange: NSRange)? {
        MarkdownSlashMenu.trigger(in: text, caret: caret)
    }

    @Test("A / at line start opens the menu with an empty query")
    func triggerAtLineStart() {
        let result = trigger("/", 1)
        #expect(result?.query == "")
        #expect(result?.sourceRange == NSRange(location: 0, length: 1))
    }

    @Test("Typing after the / grows the query and source range")
    func triggerWithQuery() {
        let result = trigger("/head", 5)
        #expect(result?.query == "head")
        #expect(result?.sourceRange == NSRange(location: 0, length: 5))
    }

    @Test("A / after whitespace opens the menu")
    func triggerAfterWhitespace() {
        let result = trigger("a /h", 4)
        #expect(result?.query == "h")
        #expect(result?.sourceRange == NSRange(location: 2, length: 2))
    }

    @Test("A / at the start of a non-first line opens the menu")
    func triggerAfterNewline() {
        let result = trigger("x\n/h", 4)
        #expect(result?.query == "h")
        #expect(result?.sourceRange == NSRange(location: 2, length: 2))
    }

    @Test("A mid-word slash does not open the menu")
    func noTriggerMidWord() {
        #expect(trigger("ab/c", 4) == nil)
    }

    @Test("A URL's slashes do not open the menu")
    func noTriggerInURL() {
        #expect(trigger("http://x", 8) == nil)
    }

    @Test("A space after the query closes the menu")
    func noTriggerAfterSpace() {
        #expect(trigger("/head ", 6) == nil)   // caret after the space
    }

    @Test("A caret right after the / (before a later space) still triggers")
    func triggerRightAfterSlash() {
        #expect(trigger("/ x", 1)?.query == "")
    }

    // MARK: - Filtering

    @Test("An empty query returns the whole menu")
    func filterEmptyReturnsAll() {
        #expect(MarkdownSlashMenu.items(matching: "") == MarkdownSlashMenu.allItems)
        #expect(MarkdownSlashMenu.allItems.count == 10)
    }

    @Test("Filtering matches titles, keywords, and block names")
    func filterMatches() {
        #expect(MarkdownSlashMenu.items(matching: "head").map(\.block) == [.heading1, .heading2, .heading3])
        #expect(MarkdownSlashMenu.items(matching: "todo").map(\.block) == [.checkbox])     // keyword
        #expect(MarkdownSlashMenu.items(matching: "quote").map(\.block) == [.blockquote])  // keyword
        #expect(MarkdownSlashMenu.items(matching: "divider").map(\.block) == [.divider])
        #expect(MarkdownSlashMenu.items(matching: "zzz").isEmpty)
    }

    @Test("Prefix matches rank ahead of substring matches")
    func filterRanksPrefixFirst() {
        // "code" is a prefix of the Code Block keyword; ensure it leads.
        #expect(MarkdownSlashMenu.items(matching: "code").first?.block == .codeBlock)
    }

    // MARK: - Block insertion edits

    private func insert(_ block: MarkdownBlockInsert, _ text: String, _ sourceRange: NSRange) -> FormattingEdit {
        MarkdownSlashMenu.insertEdit(block, replacing: sourceRange, in: text)
    }

    @Test("Heading insert replaces the /query with a heading prefix")
    func insertHeading() {
        #expect(insert(.heading1, "/h1", NSRange(location: 0, length: 3))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "# ", selection: NSRange(location: 2, length: 0)))
        #expect(insert(.heading3, "/h3", NSRange(location: 0, length: 3)).text == "### ")
    }

    @Test("List, checkbox, and quote inserts use their markers")
    func insertListFamily() {
        #expect(insert(.bulletList, "/b", NSRange(location: 0, length: 2)).text == "- ")
        #expect(insert(.numberedList, "/n", NSRange(location: 0, length: 2)).text == "1. ")
        #expect(insert(.checkbox, "/c", NSRange(location: 0, length: 2))
            == FormattingEdit(range: NSRange(location: 0, length: 2), text: "- [ ] ", selection: NSRange(location: 6, length: 0)))
        #expect(insert(.blockquote, "/q", NSRange(location: 0, length: 2)).text == "> ")
    }

    @Test("Code block insert drops a fenced block with the caret on the code line")
    func insertCodeBlock() {
        #expect(insert(.codeBlock, "/code", NSRange(location: 0, length: 5))
            == FormattingEdit(range: NSRange(location: 0, length: 5), text: "```\n\n```", selection: NSRange(location: 4, length: 0)))
    }

    @Test("Divider insert drops a thematic break")
    func insertDivider() {
        #expect(insert(.divider, "/div", NSRange(location: 0, length: 4))
            == FormattingEdit(range: NSRange(location: 0, length: 4), text: "---", selection: NSRange(location: 3, length: 0)))
    }

    @Test("Table insert drops a GFM starter and selects the first header cell")
    func insertTable() {
        let result = insert(.table, "/table", NSRange(location: 0, length: 6))
        #expect(result.text == "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |")
        #expect(result.selection == NSRange(location: 2, length: 8))   // "Column 1"
    }

    @Test("Insert keeps the line's existing content and prefixes it")
    func insertKeepsLineContent() {
        // "a /h" — selecting Heading converts the whole line, keeping "a ".
        #expect(insert(.heading1, "a /h", NSRange(location: 2, length: 2)).text == "# a ")
    }

    @Test("Insert preserves the line terminator")
    func insertPreservesTerminator() {
        #expect(insert(.bulletList, "/b\nnext", NSRange(location: 0, length: 2))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "- \n", selection: NSRange(location: 2, length: 0)))
    }

    @Test("A stale/out-of-range source range is a safe no-op (no crash)")
    func insertOutOfRangeIsNoOp() {
        // Simulates the host calling back with a published range after the document shrank.
        let result = insert(.heading1, "ab", NSRange(location: 5, length: 10))
        #expect(result.text == "")                                   // identity no-op
        #expect(result.range.length == 0)
        #expect(NSMaxRange(result.range) <= 2)                       // clamped within "ab"
    }

    @Test("Divider with trailing content puts the caret on the content line")
    func insertDividerWithContent() {
        // "a /d" → keep "a " below the rule, caret on that content line.
        let result = insert(.divider, "a /d", NSRange(location: 2, length: 2))
        #expect(result.text == "---\na ")
        #expect(result.selection == NSRange(location: 4, length: 0))
    }
}
