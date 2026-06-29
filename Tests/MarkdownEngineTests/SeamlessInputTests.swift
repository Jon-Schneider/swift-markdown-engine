//
//  SeamlessInputTests.swift
//  MarkdownEngineTests
//
//  Regression net for `MarkdownSeamlessInput` — the pure caret/deletion logic
//  for seamless (always-hidden-marker) editing. These lock the
//  backspace-to-unwrap behavior shared by the macOS and iOS adapters.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Seamless backspace-to-unwrap")
struct SeamlessInputTests {

    private let seamless = MarkdownEditorConfiguration(markers: .seamless)
    private let revealOnEdit = MarkdownEditorConfiguration.default

    private func backspace(
        _ text: String,
        at caret: Int,
        length: Int = 0,
        config: MarkdownEditorConfiguration? = nil
    ) -> SeamlessEditDecision {
        MarkdownSeamlessInput.backspace(
            currentText: text,
            selection: NSRange(location: caret, length: length),
            configuration: config ?? seamless
        )
    }

    // MARK: - Mode gating

    @Test("Reveal-on-edit mode never rewrites Backspace")
    func revealOnEditUntouched() {
        // Caret right after "> " in `> hi`.
        #expect(backspace("> hi", at: 2, config: revealOnEdit) == .allowDefault)
    }

    @Test("A non-empty selection falls through to the default delete")
    func selectionUntouched() {
        #expect(backspace("> hi", at: 2, length: 1) == .allowDefault)
    }

    @Test("Disabling seamlessBackspaceUnwrap reverts Backspace to native delete")
    func backspaceUnwrapDisabled() {
        let noUnwrap = MarkdownEditorConfiguration(
            markers: MarkerStyle(visibility: .seamless, seamlessBackspaceUnwrap: false)
        )
        // Block, inline, and atomic-token cases all fall through to native delete.
        #expect(backspace("> hi", at: 2, config: noUnwrap) == .allowDefault)
        #expect(backspace("# Title", at: 2, config: noUnwrap) == .allowDefault)
        #expect(backspace("**bold**", at: 2, config: noUnwrap) == .allowDefault)
    }

    @Test("seamlessBackspaceUnwrap defaults to enabled")
    func backspaceUnwrapDefaultsOn() {
        #expect(MarkerStyle.seamless.seamlessBackspaceUnwrap == true)
        #expect(MarkdownEditorConfiguration(markers: .seamless).markers.seamlessBackspaceUnwrap == true)
    }

    // MARK: - Blockquote

    @Test("Backspace at quote content start unwraps the whole `> ` marker")
    func blockquoteUnwrap() {
        // `> hi` — caret at index 2 (start of "hi").
        #expect(backspace("> hi", at: 2) == .replace(range: NSRange(location: 0, length: 2), text: "", caret: 0))
    }

    @Test("Nested `>> ` unwraps in one edit")
    func nestedBlockquoteUnwrap() {
        // `>> hi` — content starts at index 3.
        #expect(backspace(">> hi", at: 3) == .replace(range: NSRange(location: 0, length: 3), text: "", caret: 0))
    }

    @Test("Empty quote line `> ` still unwraps")
    func emptyBlockquoteUnwrap() {
        #expect(backspace("> ", at: 2) == .replace(range: NSRange(location: 0, length: 2), text: "", caret: 0))
    }

    @Test("Caret in the middle of quoted content is a normal delete")
    func blockquoteMidContent() {
        // caret at index 3 = between h and i.
        #expect(backspace("> hi", at: 3) == .allowDefault)
    }

    @Test("Quote on the second line unwraps relative to that line")
    func blockquoteSecondLine() {
        let text = "plain\n> hi"
        // line starts at 6; "> " hides; content starts at 8.
        #expect(backspace(text, at: 8) == .replace(range: NSRange(location: 6, length: 2), text: "", caret: 6))
    }

    // MARK: - Heading

    @Test("Backspace at heading content start removes `# `")
    func headingUnwrap() {
        #expect(backspace("# Title", at: 2) == .replace(range: NSRange(location: 0, length: 2), text: "", caret: 0))
    }

    @Test("Deeper heading `### ` unwraps fully")
    func deepHeadingUnwrap() {
        #expect(backspace("### Title", at: 4) == .replace(range: NSRange(location: 0, length: 4), text: "", caret: 0))
    }

    @Test("`#` with no following space is not a heading and is left alone")
    func hashWithoutSpace() {
        // `#tag` — caret after the `#`. No ATX space → not a heading marker.
        #expect(backspace("#tag", at: 1) == .allowDefault)
    }

    @Test("A tab-indented heading is recognized (parser parity)")
    func tabIndentedHeadingUnwraps() {
        // `\t# Title` — the parser accepts arbitrary leading whitespace, so
        // seamless must too. Content starts after `\t# ` (index 3).
        let text = "\t# Title"
        #expect(backspace(text, at: 3) == .replace(range: NSRange(location: 0, length: 3), text: "", caret: 0))
    }

    @Test("A 4-space-indented heading is recognized (parser parity)")
    func deeplyIndentedHeadingUnwraps() {
        let text = "    # Title"   // 4 spaces — beyond CommonMark, but this parser accepts it
        #expect(backspace(text, at: 6) == .replace(range: NSRange(location: 0, length: 6), text: "", caret: 0))
    }

    // MARK: - Merge-up over a blank line (keep the marker)
    //
    // When the line directly above the block is BLANK, Backspace at the block's content start
    // deletes that blank line and KEEPS the marker, rather than unwrapping it — the only single
    // gesture for that in seamless mode (the caret can't sit before the hidden marker).

