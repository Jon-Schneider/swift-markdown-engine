//
//  MacOSWidthChangeRestyleTests.swift
//  MarkdownEngineTests
//
//  Scoping of the macOS width-change restyle: which paragraphs `NativeTextView`
//  re-styles after the editor's width changes. Wide tables are found by their
//  stamped `.scrollableBlockFullRange`; an ACTIVE (revealed) table has no such
//  stamp (it renders no image) and is located via the active token set so its
//  width-dependent reveal-height reservation is dropped when a resize turns it
//  wide. Active block-LaTeX is excluded (its reservation is width-independent).
//  Headless — pure over (storage, activeTokenIndices, tokens).
//

#if os(macOS)
// macOS-only test (AppKit / NSTextStorage-centric). Guarded so the shared
// MarkdownEngineTests target also compiles for the iOS simulator.
import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("macOS width-change restyle scoping")
struct MacOSWidthChangeRestyleTests {

    /// A document with both a table and a block-LaTeX, plus the parsed tokens and the indices of
    /// each, so tests can mark either active and assert the resulting restyle scope.
    private func setupTableAndLatexDocument() -> (
        storage: NSTextStorage,
        tokens: [MarkdownToken],
        tableIndex: Int,
        blockLatexIndex: Int,
        tableParagraph: NSRange
    ) {
        let text = "intro\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n$$x$$\n\nend"
        let storage = NSTextStorage(string: text)
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let tableIndex = tokens.firstIndex { $0.kind == .table } ?? -1
        let blockLatexIndex = tokens.firstIndex { $0.kind == .blockLatex } ?? -1
        let tableParagraph = (text as NSString).paragraphRange(for: tokens[tableIndex].range)
        return (storage, tokens, tableIndex, blockLatexIndex, tableParagraph)
    }

    @Test("An active (revealed) table's paragraph is collected for restyle")
    func activeTableCollected() {
        let env = setupTableAndLatexDocument()
        let ranges = NativeTextView.widthDependentTableParagraphs(
            in: env.storage, activeTokenIndices: [env.tableIndex], tokens: env.tokens
        )
        #expect(ranges.contains(env.tableParagraph))
    }

    @Test("A wide table's stamped range is collected even when no table is active")
    func stampedWideTableCollected() {
        let env = setupTableAndLatexDocument()
        // Simulate the wide-table render stamp on the table paragraph.
        env.storage.addAttribute(
            .scrollableBlockFullRange,
            value: NSValue(range: env.tableParagraph),
            range: env.tableParagraph
        )
        let ranges = NativeTextView.widthDependentTableParagraphs(
            in: env.storage, activeTokenIndices: [], tokens: env.tokens
        )
        #expect(ranges == [env.tableParagraph])
    }

    @Test("An active block-LaTeX is NOT collected (its reservation is width-independent)")
    func activeBlockLatexNotCollected() {
        let env = setupTableAndLatexDocument()
        let ranges = NativeTextView.widthDependentTableParagraphs(
            in: env.storage, activeTokenIndices: [env.blockLatexIndex], tokens: env.tokens
        )
        // No table active and no stamp → nothing to restyle for a width change.
        #expect(ranges.isEmpty)
    }

    @Test("A stamped range and the same active table paragraph are de-duplicated")
    func stampAndActiveTableDeduped() {
        let env = setupTableAndLatexDocument()
        env.storage.addAttribute(
            .scrollableBlockFullRange,
            value: NSValue(range: env.tableParagraph),
            range: env.tableParagraph
        )
        let ranges = NativeTextView.widthDependentTableParagraphs(
            in: env.storage, activeTokenIndices: [env.tableIndex], tokens: env.tokens
        )
        #expect(ranges == [env.tableParagraph])   // collected once, not twice
    }

    @Test("Out-of-bounds active indices are ignored (no crash)")
    func outOfBoundsActiveIndexIgnored() {
        let env = setupTableAndLatexDocument()
        let ranges = NativeTextView.widthDependentTableParagraphs(
            in: env.storage, activeTokenIndices: [-1, env.tokens.count, 9999], tokens: env.tokens
        )
        #expect(ranges.isEmpty)
    }
}
#endif
