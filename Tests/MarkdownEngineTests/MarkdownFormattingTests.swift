//
//  MarkdownFormattingTests.swift
//  MarkdownEngineTests
//
//  Cross-platform regression net for `MarkdownFormatting` — the editor formatting
//  commands (bold / italic / heading / list) shared by the macOS context menu and
//  the iOS edit menu. Pins the behavior the macOS `ContextMenu` handlers produced.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Markdown formatting commands")
struct MarkdownFormattingTests {

    private func edit(_ command: MarkdownFormattingCommand, _ text: String, _ selection: NSRange) -> FormattingEdit {
        MarkdownFormatting.edit(for: command, text: text, selection: selection)
    }

    // MARK: - Bold / italic wrap

    @Test("Bold wraps a selection in ** and selects the inner text")
    func boldWrapsSelection() {
        #expect(edit(.bold, "foo", NSRange(location: 0, length: 3))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "**foo**", selection: NSRange(location: 2, length: 3)))
    }

    @Test("Italic wraps a selection in * and selects the inner text")
    func italicWrapsSelection() {
        #expect(edit(.italic, "foo", NSRange(location: 0, length: 3))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "*foo*", selection: NSRange(location: 1, length: 3)))
    }

    @Test("Bold on an empty selection inserts **** with the caret between")
    func boldEmptyInsertsMarkers() {
        #expect(edit(.bold, "", NSRange(location: 0, length: 0))
            == FormattingEdit(range: NSRange(location: 0, length: 0), text: "****", selection: NSRange(location: 2, length: 0)))
    }

    @Test("Bold keeps leading/trailing whitespace outside the markers")
    func boldPreservesEdgeWhitespace() {
        #expect(edit(.bold, " foo ", NSRange(location: 0, length: 5))
            == FormattingEdit(range: NSRange(location: 0, length: 5), text: " **foo** ", selection: NSRange(location: 3, length: 3)))
    }

    // MARK: - Bold / italic toggle off

    @Test("Bold on already-bold text strips the markers")
    func boldTogglesOff() {
        #expect(edit(.bold, "**foo**", NSRange(location: 2, length: 3))
            == FormattingEdit(range: NSRange(location: 0, length: 7), text: "foo", selection: NSRange(location: 0, length: 3)))
    }

    @Test("Italic on bold-italic text leaves the bold markers")
    func italicOffOnBoldItalicKeepsBold() {
        #expect(edit(.italic, "***foo***", NSRange(location: 4, length: 0))
            == FormattingEdit(range: NSRange(location: 0, length: 9), text: "**foo**", selection: NSRange(location: 2, length: 3)))
    }

    // MARK: - Heading

    @Test("Heading adds the marker to a plain line")
    func headingAddsMarker() {
        #expect(edit(.heading(1), "foo", NSRange(location: 0, length: 0))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "# foo", selection: NSRange(location: 2, length: 3)))
    }

    @Test("Heading replaces an existing heading level")
    func headingReplacesLevel() {
        #expect(edit(.heading(1), "## foo", NSRange(location: 0, length: 0))
            == FormattingEdit(range: NSRange(location: 0, length: 6), text: "# foo", selection: NSRange(location: 2, length: 3)))
    }

    @Test("Heading preserves the trailing newline of a non-final line")
    func headingPreservesNewline() {
        let result = edit(.heading(2), "foo\nbar", NSRange(location: 0, length: 0))
        #expect(result.range == NSRange(location: 0, length: 4))   // "foo\n"
        #expect(result.text == "## foo\n")
    }

    // MARK: - Lists

    @Test("Bullet list adds the marker")
    func bulletAddsMarker() {
        #expect(edit(.bulletList, "foo", NSRange(location: 0, length: 0))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "- foo", selection: NSRange(location: 2, length: 3)))
    }

    @Test("Numbered list adds the marker")
    func numberedAddsMarker() {
        #expect(edit(.numberedList, "foo", NSRange(location: 0, length: 0))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "1. foo", selection: NSRange(location: 3, length: 3)))
    }

    // MARK: - Active state (menu on/off)

    @Test("isActive reflects the current formatting")
    func isActiveReflectsState() {
        #expect(MarkdownFormatting.isActive(.bold, text: "**foo**", selection: NSRange(location: 2, length: 3)))
        #expect(!MarkdownFormatting.isActive(.bold, text: "foo", selection: NSRange(location: 0, length: 3)))
        #expect(MarkdownFormatting.isActive(.heading(1), text: "# foo", selection: NSRange(location: 0, length: 0)))
        #expect(MarkdownFormatting.isActive(.bulletList, text: "- foo", selection: NSRange(location: 0, length: 0)))
    }
}