    @Test("Heading after a blank line: Backspace deletes the blank line, keeps `# `")
    func headingMergesUpOverBlankLine() {
        // "\n# Title" — blank first line, heading on line 2 (starts at index 1); content at 3.
        // Deleting the blank line (range 0..1) leaves "# Title" with the caret back at content
        // start (now index 2), still a heading.
        #expect(backspace("\n# Title", at: 3)
            == .replace(range: NSRange(location: 0, length: 1), text: "", caret: 2))
    }

    @Test("Heading after a blank line that sits below real content merges up, keeps `# `")
    func headingMergesUpOverBlankLineBelowContent() {
        // "intro\n\n# Title": blank middle line is range 6..7; heading starts at 7, content at 9.
        #expect(backspace("intro\n\n# Title", at: 9)
            == .replace(range: NSRange(location: 6, length: 1), text: "", caret: 8))
    }

    @Test("A whitespace-only previous line counts as blank")
    func headingMergesUpOverWhitespaceOnlyLine() {
        // "  \n# Title": the 2-space line (range 0..3 incl. \n) is blank; heading content at 5.
        #expect(backspace("  \n# Title", at: 5)
            == .replace(range: NSRange(location: 0, length: 3), text: "", caret: 2))
    }

    @Test("Quote / bullet after a blank line merge up too (not heading-specific)")
    func blockMarkersMergeUpOverBlankLine() {
        // "\n> hi": quote content at 3 → delete blank line, keep "> hi".
        #expect(backspace("\n> hi", at: 3)
            == .replace(range: NSRange(location: 0, length: 1), text: "", caret: 2))
        // "\n- item": bullet content at 3 → delete blank line, keep "- item".
        #expect(backspace("\n- item", at: 3)
            == .replace(range: NSRange(location: 0, length: 1), text: "", caret: 2))
    }

    @Test("A NON-blank previous line still unwraps (no merge-up)")
    func headingAfterContentStillUnwraps() {
        // "intro\n# Title": previous line "intro" is not blank, so Backspace unwraps the heading.
        let text = "intro\n# Title"   // heading starts at 6, content at 8.
        #expect(backspace(text, at: 8) == .replace(range: NSRange(location: 6, length: 2), text: "", caret: 6))
    }

    // MARK: - Lists

    @Test("Unordered `- ` unwraps")
    func bulletUnwrap() {
        #expect(backspace("- item", at: 2) == .replace(range: NSRange(location: 0, length: 2), text: "", caret: 0))
    }

    @Test("`* ` bullet unwraps")
    func starBulletUnwrap() {
        #expect(backspace("* item", at: 2) == .replace(range: NSRange(location: 0, length: 2), text: "", caret: 0))
    }

    @Test("Checkbox `- [ ] ` unwraps the whole marker")
    func checkboxUnwrap() {
        // `- [ ] task` — content starts at index 6.
        #expect(backspace("- [ ] task", at: 6) == .replace(range: NSRange(location: 0, length: 6), text: "", caret: 0))
    }

    // 1.3: Backspace at an ordered item's content start unwraps the `1. ` marker
    // (parity with `- `/`[ ]`). Renumbering of following items is out of scope.

    @Test("Ordered `1. ` unwraps at content start")
    func orderedListUnwrap() {
        // `1. item` — content starts at index 3; unwrap removes `1. ` → `item`.
        #expect(backspace("1. item", at: 3) == .replace(range: NSRange(location: 0, length: 3), text: "", caret: 0))
    }

    @Test("Multi-digit ordered `12. ` unwraps the whole marker")
    func multiDigitOrderedUnwrap() {
        // `12. item` — content starts at index 4.
        #expect(backspace("12. item", at: 4) == .replace(range: NSRange(location: 0, length: 4), text: "", caret: 0))
    }

    @Test("Caret in the middle of an ordered item is a normal delete")
    func orderedMidContentUntouched() {
        // Only the content-start position unwraps; elsewhere is an ordinary delete.
        #expect(backspace("1. item", at: 4) == .allowDefault)
    }

    @Test("9-digit ordered marker still unwraps (parser accepts up to 9 digits)")
    func nineDigitOrderedUnwrap() {
        // `123456789. x` — 9 digits + `. ` → content starts at index 11.
        #expect(backspace("123456789. x", at: 11) == .replace(range: NSRange(location: 0, length: 11), text: "", caret: 0))
    }

    @Test("10+-digit ordered-looking line is NOT a list — normal delete")
    func tenDigitOrderedNotAList() {
        // `1234567890. item` — 10 digits. The parser caps ordered markers at 9
        // digits, so this is a plain paragraph (visible literal text), not a list;
        // Backspace must be an ordinary delete, not an unwrap of the whole prefix.
        #expect(backspace("1234567890. item", at: 12) == .allowDefault)
    }

    @Test("Indented ordered item unwraps to a flush paragraph")
    func indentedOrderedUnwrap() {
        // 3 leading spaces + "1. x": content starts at index 6.
        let text = "   1. x"
        #expect(backspace(text, at: 6) == .replace(range: NSRange(location: 0, length: 6), text: "", caret: 0))
    }

    @Test("Ordered item on a later line unwraps relative to that line, leaving siblings byte-for-byte")
    func orderedSecondLineUnwrap() {
        // `1. a\n2. b` — content start of line 2 is index 8. Only `2. ` is removed;
        // line 1 (`1. a`) is untouched (no renumber — out of scope per 1.3).
        let text = "1. a\n2. b"
        #expect(backspace(text, at: 8) == .replace(range: NSRange(location: 5, length: 3), text: "", caret: 5))
    }

    @Test("Plain ordered: copy preserves the visible number (unwrap is Backspace-only)")
    func plainOrderedNumberStaysVisibleOnCopy() {
        // A *plain* ordered number is drawn in seamless mode, so visibleText keeps
        // it (only the Backspace path treats `1. ` as removable). This locks the
        // `includeOrdered` design: copy/caret are unaffected for plain ordered.
        let copied = MarkdownSeamlessInput.visibleText(
            of: NSRange(location: 0, length: 7), in: "1. item", configuration: seamless
        )
        #expect(copied == "1. item")
    }

    // Ordered *checkbox* items: the styler's checkbox branch hides the `1.` marker
    // (clears it, draws ☐), so `1. [ ] task` renders identically to `- [ ] task`
    // and must behave the same for *all* callers — not just Backspace.

    @Test("Ordered checkbox `1. [ ] ` unwraps the whole marker")
    func orderedCheckboxUnwrap() {
        // `1. [ ] task` — content starts at index 7 (`1. [ ] `).
        #expect(backspace("1. [ ] task", at: 7) == .replace(range: NSRange(location: 0, length: 7), text: "", caret: 0))
    }

    @Test("Checked ordered checkbox `1. [x] ` unwraps the whole marker")
    func checkedOrderedCheckboxUnwrap() {
        #expect(backspace("1. [x] task", at: 7) == .replace(range: NSRange(location: 0, length: 7), text: "", caret: 0))
    }

    @Test("Ordered checkbox copies clean like `- [ ] ` (hidden marker, not visible number)")
    func orderedCheckboxCopiesClean() {
        // The `1.` is hidden by the checkbox styler, so visibleText must strip the
        // whole `1. [ ] ` prefix — matching `- [ ] task` → `task`. Otherwise the
        // copy would carry invisible buffer text the user never sees.
        let ordered = MarkdownSeamlessInput.visibleText(
            of: NSRange(location: 0, length: 11), in: "1. [ ] task", configuration: seamless
        )
        let unordered = MarkdownSeamlessInput.visibleText(
            of: NSRange(location: 0, length: 10), in: "- [ ] task", configuration: seamless
        )
        #expect(ordered == "task")
        #expect(unordered == "task")
    }

    @Test("Indented bullet unwraps to a flush paragraph (no 4-space code trap)")
    func indentedBulletUnwrap() {
        // 4 leading spaces + "- x": content starts at index 6; unwrap removes
        // the entire prefix incl. indent so we don't leave a code block.
        let text = "    - x"
        #expect(backspace(text, at: 6) == .replace(range: NSRange(location: 0, length: 6), text: "", caret: 0))
    }

    // MARK: - Inline spans

    @Test("Bold `**bold**` unwraps to its content")
    func boldUnwrap() {
        // caret at index 2 = start of "bold".
        #expect(backspace("**bold**", at: 2) == .replace(range: NSRange(location: 0, length: 8), text: "bold", caret: 0))
    }

    @Test("Italic `*i*` unwraps")
    func italicUnwrap() {
        #expect(backspace("*i*", at: 1) == .replace(range: NSRange(location: 0, length: 3), text: "i", caret: 0))
    }

    @Test("Strikethrough `~~s~~` unwraps")
    func strikeUnwrap() {
        #expect(backspace("~~s~~", at: 2) == .replace(range: NSRange(location: 0, length: 5), text: "s", caret: 0))
    }

    @Test("Inline code `` `c` `` unwraps")
    func inlineCodeUnwrap() {
        #expect(backspace("`c`", at: 1) == .replace(range: NSRange(location: 0, length: 3), text: "c", caret: 0))
    }

    @Test("Link `[t](u)` unwraps to its text")
    func linkUnwrap() {
        // `[t](u)` — text starts at index 1.
        #expect(backspace("[t](u)", at: 1) == .replace(range: NSRange(location: 0, length: 6), text: "t", caret: 0))
    }

    // The reported seamless-feel bug: at the start of an inline span's content the
    // hidden marker is zero-width, so Backspace must delete the *previous visible
    // character*, not strip the formatting.

    @Test("Backspace at the start of mid-text bold deletes the preceding space")
    func boldStartDeletesPreviousChar() {
        // "hello **world**" — caret before "world" (index 8). The hidden `**` is
        // zero-width, so Backspace removes the space at index 5, not the bold.
        #expect(backspace("hello **world**", at: 8) == .replace(range: NSRange(location: 5, length: 1), text: "", caret: 5))
    }

    @Test("Backspace at the start of mid-text italic deletes the preceding char")
    func italicStartDeletesPreviousChar() {
        // "a *b*" — caret before "b" (index 3) deletes the space at index 1.
        #expect(backspace("a *b*", at: 3) == .replace(range: NSRange(location: 1, length: 1), text: "", caret: 1))
    }

    @Test("Backspace at the start of a span on a later line merges with the line above")
    func spanStartMergesLines() {
        // "a\n**b**" — caret before "b" (index 4) deletes the newline (index 1).
        #expect(backspace("a\n**b**", at: 4) == .replace(range: NSRange(location: 1, length: 1), text: "", caret: 1))
    }

    @Test("Nested bold-in-italic deletes the previous visible char, not the formatting")
    func nestedInlineDeletesPreviousChar() {
        // `*a**b**c*` — caret after the inner `**` (index 4) deletes the "a" before
        // the bold marker, leaving the spans intact.
        #expect(backspace("*a**b**c*", at: 4) == .replace(range: NSRange(location: 1, length: 1), text: "", caret: 1))
    }

    @Test("Caret inside bold content (not at start) is a normal delete")
    func boldMidContent() {
        #expect(backspace("**bold**", at: 4) == .allowDefault)
    }

    @Test("A span with no visible char before it unwraps (block's first content)")
    func inlineAfterBlockMarkerUnwraps() {
        // `# **b**` — caret after `# **` (index 4). Only the hidden `# ` and `**`
        // precede the span on the line, so there's nothing visible to delete →
        // fall back to unwrapping the bold.
        #expect(backspace("# **b**", at: 4) == .replace(range: NSRange(location: 2, length: 5), text: "b", caret: 2))
    }

    @Test("Adjacent spans: Backspace at the second deletes the space between them")
    func adjacentSpansDeleteSeparator() {
        // "**a** **b**" — caret before "b" (index 8) deletes the space at index 5.
        #expect(backspace("**a** **b**", at: 8) == .replace(range: NSRange(location: 5, length: 1), text: "", caret: 5))
    }

    @Test("Link: Backspace at the link text start deletes the preceding char")
    func linkStartDeletesPreviousChar() {
        // "hi [t](u)" — caret before "t" (index 4) deletes the space at index 2.
        #expect(backspace("hi [t](u)", at: 4) == .replace(range: NSRange(location: 2, length: 1), text: "", caret: 2))
    }

    @Test("Grapheme safety: an emoji before a span is deleted whole")
    func emojiBeforeSpanDeletedWhole() {
        // "😀**b**" — the emoji is a surrogate pair (indices 0…1); caret before "b"
        // (index 4) removes the whole pair, never a half-surrogate.
        #expect(backspace("😀**b**", at: 4) == .replace(range: NSRange(location: 0, length: 2), text: "", caret: 0))
    }

    @Test("CRLF: a span at the start of a CRLF line merges without a stray \\r")
    func crlfSpanMerge() {
        // "a\r\n**b**" — caret before "b" (index 5) deletes the whole "\r\n" cluster.
        #expect(backspace("a\r\n**b**", at: 5) == .replace(range: NSRange(location: 1, length: 2), text: "", caret: 1))
    }

    // MARK: - Inline spans inside opaque blocks are literal (and drawn)

    @Test("Backspace before bold inside a `$$…$$` block is a normal delete")
    func inlineInsideBlockLatexIsLiteral() {
        // "$$\n**x**\n$$" — inside block LaTeX the `**` is literal source, drawn (not
        // hidden), so Backspace must be a native single-char delete, not a skip.
        #expect(backspace("$$\n**x**\n$$", at: 5) == .allowDefault)
    }

    @Test("Backspace before bold inside a table cell is a normal delete")
    func inlineInsideTableIsLiteral() {
        // The `**x**` in a GFM table header cell is literal/drawn source.
        #expect(backspace("| **x** | y |\n| --- | --- |", at: 4) == .allowDefault)
    }

    // MARK: - Atomic rendered tokens

    @Test("Backspace at an image's trailing edge deletes the whole token")
    func imageWholeDelete() {
        // `![a](u)` is 7 chars; caret at the end (7) removes the entire token.
        let text = "![a](u)"
        #expect(backspace(text, at: 7) == .replace(range: NSRange(location: 0, length: 7), text: "", caret: 0))
    }

    @Test("Backspace in the middle of an image is a normal delete")
    func imageMidIsDefault() {
        #expect(backspace("![a](u)", at: 3) == .allowDefault)
    }

    // MARK: - Plain paragraphs

    @Test("Plain paragraph Backspace is untouched")
    func plainParagraph() {
        #expect(backspace("hello", at: 3) == .allowDefault)
    }

    @Test("Caret at absolute start of document is untouched")
    func documentStart() {
        #expect(backspace("> hi", at: 0) == .allowDefault)
    }

    // MARK: - Fenced code is opaque

    @Test("Backspace after a `# ` inside a fenced code block is a normal delete")
    func headingLineInsideCodeIsLiteral() {
        // The `# x` is code, not a heading — must NOT unwrap.
        let text = "```\n# x\n```"
        let caret = (("```\n# ") as NSString).length   // just after `# ` on line 2
        #expect(backspace(text, at: caret) == .allowDefault)
    }

    @Test("Backspace after a real `# ` outside code still unwraps")
    func headingOutsideCodeStillUnwraps() {
        // Sanity: the same `# ` not wrapped in a fence DOES unwrap.
        #expect(backspace("# x", at: 2) == .replace(range: NSRange(location: 0, length: 2), text: "", caret: 0))
    }

    @Test("An indented ``` is not a fence — a heading after it still unwraps")
    func indentedFenceIsNotCodeHeadingUnwraps() {
        // `BlockParser.isFence` requires column 0, so `  ``` ` is NOT a code
        // fence; `# heading` between two indented ``` lines is a real heading and
        // must unwrap (seamless detection must not treat it as inside code).
        let text = "  ```\n# heading\n  ```"
        let lineStart = (("  ```\n") as NSString).length     // start of `# heading`
        let caret = (("  ```\n# ") as NSString).length       // just after `# `
        #expect(backspace(text, at: caret)
            == .replace(range: NSRange(location: lineStart, length: 2), text: "", caret: lineStart))
    }

    // MARK: - Block LaTeX / tables are opaque too

    @Test("Backspace after a `# ` inside a `$$…$$` block is a normal delete")
    func headingLineInsideBlockLatexIsLiteral() {
        // The `# x` is LaTeX source, not a heading — must NOT unwrap.
        let text = "$$\n# x\n$$"
        let caret = (("$$\n# ") as NSString).length   // just after `# ` on line 2
        #expect(backspace(text, at: caret) == .allowDefault)
    }

    // MARK: - Tab-indented blockquote (parser parity)

    @Test("Backspace at a tab-indented quote's content start unwraps the whole marker")
    func tabIndentedBlockquoteUnwraps() {
        // `\t> hi` — `BlockParser.isBlockquote` accepts the leading tab, so the
        // hidden marker is `\t> ` and content starts at index 3.
        #expect(backspace("\t> hi", at: 3) == .replace(range: NSRange(location: 0, length: 3), text: "", caret: 0))
    }
}

