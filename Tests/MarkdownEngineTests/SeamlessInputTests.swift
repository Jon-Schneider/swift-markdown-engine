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

    @Test("Ordered `1. ` keeps its visible number — normal delete")
    func orderedListUntouched() {
        // `1. item` — caret at content start index 3. Number stays visible in
        // seamless mode, so Backspace is the ordinary one.
        #expect(backspace("1. item", at: 3) == .allowDefault)
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

    @Test("Seamless never marks a rendered block active (source stays hidden)")
    func seamlessHidesSource() {
        // Caret inside the inline LaTeX `$x$`.
        #expect(active("$x$", caret: 1, .seamless).isEmpty)
    }

    @Test("Reveal-all marks every token active (source shown everywhere)")
    func revealAllShowsSource() {
        let text = "$x$"
        let count = MarkdownTokenizer.parseTokensViaAST(in: text).count
        #expect(active(text, caret: 0, .revealAll).count == count)
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
