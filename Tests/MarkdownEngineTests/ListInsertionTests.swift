//
//  ListInsertionTests.swift
//  MarkdownEngineTests
//
//  Cross-platform regression net for `MarkdownLists.computeListInsertion` — the
//  pure list/blockquote/indent/auto-pair input logic extracted in Phase 2b so the
//  macOS NSTextView path and the iOS UITextView path share one implementation.
//  These run on the macOS host and lock the behavior the macOS editor had inline.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("List insertion decisions")
struct ListInsertionTests {

    private let config = MarkdownEditorConfiguration.default

    private func decide(_ text: String, _ replacement: String, at location: Int, length: Int = 0) -> ListInsertionDecision {
        MarkdownLists.computeListInsertion(
            currentText: text,
            affectedCharRange: NSRange(location: location, length: length),
            replacementString: replacement,
            configuration: config
        )
    }

    private func end(of text: String) -> Int { (text as NSString).length }

    // MARK: - Fast path

    @Test("Ordinary character insertion is allowed through untouched")
    func ordinaryCharAllowsDefault() {
        #expect(decide("hello", "x", at: 5) == .allowDefault)
    }

    // MARK: - Enter continuation

    @Test("Enter on a non-empty bullet continues the list")
    func enterContinuesBullet() {
        let text = "- foo"
        #expect(decide(text, "\n", at: end(of: text)) == .replace(range: NSRange(location: 5, length: 0), text: "\n- ", caret: 8))
    }

    @Test("Enter on a non-empty numbered item increments the number")
    func enterContinuesNumbered() {
        let text = "1. foo"
        #expect(decide(text, "\n", at: end(of: text)) == .replace(range: NSRange(location: 6, length: 0), text: "\n2. ", caret: 10))
    }

    @Test("Enter on a non-empty checkbox item continues with an unchecked box")
    func enterContinuesCheckbox() {
        let text = "- [ ] foo"
        #expect(decide(text, "\n", at: end(of: text)) == .replace(range: NSRange(location: 9, length: 0), text: "\n- [ ] ", caret: 16))
    }

    @Test("Enter on a non-empty blockquote continues the quote")
    func enterContinuesBlockquote() {
        let text = "> foo"
        #expect(decide(text, "\n", at: end(of: text)) == .replace(range: NSRange(location: 5, length: 0), text: "\n> ", caret: 8))
    }

    @Test("Enter on an empty bullet item exits the list (removes the marker)")
    func enterExitsEmptyBullet() {
        let text = "- "
        #expect(decide(text, "\n", at: end(of: text)) == .replace(range: NSRange(location: 0, length: 2), text: "", caret: 0))
    }

    @Test("Enter on an empty blockquote exits the quote")
    func enterExitsEmptyBlockquote() {
        let text = "> "
        #expect(decide(text, "\n", at: end(of: text)) == .replace(range: NSRange(location: 0, length: 2), text: "", caret: 0))
    }

    // MARK: - Tab indent

    @Test("Tab on a list item inserts a leading tab and shifts the caret")
    func tabIndentsListItem() {
        let text = "- foo"
        #expect(decide(text, "\t", at: end(of: text)) == .replace(range: NSRange(location: 0, length: 0), text: "\t", caret: 6))
    }

    @Test("Tab on a non-list line is allowed through")
    func tabOnPlainLineAllowsDefault() {
        #expect(decide("plain", "\t", at: 5) == .allowDefault)
    }

    // MARK: - Auto-close pairs

    @Test("Typing ( auto-closes to () with the caret between")
    func autoClosesParen() {
        #expect(decide("", "(", at: 0) == .replace(range: NSRange(location: 0, length: 0), text: "()", caret: 1))
    }

    @Test("Typing [ after [ over an auto-paired ] collapses to [[]]")
    func collapsesDoubleBracket() {
        // "[]" with caret between the brackets, typing another "["
        #expect(decide("[]", "[", at: 1) == .replace(range: NSRange(location: 0, length: 2), text: "[[]]", caret: 2))
    }

    @Test("Typing > right after - becomes an arrow")
    func dashGreaterThanBecomesArrow() {
        #expect(decide("-", ">", at: 1) == .replace(range: NSRange(location: 0, length: 1), text: "→", caret: 1))
    }

    // MARK: - Code fence

    @Test("Enter at the end of an opening code fence completes the block")
    func enterCompletesCodeFence() {
        let text = "```"
        #expect(decide(text, "\n", at: end(of: text)) == .replace(range: NSRange(location: 3, length: 0), text: "\n\n```", caret: 4))
    }

    // MARK: - Code fence exit (double-Return)

    @Test("Enter on the empty trailing line of an UNCLOSED fence closes it and exits")
    func enterExitsUnclosedFence() {
        // ```swift\nlet x = 1\n  (caret at EOF, no closing fence)
        let text = "```swift\nlet x = 1\n"
        // Replace the trailing "\n" [18,19) with "\n```\n"; caret on the new line after the fence.
        #expect(decide(text, "\n", at: end(of: text))
            == .replace(range: NSRange(location: 18, length: 1), text: "\n```\n", caret: 23))
    }

    @Test("Enter on the empty trailing line of a CLOSED fence consumes the line and exits")
    func enterExitsClosedFence() {
        // ```swift\nlet x = 1\n<empty>\n```  (caret on the empty line before the closing fence)
        let text = "```swift\nlet x = 1\n\n```"
        // Caret sits at location 19 (start of the empty line). Replace [18,23) — the code
        // line's newline, the empty line, and the old closing fence — with "\n```\n".
        #expect(decide(text, "\n", at: 19)
            == .replace(range: NSRange(location: 18, length: 5), text: "\n```\n", caret: 23))
    }

    @Test("Enter on a blank line WITH code below is preserved (does not exit)")
    func enterKeepsBlankLineAboveCode() {
        // Blank line between two code lines must stay a blank line.
        let text = "```\nfunc a()\n\nfunc b()\n```"
        // Caret on the empty middle line (location 13). No fence-exit → normal newline.
        #expect(decide(text, "\n", at: 13) == .allowDefault)
    }

    @Test("Enter on the empty line AFTER a closed fence does not re-trigger an exit")
    func enterAfterClosedFenceAllowsDefault() {
        // ```\ncode\n```\n  (caret at EOF, on the empty line past the closing fence)
        let text = "```\ncode\n```\n"
        #expect(decide(text, "\n", at: end(of: text)) == .allowDefault)
    }
}