/// In seamless mode the marker characters are rendered/hidden by the styler, so
/// "autoformatting" `> `, `# `, `- ` at line start is *inherent*: the keystrokes
/// just need to reach the buffer (`.allowDefault`) and the styler renders the
/// element with the marker hidden. These lock that pass-through so a future
/// input-handling change can't silently break block autoformat.
@Suite("Seamless block autoformat (pass-through)")
struct SeamlessAutoformatTests {

    private let seamless = MarkdownEditorConfiguration(markers: .seamless)

    private func decide(_ text: String, _ replacement: String, at location: Int) -> ListInsertionDecision {
        MarkdownLists.computeListInsertion(
            currentText: text, affectedCharRange: NSRange(location: location, length: 0),
            replacementString: replacement, configuration: seamless
        )
    }

    @Test("Typing `>` at line start reaches the buffer")
    func quoteMarkerPassesThrough() {
        #expect(decide("", ">", at: 0) == .allowDefault)
    }

    @Test("Typing the space after `>` reaches the buffer (forms `> `)")
    func quoteSpacePassesThrough() {
        #expect(decide(">", " ", at: 1) == .allowDefault)
    }

    @Test("Typing `#` at line start reaches the buffer")
    func headingMarkerPassesThrough() {
        #expect(decide("", "#", at: 0) == .allowDefault)
    }

