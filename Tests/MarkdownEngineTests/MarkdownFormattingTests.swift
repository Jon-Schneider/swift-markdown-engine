//
//  MarkdownFormattingTests.swift
//  MarkdownEngineTests
//
//  Cross-platform regression net for `MarkdownFormatting` — the editor formatting
//  commands (bold / italic / strikethrough / inline-code / heading / list /
//  clear-formatting) shared by the macOS context menu and the iOS edit menu. Pins the
//  emphasis/heading/list behavior the macOS `ContextMenu` handlers produced, plus the
//  newer shared-core commands (strikethrough, inline-code, clear-formatting) that have
//  no bespoke macOS predecessor.
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

    @Test("Bold on an all-whitespace selection doesn't duplicate the whitespace")
    func boldAllWhitespaceSelectionDoesNotDuplicate() {
        // The leading/trailing whitespace runs must not both claim the same characters — a clamp
        // keeps the result "   ****" (whitespace once, then empty markers), not "   ****   ".
        #expect(edit(.bold, "   ", NSRange(location: 0, length: 3))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "   ****", selection: NSRange(location: 5, length: 0)))
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

    // MARK: - Strikethrough / inline code (symmetric wraps)

    @Test("Strikethrough wraps a selection in ~~ and selects the inner text")
    func strikethroughWrapsSelection() {
        #expect(edit(.strikethrough, "foo", NSRange(location: 0, length: 3))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "~~foo~~", selection: NSRange(location: 2, length: 3)))
    }

    @Test("Inline code wraps a selection in backticks and selects the inner text")
    func inlineCodeWrapsSelection() {
        #expect(edit(.inlineCode, "foo", NSRange(location: 0, length: 3))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "`foo`", selection: NSRange(location: 1, length: 3)))
    }

    @Test("Strikethrough on an empty selection inserts ~~~~ with the caret between")
    func strikethroughEmptyInsertsMarkers() {
        #expect(edit(.strikethrough, "", NSRange(location: 0, length: 0))
            == FormattingEdit(range: NSRange(location: 0, length: 0), text: "~~~~", selection: NSRange(location: 2, length: 0)))
    }

    @Test("Strikethrough on already-struck text strips the markers")
    func strikethroughTogglesOff() {
        #expect(edit(.strikethrough, "~~foo~~", NSRange(location: 2, length: 3))
            == FormattingEdit(range: NSRange(location: 0, length: 7), text: "foo", selection: NSRange(location: 0, length: 3)))
    }

    @Test("Inline code on a selection containing a backtick uses a longer fence")
    func inlineCodeEscapesInnerBacktick() {
        #expect(edit(.inlineCode, "a`b", NSRange(location: 0, length: 3))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "``a`b``", selection: NSRange(location: 2, length: 3)))
    }

    @Test("Inline code pads with a space when the core abuts a backtick")
    func inlineCodePadsBacktickEdge() {
        #expect(edit(.inlineCode, "`x", NSRange(location: 0, length: 2))
            == FormattingEdit(range: NSRange(location: 0, length: 2), text: "`` `x ``", selection: NSRange(location: 3, length: 2)))
    }

    @Test("The inline-code fence round-trips to a single code span over the original core")
    func inlineCodeFenceRoundTrips() {
        let produced = edit(.inlineCode, "a`b", NSRange(location: 0, length: 3)).text   // ``a`b``
        let codeSpans = MarkdownTokenizer.parseTokensViaAST(in: produced).filter { $0.kind == .inlineCode }
        #expect(codeSpans.count == 1)
        if let span = codeSpans.first {
            #expect((produced as NSString).substring(with: span.contentRange) == "a`b")
        }
    }

    @Test("Inline code on already-coded text strips the backticks")
    func inlineCodeTogglesOff() {
        #expect(edit(.inlineCode, "`foo`", NSRange(location: 1, length: 3))
            == FormattingEdit(range: NSRange(location: 0, length: 5), text: "foo", selection: NSRange(location: 0, length: 3)))
    }

    @Test("Inline code keeps leading/trailing whitespace outside the backticks")
    func inlineCodePreservesEdgeWhitespace() {
        #expect(edit(.inlineCode, " foo ", NSRange(location: 0, length: 5))
            == FormattingEdit(range: NSRange(location: 0, length: 5), text: " `foo` ", selection: NSRange(location: 2, length: 3)))
    }

    // MARK: - Clear formatting

    @Test("Clear formatting strips the emphasis markers around the caret")
    func clearFormattingStripsBold() {
        let result = edit(.clearFormatting, "a **b** c", NSRange(location: 4, length: 0))
        #expect(result.range == NSRange(location: 2, length: 5))
        #expect(result.text == "b")
        #expect(result.selection == NSRange(location: 2, length: 1))
    }

    @Test("Clear formatting strips every emphasis span a selection straddles")
    func clearFormattingMultiSpan() {
        let result = edit(.clearFormatting, "**b** *c*", NSRange(location: 0, length: 9))
        #expect(result == FormattingEdit(
            range: NSRange(location: 0, length: 9), text: "b c", selection: NSRange(location: 0, length: 3)))
    }

    @Test("Clear formatting preserves un-emphasized text between two distant spans")
    func clearFormattingPreservesTextBetweenSpans() {
        // The cleared range is the union of both bold spans; the plain run between them
        // must survive (only marker runs are deleted, not the gap).
        let result = edit(.clearFormatting, "a **b** plain **c** d", NSRange(location: 0, length: 21))
        #expect(result.range == NSRange(location: 2, length: 17))   // first `**` … last `**`
        #expect(result.text == "b plain c")
    }

    @Test("Clear formatting also clears strikethrough and inline code")
    func clearFormattingCodeAndStrike() {
        #expect(edit(.clearFormatting, "~~y~~", NSRange(location: 2, length: 1)).text == "y")
        #expect(edit(.clearFormatting, "`x`", NSRange(location: 1, length: 1)).text == "x")
    }

    @Test("Strikethrough refuses any selection that wouldn't parse back to a span")
    func strikethroughRefusesUnparseableWrap() {
        // Inner tilde — `~~a~b~~` doesn't form a span; refuse (identity no-op).
        let inner = NSRange(location: 0, length: 3)
        #expect(edit(.strikethrough, "a~b", inner)
            == FormattingEdit(range: inner, text: "a~b", selection: inner))
        // Adjacent tilde just OUTSIDE the selection — wrapping "foo" would make `~~~foo~~`
        // (an unbalanced run), so refuse that too.
        let adj = NSRange(location: 1, length: 3)   // "foo" in "~foo"
        #expect(edit(.strikethrough, "~foo", adj)
            == FormattingEdit(range: adj, text: "foo", selection: adj))
        // A clean selection still wraps normally.
        #expect(edit(.strikethrough, "ab", NSRange(location: 0, length: 2))
            == FormattingEdit(range: NSRange(location: 0, length: 2), text: "~~ab~~", selection: NSRange(location: 2, length: 2)))
    }

    @Test("Inline code refuses a fence that would merge with an adjacent backtick")
    func inlineCodeRefusesAdjacentBacktick() {
        // "foo" in "`foo" — wrapping makes ``` ``foo` ```, an unbalanced run that forms no span.
        let adj = NSRange(location: 1, length: 3)
        #expect(edit(.inlineCode, "`foo", adj)
            == FormattingEdit(range: adj, text: "foo", selection: adj))
    }

    @Test("Clear formatting restores a padded inline-code span's content, escaped and inert")
    func clearFormattingPaddedInlineCode() {
        // Inline code built from "`x" is `` ` `x ` `` (padded); clearing it drops the fence/padding
        // and escapes the literal backtick so it can't start a new span — i.e. "\`x", not " `x ".
        let padded = edit(.inlineCode, "`x", NSRange(location: 0, length: 2)).text   // "`` `x ``"
        let cleared = edit(.clearFormatting, padded, NSRange(location: 3, length: 0)).text
        #expect(cleared == "\\`x")
    }

    @Test("Clear formatting escapes Markdown in cleared inline-code content so it stays inert")
    func clearFormattingEscapesCodeContent() {
        // `*x*` as a code span → clearing must NOT write raw `*x*` (which re-parses as italic);
        // it backslash-escapes the delimiters so the result is plain, inert text.
        let cleared = edit(.clearFormatting, "`*x*`", NSRange(location: 2, length: 1)).text
        #expect(cleared == "\\*x\\*")
        #expect(!MarkdownTokenizer.parseTokensViaAST(in: cleared).contains { $0.kind == .italic })
    }

    @Test("Clear formatting escapes a dollar sign so cleared code can't re-form inline LaTeX")
    func clearFormattingEscapesDollarLatex() {
        let cleared = edit(.clearFormatting, "`$a+b$`", NSRange(location: 3, length: 1)).text
        #expect(cleared == "\\$a+b\\$")
        #expect(!MarkdownTokenizer.parseTokensViaAST(in: cleared).contains { $0.kind == .inlineLatex })
    }

    @Test("Clear formatting unwraps inline code nested inside bold")
    func clearFormattingNestedCodeInBold() {
        // Both the bold token and the nested inline-code token are affected; their replacements
        // (bold markers deleted, code span → escaped content) are disjoint and must combine to "x".
        #expect(edit(.clearFormatting, "**`x`**", NSRange(location: 3, length: 0)).text == "x")
    }

    @Test("Clear formatting fully neutralizes a code span packed with inline delimiters")
    func clearFormattingNeutralizesAllInlineDelimiters() {
        // A code span whose literal text exercises every inline construct that could re-form from
        // raw text (emphasis, strikethrough, latex, link, wiki-link, image, autolink). After
        // clearing, NONE of those tokens may reappear — proves the escape set is complete.
        let messy = "*a* _b_ ~c~ $e$ [f](g) ![h](i) [[j]] <k>"
        let coded = "`" + messy + "`"   // single-backtick fence (messy has no backtick)
        let cleared = edit(.clearFormatting, coded, NSRange(location: 3, length: 0)).text
        let inlineKinds: Set<MarkdownTokenKind> =
            [.bold, .italic, .boldItalic, .strikethrough, .inlineCode, .inlineLatex,
             .link, .wikiLink, .imageEmbed, .imageLink]
        let reformed = MarkdownTokenizer.parseTokensViaAST(in: cleared).filter { inlineKinds.contains($0.kind) }
        #expect(reformed.isEmpty)
    }

    @Test("Clear formatting is an identity edit on plain text")
    func clearFormattingNoOp() {
        #expect(edit(.clearFormatting, "plain", NSRange(location: 0, length: 5))
            == FormattingEdit(range: NSRange(location: 0, length: 5), text: "plain", selection: NSRange(location: 0, length: 5)))
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

    // MARK: - Blockquote

    @Test("Blockquote adds a > prefix and selects the line text")
    func blockquoteAddsPrefix() {
        #expect(edit(.blockquote, "hi", NSRange(location: 0, length: 0))
            == FormattingEdit(range: NSRange(location: 0, length: 2), text: "> hi", selection: NSRange(location: 2, length: 2)))
    }

    @Test("Blockquote toggles off one level of quoting")
    func blockquoteTogglesOff() {
        #expect(edit(.blockquote, "> hi", NSRange(location: 2, length: 0))
            == FormattingEdit(range: NSRange(location: 0, length: 4), text: "hi", selection: NSRange(location: 0, length: 2)))
        // Nested: removes only the outer level.
        #expect(edit(.blockquote, ">> hi", NSRange(location: 3, length: 0)).text == "> hi")
    }

    @Test("Blockquote detection and toggle agree on an indented quote (matches the tokenizer)")
    func blockquoteIndentedLineTogglesOff() {
        // The block tokenizer accepts up to 3 leading spaces before `>`, so an indented quote both
        // reports active AND toggles off (rather than getting double-quoted).
        #expect(MarkdownFormatting.isActive(.blockquote, text: "   > hi", selection: NSRange(location: 5, length: 0)))
        #expect(edit(.blockquote, "   > hi", NSRange(location: 5, length: 0)).text == "hi")
    }

    @Test("Blockquote preserves a non-final line's newline")
    func blockquotePreservesNewline() {
        let result = edit(.blockquote, "a\nb", NSRange(location: 0, length: 0))
        #expect(result.range == NSRange(location: 0, length: 2))   // "a\n"
        #expect(result.text == "> a\n")
    }

    // MARK: - Code block (fenced)

    @Test("Code block wraps the line in a fence and selects the body")
    func codeBlockWrapsLine() {
        #expect(edit(.codeBlock, "foo", NSRange(location: 0, length: 3))
            == FormattingEdit(range: NSRange(location: 0, length: 3), text: "```\nfoo\n```", selection: NSRange(location: 4, length: 3)))
    }

    @Test("Code block toggles off by unwrapping the fenced block")
    func codeBlockTogglesOff() {
        #expect(edit(.codeBlock, "```\ncode\n```", NSRange(location: 5, length: 0))
            == FormattingEdit(range: NSRange(location: 0, length: 12), text: "code", selection: NSRange(location: 0, length: 4)))
    }

    @Test("Code block refuses a body that already contains a fence line (would close early)")
    func codeBlockRefusesBodyWithFence() {
        // This engine closes a fence on any line starting with ```, so a body containing a ```
        // line can't be wrapped cleanly — verifiedWrap returns an identity no-op.
        let selection = NSRange(location: 0, length: 7)
        #expect(edit(.codeBlock, "a\n```\nb", selection)
            == FormattingEdit(range: selection, text: "a\n```\nb", selection: selection))
    }

    @Test("Code block on an empty selection inserts an empty fenced block")
    func codeBlockEmptyInsert() {
        #expect(edit(.codeBlock, "", NSRange(location: 0, length: 0))
            == FormattingEdit(range: NSRange(location: 0, length: 0), text: "```\n\n```", selection: NSRange(location: 4, length: 0)))
    }

    // MARK: - Active state (menu on/off)

    @Test("isActive reflects the current formatting")
    func isActiveReflectsState() {
        #expect(MarkdownFormatting.isActive(.bold, text: "**foo**", selection: NSRange(location: 2, length: 3)))
        #expect(!MarkdownFormatting.isActive(.bold, text: "foo", selection: NSRange(location: 0, length: 3)))
        #expect(MarkdownFormatting.isActive(.heading(1), text: "# foo", selection: NSRange(location: 0, length: 0)))
        #expect(MarkdownFormatting.isActive(.bulletList, text: "- foo", selection: NSRange(location: 0, length: 0)))
        // Bullet and numbered are distinct (a numbered line isn't "active" for bullet, and vice-versa).
        #expect(MarkdownFormatting.isActive(.numberedList, text: "1. foo", selection: NSRange(location: 0, length: 0)))
        #expect(!MarkdownFormatting.isActive(.bulletList, text: "1. foo", selection: NSRange(location: 0, length: 0)))
        #expect(!MarkdownFormatting.isActive(.numberedList, text: "- foo", selection: NSRange(location: 0, length: 0)))
    }

    @Test("isActive reflects strikethrough and inline code")
    func isActiveStrikethroughAndCode() {
        #expect(MarkdownFormatting.isActive(.strikethrough, text: "~~foo~~", selection: NSRange(location: 2, length: 3)))
        #expect(!MarkdownFormatting.isActive(.strikethrough, text: "foo", selection: NSRange(location: 0, length: 3)))
        #expect(MarkdownFormatting.isActive(.inlineCode, text: "`foo`", selection: NSRange(location: 1, length: 3)))
        #expect(!MarkdownFormatting.isActive(.inlineCode, text: "foo", selection: NSRange(location: 0, length: 3)))
        // clearFormatting is an action, never an "on" state.
        #expect(!MarkdownFormatting.isActive(.clearFormatting, text: "**foo**", selection: NSRange(location: 2, length: 3)))
    }

    @Test("isActive reflects blockquote and code block")
    func isActiveBlockquoteAndCodeBlock() {
        #expect(MarkdownFormatting.isActive(.blockquote, text: "> q", selection: NSRange(location: 2, length: 0)))
        #expect(!MarkdownFormatting.isActive(.blockquote, text: "q", selection: NSRange(location: 0, length: 0)))
        #expect(MarkdownFormatting.isActive(.codeBlock, text: "```\nc\n```", selection: NSRange(location: 5, length: 0)))
        #expect(!MarkdownFormatting.isActive(.codeBlock, text: "c", selection: NSRange(location: 0, length: 0)))
    }

    // MARK: - Selection state (toolbar sync)

    private func state(_ text: String, _ selection: NSRange) -> MarkdownSelectionState {
        MarkdownFormatting.selectionState(
            text: text, selection: selection,
            tokens: MarkdownTokenizer.parseTokensViaAST(in: text)
        )
    }

    @Test("Selection state flags bold and italic from the enclosing token")
    func selectionStateEmphasis() {
        #expect(state("a **b** c", NSRange(location: 4, length: 0)).isBold)
        #expect(state("a *b* c", NSRange(location: 3, length: 0)).isItalic)
        let plain = state("plain text", NSRange(location: 2, length: 0))
        #expect(!plain.isBold && !plain.isItalic && plain.headingLevel == nil)
    }

    @Test("Bold-italic span flags both bold and italic")
    func selectionStateBoldItalic() {
        let s = state("***x***", NSRange(location: 4, length: 0))
        #expect(s.isBold && s.isItalic)
    }

    @Test("Selection state flags strikethrough and inline code from the enclosing token")
    func selectionStateStrikethroughAndCode() {
        #expect(state("a ~~b~~ c", NSRange(location: 4, length: 0)).isStrikethrough)
        #expect(state("a `b` c", NSRange(location: 3, length: 0)).isInlineCode)
        let plain = state("plain", NSRange(location: 2, length: 0))
        #expect(!plain.isStrikethrough && !plain.isInlineCode)
    }

    @Test("Selection state reports the caret line's heading level")
    func selectionStateHeading() {
        #expect(state("# Title", NSRange(location: 3, length: 0)).headingLevel == 1)
        #expect(state("### Deep", NSRange(location: 5, length: 0)).headingLevel == 3)
        #expect(state("body", NSRange(location: 1, length: 0)).headingLevel == nil)
    }

    @Test("Selection state distinguishes bullet vs numbered list lines")
    func selectionStateLists() {
        #expect(state("- item", NSRange(location: 3, length: 0)).isBulletList)
        #expect(!state("- item", NSRange(location: 3, length: 0)).isNumberedList)
        #expect(state("1. item", NSRange(location: 4, length: 0)).isNumberedList)
        #expect(!state("1. item", NSRange(location: 4, length: 0)).isBulletList)
    }

    @Test("Selection state flags blockquote and code-block lines")
    func selectionStateBlockAndCode() {
        #expect(state("> quoted", NSRange(location: 3, length: 0)).isBlockquote)
        #expect(!state("plain", NSRange(location: 2, length: 0)).isBlockquote)
        #expect(state("```\ncode\n```", NSRange(location: 5, length: 0)).isCodeBlock)
        #expect(!state("code", NSRange(location: 2, length: 0)).isCodeBlock)
    }
}