    @Test("Typing the space after `#` reaches the buffer (forms `# `)")
    func headingSpacePassesThrough() {
        #expect(decide("#", " ", at: 1) == .allowDefault)
    }
}

@Suite("Seamless copy (visible text)")
struct SeamlessCopyTests {

    private let seamless = MarkdownEditorConfiguration(markers: .seamless)
    private let revealOnEdit = MarkdownEditorConfiguration.default

    private func visible(_ text: String, _ range: NSRange, config: MarkdownEditorConfiguration? = nil) -> String {
        MarkdownSeamlessInput.visibleText(of: range, in: text, configuration: config ?? seamless)
    }

    private func whole(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }

    @Test("Reveal-on-edit copies the raw substring unchanged")
    func revealOnEditRaw() {
        #expect(visible("**b**", whole("**b**"), config: revealOnEdit) == "**b**")
    }

    @Test("Blockquote copies without the `> `")
    func quoteVisible() {
        #expect(visible("> hello", whole("> hello")) == "hello")
    }

    @Test("Heading copies without the `# `")
    func headingVisible() {
        #expect(visible("# Title", whole("# Title")) == "Title")
    }

    @Test("Bold copies its inner text")
    func boldVisible() {
        #expect(visible("a **b** c", whole("a **b** c")) == "a b c")
    }

    @Test("Link copies just its visible text")
    func linkVisible() {
        #expect(visible("see [docs](http://x) ok", whole("see [docs](http://x) ok")) == "see docs ok")
    }

    @Test("Ordered list number is preserved (it's visible)")
    func orderedPreserved() {
        #expect(visible("1. item", whole("1. item")) == "1. item")
    }

    @Test("Partial selection strips only the markers it overlaps")
    func partialSelection() {
        // `a **bold** b` — select `**bold**` (indices 2…10).
        let text = "a **bold** b"
        #expect(visible(text, NSRange(location: 2, length: 8)) == "bold")
    }

    @Test("A multi-line blockquote selection drops each line's `> `")
    func multiLineQuote() {
        let text = "> a\n> b"
        #expect(visible(text, whole(text)) == "a\nb")
    }

    @Test("Multibyte content survives marker stripping intact")
    func multibytePreserved() {
        // `**😀**` → the emoji (a surrogate pair) must not be split by the cut.
        #expect(visible("**😀**", whole("**😀**")) == "😀")
    }

    @Test("A fenced code block copies as just its code (fences stripped)")
    func codeFenceStripped() {
        let text = "```swift\nlet x = 1\n```"
        #expect(visible(text, whole(text)) == "let x = 1\n")
    }

    @Test("A `# `/`- ` line inside a code block is copied verbatim (not stripped)")
    func markerLikeCodeLinePreserved() {
        // The `# heading` and `- item` here are code content; only the fences go.
        let text = "```\n# heading\n- item\n```"
        #expect(visible(text, whole(text)) == "# heading\n- item\n")
    }

    // MARK: - 1.5: the copy contract is intentionally LOSSY
    //
    // Seamless copy yields *visible* text — markers are dropped, so the result is
    // deliberately NOT round-trippable Markdown. These cases pin the lossy mapping
    // explicitly (not a round-trip). Anyone needing fidelity copies from
    // `.revealAll`, which yields the full source (see `revealAllCopiesFullSource`).

    @Test("Link copy drops the URL — only the visible text survives")
    func linkDropsURL() {
        // The acceptance example: `[x](http://y)` → `x` (the `](http://y)` is gone).
        #expect(visible("[x](http://y)", whole("[x](http://y)")) == "x")
    }

    @Test("An image copies as empty — its whole `![alt](url)` range is a hidden marker")
    func imageCopiesEmpty() {
        // The rendered image is atomic: the entire token is a marker, so the
        // visible text it contributes is nothing.
        #expect(visible("![alt](http://y/z.png)", whole("![alt](http://y/z.png)")) == "")
    }

    @Test("A checkbox item drops its list/checkbox structure — `- [ ] task` → `task`")
    func checkboxDropsStructure() {
        // The `- [ ] ` marker (and its rendered ☐ glyph) is not buffer-visible text.
        #expect(visible("- [ ] task", whole("- [ ] task")) == "task")
    }

    @Test("Inline code drops its backticks — `` `code` `` → `code`")
    func inlineCodeDropsTicks() {
        #expect(visible("`code`", whole("`code`")) == "code")
    }

    @Test("Wiki-link drops its `[[ ]]` brackets — `[[Page]]` → `Page`")
    func wikiLinkDropsBrackets() {
        #expect(visible("[[Page]]", whole("[[Page]]")) == "Page")
    }

    @Test("Nested spans drop every marker pair — `**_x_**` → `x`")
    func nestedSpansDropAllMarkers() {
        #expect(visible("**_x_**", whole("**_x_**")) == "x")
    }

    @Test("Copy is not round-trippable: a link's visible text alone never reconstructs the source")
    func lossyNotRoundTrippable() {
        // Explicitly assert lossiness rather than a round-trip: the copied text is
        // strictly shorter than the source and carries no URL, so re-parsing it
        // cannot recover the link. This locks the 1.5 decision (no source-copy flag).
        let source = "[x](http://y)"
        let copied = visible(source, whole(source))
        #expect(copied == "x")
        #expect(copied != source)
        #expect(!copied.contains("http://y"))
    }

    @Test("`visibleText` is a no-op outside seamless — markers survive for `.revealAll`")
    func revealAllVisibleTextIsRawSubstring() {
        // NOTE ON SCOPE: this pins `visibleText`'s contract (it strips ONLY in
        // seamless; for any other visibility it returns the raw substring). That is
        // defense-in-depth, NOT a test of the production `.revealAll` copy path:
        // the copy override (`NativeTextView+SeamlessCopy`/`MarkdownUITextView`)
        // never calls `visibleText` for `.revealAll` — it falls back to
        // `super.copy()`, which copies the raw source. That responder fallback is a
        // view-level path, verified by reading the override, not by this unit test.
        let revealAll = MarkdownEditorConfiguration(markers: MarkerStyle(visibility: .revealAll))
        let source = "> # [x](http://y) ![a](u) - [ ] t"
        #expect(visible(source, whole(source), config: revealAll) == source)
    }
}

@Suite("Seamless rendered-block visibility routing")
struct SeamlessActiveTokenTests {

    private func active(_ text: String, caret: Int, _ visibility: MarkerVisibility) -> Set<Int> {
        let ns = text as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        return MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caret, length: 0),
            tokens: tokens, in: ns, markerVisibility: visibility
        )
    }

    @Test("Seamless keeps INLINE rendered runs hidden, even with the caret on them")
    func seamlessHidesInlineSource() {
        // Inline LaTeX `$x$` and inline emphasis never reveal in seamless — only block-level
        // rendered elements do (see the reveal-hole tests below).
        #expect(active("$x$", caret: 1, .seamless).isEmpty)
        #expect(active("**bold**", caret: 3, .seamless).isEmpty)
    }

    @Test("Reveal-all marks every token active (source shown everywhere)")
    func revealAllShowsSource() {
        let text = "$x$"
        let count = MarkdownTokenizer.parseTokensViaAST(in: text).count
        #expect(active(text, caret: 0, .revealAll).count == count)
    }

    // MARK: - Seamless reveal hole (plan 1.2): block LaTeX reveals its source on caret entry

    @Test("Seamless reveals the block LaTeX the caret is inside (so it can be edited)")
    func seamlessRevealsBlockLatexOnEntry() {
        // Single-line `$$x$$`: caret inside → that block becomes active (raw source revealed).
        #expect(active("$$x$$", caret: 2, .seamless) == [0])
    }

    @Test("Seamless reveals a multi-line block LaTeX by the block containing the caret")
    func seamlessRevealsMultiLineBlockLatex() {
        let text = "$$\n\\frac{a}{b}\n$$"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        guard let blockIdx = tokens.firstIndex(where: { $0.kind == .blockLatex }) else {
            Issue.record("expected a block-LaTeX token"); return
        }
        let caretInside = tokens[blockIdx].range.location + 4   // on the content line
        #expect(active(text, caret: caretInside, .seamless) == [blockIdx])
    }

    @Test("Seamless reveals nothing when the caret is outside any block LaTeX")
    func seamlessNoRevealOutsideBlock() {
        // `$$x$$` then a blank line then prose; caret in the prose → no block revealed.
        let text = "$$x$$\n\nplain text"
        #expect(active(text, caret: text.utf16.count - 1, .seamless).isEmpty)
    }

    @Test("Seamless reveals from the block's start edge")
    func seamlessRevealsAtBlockStart() {
        // Caret at index 0 (the block's leading `$`) counts as inside.
        #expect(active("$$x$$", caret: 0, .seamless) == [0])
    }

    @Test("Seamless does NOT reveal once the caret sits on the line after the block")
    func seamlessNoRevealOnNextLine() {
        // The block range includes its trailing newline; a caret at the start of the next line
        // (== block end, preceded by `\n`) must re-hide the block, not keep it revealed.
        let text = "$$x$$\nplain"          // block [0,6) incl. the `\n`; next line starts at 6
        #expect(active(text, caret: 6, .seamless).isEmpty)
    }

    // MARK: - Seamless reveal hole (plan 1.1): tables reveal their source on caret entry

    private static let tableDoc = "intro\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nend"

    @Test("Seamless reveals a table the caret is inside (so its source can be edited)")
    func seamlessRevealsTableOnEntry() {
        let text = Self.tableDoc
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        guard let tableIdx = tokens.firstIndex(where: { $0.kind == .table }) else {
            Issue.record("expected a table token"); return
        }
        let caretInside = tokens[tableIdx].range.location + 3
        #expect(active(text, caret: caretInside, .seamless).contains(tableIdx))
    }

    @Test("Seamless keeps a table hidden when the caret is outside it")
    func seamlessNoTableRevealOutside() {
        // Caret in the leading "intro" prose → no table revealed.
        #expect(active(Self.tableDoc, caret: 2, .seamless).isEmpty)
    }

    @Test("Seamless propagates active state to a table cell's link/image token (load-bearing)")
    func seamlessRevealsTableCellTokens() {
        // A link in a cell is the case where propagation MATTERS: the link styler honors
        // `activeTokenIndices` and does NOT skip table interiors, so without propagation the link
        // would render over the revealed raw `[a](b)` source. (Inline `$…$`/`**bold**` reveal via
        // the table styler regardless, so they don't exercise propagation.)
        let text = "intro\n\n| [a](b) | c |\n| --- | --- |\n| 1 | 2 |\n\nend"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        guard let tableIdx = tokens.firstIndex(where: { $0.kind == .table }),
              let linkIdx = tokens.firstIndex(where: { $0.kind == .link }) else {
            Issue.record("expected table + link tokens"); return
        }
        let caretInside = tokens[tableIdx].range.location + 5
        let activeSet = active(text, caret: caretInside, .seamless)
        #expect(activeSet.contains(tableIdx))
        #expect(activeSet.contains(linkIdx), "a link inside a revealed table must be active via container propagation")
    }

    @Test("Seamless reveals a block a ranged selection overlaps")
    func seamlessRevealsBlockUnderRangedSelection() {
        let text = "$$x$$\nplain"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        guard let blockIdx = tokens.firstIndex(where: { $0.kind == .blockLatex }) else {
            Issue.record("expected a block-LaTeX token"); return
        }
        let sel = NSRange(location: 1, length: 3)   // spans inside `$$x$$`
        let result = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: sel, tokens: tokens, in: text as NSString, markerVisibility: .seamless
        )
        #expect(result == [blockIdx])
    }
}

@Suite("Seamless caret normalization")
struct SeamlessCaretTests {

    private let seamless = MarkdownEditorConfiguration(markers: .seamless)
    private let revealOnEdit = MarkdownEditorConfiguration.default

    private func normalize(_ text: String, proposed: Int, previous: Int,
                           config: MarkdownEditorConfiguration? = nil) -> Int {
        MarkdownSeamlessInput.normalizedCaret(
            text: text, proposed: proposed, previous: previous, configuration: config ?? seamless
        )
    }

    // MARK: - Mode gating

    @Test("Reveal-on-edit never moves the caret")
    func revealOnEditUntouched() {
        #expect(normalize("> hi", proposed: 0, previous: 4, config: revealOnEdit) == 0)
    }

    // MARK: - Block dead-zone forward pull

    @Test("A caret landing before `> ` is pulled to content start")
    func tapAtLineStartPulledForward() {
        // Tap / Home: previous far away, proposed at the hidden marker's start.
        #expect(normalize("> hi", proposed: 0, previous: 4) == 2)
    }

    @Test("A caret strictly inside the marker is pulled to content start")
    func insideMarkerPulledForward() {
        #expect(normalize("> hi", proposed: 1, previous: 9) == 2)
    }

    @Test("Home onto a heading line lands at content start, not line start")
    func homeOntoHeading() {
        // `# Title` — Home from caret 5 → proposed 0 (line start), large step → content start 2.
        #expect(normalize("# Title", proposed: 0, previous: 5) == 2)
    }

    @Test("A caret already in the content is left alone")
    func contentUntouched() {
        #expect(normalize("> hi", proposed: 3, previous: 2) == 3)
    }

    @Test("A plain paragraph caret is never moved")
    func plainParagraph() {
        #expect(normalize("hello", proposed: 0, previous: 5) == 0)
    }

    @Test("Ordered list number is visible, so its line has no dead zone")
    func orderedListNoDeadZone() {
        #expect(normalize("1. item", proposed: 0, previous: 5) == 0)
    }

    // MARK: - Leftward escape

    @Test("A single ← step out of content escapes to the previous line")
    func leftwardEscapeToPreviousLine() {
        // `x\n> hi`: line starts at 2, content at 4. ← from 4 → proposed 3.
        // Escapes to end of the previous line (index 1).
        #expect(normalize("x\n> hi", proposed: 3, previous: 4) == 1)
    }

    @Test("On the first line there is nowhere to escape, so it holds at content start")
    func firstLineNoEscape() {
        // ← from content start 2 → proposed 1, previous 2 → stays at content start 2.
        #expect(normalize("> hi", proposed: 1, previous: 2) == 2)
    }

    // MARK: - Atomic inline runs (link tail / image)

    @Test("Moving right into a link's `](url)` tail snaps past the whole tail")
    func linkTailSnapRight() {
        // `[t](url)` — text "t" at index 1, tail `](url)` spans 2..8.
        let text = "[t](url)"
        // → from inside the tail (proposed 4, previous 2) lands at the tail end (8).
        #expect(normalize(text, proposed: 4, previous: 2) == 8)
    }

    @Test("Moving left into a link tail snaps to the tail start")
    func linkTailSnapLeft() {
        let text = "[t](url)"
        // ← from the end (proposed 6, previous 8) lands at the tail start (2).
        #expect(normalize(text, proposed: 6, previous: 8) == 2)
    }

    @Test("A caret inside a rendered image run snaps out of it")
    func imageRunSnap() {
        // `![a](u)` spans 0..7; → from inside (proposed 3, previous 0) → 7.
        #expect(normalize("![a](u)", proposed: 3, previous: 0) == 7)
    }

    @Test("A link cell inside a REVEALED table is editable — its tail is not snapped")
    func linkTailInsideRevealedTableNotSnapped() {
        // Plan 1.1 makes tables revealable in seamless mode, so a table whose cell holds
        // `[t](u)` shows that raw source for editing. The caret must be able to rest inside
        // the `](u)` tail (it's drawn source here, not a hidden run) — `atomicInlineCaret`
        // must NOT snap it out, unlike the same tail in ordinary prose.
        let text = "| [t](u) | x |\n| --- | --- |\n| a | b |"
        let tail = (("| [t](") as NSString).length   // inside the link's `](u)` tail
        #expect(normalize(text, proposed: tail, previous: tail - 2) == tail)
    }

    @Test("An image cell inside a REVEALED table is editable — its run is not snapped")
    func imageRunInsideRevealedTableNotSnapped() {
        // Same contract as the link-cell case, for the other atomic run kind: an
        // `![a](u)` image cell in a revealed table is drawn source, so the caret must
        // rest inside it rather than snapping to the run's far edge.
        let text = "| ![a](u) | x |\n| --- | --- |\n| a | b |"
        let inside = (("| ![a]") as NSString).length   // inside the image run
        #expect(normalize(text, proposed: inside, previous: inside - 2) == inside)
    }

    @Test("Short `**` markers are left to native motion (not snapped)")
    func shortInlineMarkersNotSnapped() {
        // `a**b**` — caret 2 (between the asterisks) is left where the system put it.
        #expect(normalize("a**b**", proposed: 2, previous: 1) == 2)
    }

    @Test("A line with no link/image is never parsed for inline snapping")
    func plainLineNoInlineSnap() {
        #expect(normalize("just some prose here", proposed: 5, previous: 4) == 5)
    }

    // MARK: - Grapheme safety

    @Test("Multibyte content is irrelevant to the line-based marker math")
    func multibyteContentUntouched() {
        // `> 😀` — the emoji is 2 UTF-16 units at index 2..4; content caret unaffected.
        let text = "> 😀"
        // caret in the emoji content (index 2 = content start) is left alone.
        #expect(normalize(text, proposed: 2, previous: 2) == 2)
        // a tap before the marker still pulls forward to content start (2).
        #expect(normalize(text, proposed: 0, previous: 4) == 2)
    }
}

@Suite("Seamless hidden-marker collection")
struct SeamlessHiddenRangesTests {

    private let seamless = MarkdownEditorConfiguration(markers: .seamless)
    private let revealOnEdit = MarkdownEditorConfiguration.default

    private func hidden(_ text: String) -> [NSRange] {
        MarkdownSeamlessInput.hiddenMarkerRanges(in: text, configuration: seamless)
    }

    @Test("Reveal-on-edit mode reports no hidden markers")
    func noHiddenWhenRevealOnEdit() {
        #expect(MarkdownSeamlessInput.hiddenMarkerRanges(in: "**b** > q", configuration: revealOnEdit).isEmpty)
    }

    @Test("Block leading `> ` is a hidden marker range")
    func blockMarkerCollected() {
        #expect(hidden("> hi").contains(NSRange(location: 0, length: 2)))
    }

    @Test("Inline `**` pair yields two hidden marker ranges")
    func inlineMarkersCollected() {
        let ranges = hidden("a**b**c")
        #expect(ranges.contains(NSRange(location: 1, length: 2)))   // opening **
        #expect(ranges.contains(NSRange(location: 4, length: 2)))   // closing **
    }

    @Test("Ordered list number is NOT a hidden marker")
    func orderedNotHidden() {
        #expect(hidden("1. item").isEmpty)
    }
}

/// Phase-C: full-line hidden elements (thematic-break rules and code-fence
/// delimiter lines). In seamless mode the caret steps over them (never rests on
/// a line the user can't edit), and Backspace deletes them atomically — a rule
/// in one edit, a code block by unwrapping to a plain paragraph.
@Suite("Seamless full-line elements")
struct SeamlessFullLineElementTests {

    private let seamless = MarkdownEditorConfiguration(markers: .seamless)

    private func normalize(_ text: String, proposed: Int, previous: Int) -> Int {
        MarkdownSeamlessInput.normalizedCaret(
            text: text, proposed: proposed, previous: previous, configuration: seamless
        )
    }

    private func backspace(_ text: String, at caret: Int) -> SeamlessEditDecision {
        MarkdownSeamlessInput.backspace(
            currentText: text, selection: NSRange(location: caret, length: 0), configuration: seamless
        )
    }

    // MARK: - Caret skip: thematic break

    @Test("Arrowing down onto a `---` rule skips to the line below")
    func thematicSkipForward() {
        // "a\n---\nb": rule line is indices 2…5; "b" starts at 6.
        #expect(normalize("a\n---\nb", proposed: 3, previous: 0) == 6)
    }

    @Test("Arrowing up onto a `---` rule skips to the end of the line above")
    func thematicSkipBackward() {
        // Travelling up from "b" (6) → end of "a" (index 1).
        #expect(normalize("a\n---\nb", proposed: 3, previous: 6) == 1)
    }

    // MARK: - Caret skip: code fence

    @Test("Arrowing down onto an open fence lands in the first body line")
    func openFenceSkipsIntoBody() {
        // "a\n```\nx\n```\nb": open fence 2…5, body "x" at 6.
        #expect(normalize("a\n```\nx\n```\nb", proposed: 3, previous: 0) == 6)
    }

    @Test("Arrowing up onto a close fence lands at the end of the last body line")
    func closeFenceSkipsToBody() {
        // Same doc: close fence is line 8…11; travelling up from "b" (12) lands at
        // the end of body "x" (index 7).
        #expect(normalize("a\n```\nx\n```\nb", proposed: 9, previous: 12) == 7)
    }

    @Test("The editable code body is never skipped")
    func bodyCaretUntouched() {
        // Caret at the start of body "x" (6) stays put.
        #expect(normalize("a\n```\nx\n```\nb", proposed: 6, previous: 3) == 6)
    }

    @Test("A `---` line inside a code body is literal — caret is not skipped")
    func dashesInsideCodeNotSkipped() {
        // "```\n---\n```": the middle line is code, not a thematic break.
        #expect(normalize("```\n---\n```", proposed: 5, previous: 0) == 5)
    }

    // MARK: - Atomic delete: thematic break

    @Test("Backspace at the start of the line after a rule deletes the whole rule")
    func backspaceDeletesRule() {
        // "a\n---\nb", caret at "b" (6) → remove "---\n" (indices 2…5).
        #expect(backspace("a\n---\nb", at: 6)
            == .replace(range: NSRange(location: 2, length: 4), text: "", caret: 2))
    }

    @Test("`***` and `___` rules are recognized too")
    func backspaceDeletesStarAndUnderscoreRules() {
        #expect(backspace("a\n***\nb", at: 6)
            == .replace(range: NSRange(location: 2, length: 4), text: "", caret: 2))
        #expect(backspace("a\n___\nb", at: 6)
            == .replace(range: NSRange(location: 2, length: 4), text: "", caret: 2))
    }

    // MARK: - Atomic delete: code fence (unwrap)

    @Test("Backspace at the start of a code body unwraps the whole block")
    func backspaceUnwrapsCodeBlock() {
        // "```\nx\n```" → replace the whole block (0…8) with the body "x\n".
        #expect(backspace("```\nx\n```", at: 4)
            == .replace(range: NSRange(location: 0, length: 9), text: "x\n", caret: 0))
    }

    @Test("Unwrapping an unterminated one-line fence keeps the body")
    func backspaceUnwrapsUnterminatedSingleLine() {
        // "```\nx" — no closing fence; the block runs to EOF, so the body is "x"
        // and must NOT be dropped.
        #expect(backspace("```\nx", at: 4)
            == .replace(range: NSRange(location: 0, length: 5), text: "x", caret: 0))
    }

    @Test("Unwrapping an unterminated multi-line fence keeps every body line")
    func backspaceUnwrapsUnterminatedMultiLine() {
        // "```\na\nb" — last line "b" is body, not a close fence.
        #expect(backspace("```\na\nb", at: 4)
            == .replace(range: NSRange(location: 0, length: 7), text: "a\nb", caret: 0))
    }

    @Test("Unwrapping an empty terminated block yields an empty paragraph")
    func backspaceUnwrapsEmptyBlock() {
        // "```\n```" — open then close, no body → unwrap to "".
        #expect(backspace("```\n```", at: 4)
            == .replace(range: NSRange(location: 0, length: 7), text: "", caret: 0))
    }

    @Test("Backspace in the middle of a code body is a normal delete")
    func backspaceMidBodyNative() {
        #expect(backspace("```\nx\n```", at: 5) == .allowDefault)
    }

    @Test("Backspace at the start of the line after a code block is a normal delete")
    func backspaceAfterCodeBlockNative() {
        // Not an unwrap trigger — only the body's first line unwraps.
        #expect(backspace("```\nx\n```\nb", at: 10) == .allowDefault)
    }
}
