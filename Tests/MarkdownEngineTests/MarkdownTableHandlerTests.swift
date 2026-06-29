//
//  MarkdownTableHandlerTests.swift
//  MarkdownEngineTests
//
//  Pure decision-layer tests for GFM table grid navigation (plan 1.1): Tab /
//  Shift-Tab walk cells, Enter steps to the cell below / appends a row.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table grid navigation")
struct MarkdownTableHandlerTests {

    private let config = MarkdownEditorConfiguration.default

    // A 2-column table: header, separator, two body rows. Offsets are computed from
    // the literal so the tests don't hard-code brittle integers.
    //
    //   | a | b |        rows[0] header
    //   | - | - |        rows[1] separator
    //   | c | d |        rows[2]
    //   | e | f |        rows[3]
    private static let table = "| a | b |\n| - | - |\n| c | d |\n| e | f |"

    /// Document index just before the first occurrence of `needle`.
    private func at(_ needle: String, in text: String) -> Int {
        (text as NSString).range(of: needle).location
    }

    private func tab(_ text: String, caret: Int) -> TableEditDecision {
        MarkdownTableHandler.tab(currentText: text, selection: NSRange(location: caret, length: 0), configuration: config)
    }
    private func backtab(_ text: String, caret: Int) -> TableEditDecision {
        MarkdownTableHandler.backtab(currentText: text, selection: NSRange(location: caret, length: 0), configuration: config)
    }
    private func newline(_ text: String, caret: Int) -> TableEditDecision {
        MarkdownTableHandler.newline(currentText: text, selection: NSRange(location: caret, length: 0), configuration: config)
    }

    // MARK: - Tab (forward)

    @Test("Tab moves to the next cell in the same row")
    func tabWithinRow() {
        let t = Self.table
        // caret on header "a" → next cell is "b".
        #expect(tab(t, caret: at("a", in: t)) == .moveCaret(at("b", in: t)))
    }

    @Test("Tab from a row's last cell moves to the next data row's first cell, skipping the separator")
    func tabWrapsToNextRowSkippingSeparator() {
        let t = Self.table
        // caret on header "b" (last cell) → first cell of the next DATA row is "c"
        // (the `| - | - |` separator is skipped, never a target).
        #expect(tab(t, caret: at("b", in: t)) == .moveCaret(at("c", in: t)))
    }

    @Test("Tab from the very last cell exits below the table (already a trailing newline)")
    func tabExitsBelowWithTrailingNewline() {
        let t = Self.table + "\nafter"
        // caret on "f" (last cell of last row) → exit below: start of the line after,
        // i.e. the "after" line. (The parsed table range already covers the newline.)
        #expect(tab(t, caret: at("f", in: t)) == .moveCaret(at("after", in: t)))
    }

    @Test("Tab from the very last cell at EOF inserts the exit newline")
    func tabExitsBelowAtEOF() {
        let t = Self.table
        let end = (t as NSString).length
        #expect(tab(t, caret: at("f", in: t)) == .replace(range: NSRange(location: end, length: 0), text: "\n", caret: end + 1))
    }

    // MARK: - Shift-Tab (backward)

    @Test("Shift-Tab moves to the previous cell in the same row")
    func backtabWithinRow() {
        let t = Self.table
        #expect(backtab(t, caret: at("b", in: t)) == .moveCaret(at("a", in: t)))
    }

    @Test("Shift-Tab from a row's first cell moves to the previous data row's last cell")
    func backtabWrapsToPreviousRow() {
        let t = Self.table
        // caret on "c" (first cell of rows[2]) → previous data row is the header,
        // its last cell "b" (separator skipped).
        #expect(backtab(t, caret: at("c", in: t)) == .moveCaret(at("b", in: t)))
    }

    @Test("Shift-Tab at the table's very first cell falls through to native")
    func backtabAtFirstCellIsNative() {
        let t = Self.table
        #expect(backtab(t, caret: at("a", in: t)) == .allowDefault)
    }

    // MARK: - Enter (down a column)

    @Test("Enter moves to the same column in the next data row")
    func enterMovesDownColumn() {
        let t = Self.table
        // caret on "c" (col 0, rows[2]) → same column of rows[3] is "e".
        #expect(newline(t, caret: at("c", in: t)) == .moveCaret(at("e", in: t)))
    }

    @Test("Enter from the header steps over the separator into the first body row")
    func enterFromHeaderSkipsSeparator() {
        let t = Self.table
        // caret on header "b" (col 1) → col 1 of the first data row below is "d".
        #expect(newline(t, caret: at("b", in: t)) == .moveCaret(at("d", in: t)))
    }

    @Test("Enter on the last row of an EOF table appends a new row, same column")
    func enterAppendsRowAtEOF() {
        let t = Self.table
        let end = (t as NSString).length
        // col 1 ("f") → prepend-newline form "\n|  |  |"; col 1 content at index 2 + 3*1 = 5.
        #expect(newline(t, caret: at("f", in: t)) == .replace(range: NSRange(location: end, length: 0), text: "\n|  |  |", caret: end + 5))
    }

    @Test("Enter-appended EOF row, column 0, lands just past the leading pipe")
    func enterAppendsRowColumnZero() {
        let t = Self.table
        let end = (t as NSString).length
        // col 0 ("e") → land at insert index 2 + 3*0 = 2.
        #expect(newline(t, caret: at("e", in: t)) == .replace(range: NSRange(location: end, length: 0), text: "\n|  |  |", caret: end + 2))
    }

    @Test("Enter-append on a MID-DOCUMENT table inserts the row before the following content, not after a blank line")
    func enterAppendsRowMidDocument() {
        // Regression: the table range includes its trailing newline, so its end is
        // the start of the "after" line. The new row must go there followed by its
        // OWN newline ("<row>\n"), keeping "after" on its own line — NOT "\n<row>"
        // (which would orphan the row past a blank line and glue "after" to a cell).
        let t = Self.table + "\nafter"
        // The table block range INCLUDES its trailing newline, so its end is the
        // start of the "after" line — that's the insertion point.
        let end = at("after", in: t)
        // col 1 ("f"): insert "|  |  |\n"; col 1 content at index 1 + 3*1 = 4.
        #expect(newline(t, caret: at("f", in: t)) == .replace(range: NSRange(location: end, length: 0), text: "|  |  |\n", caret: end + 4))
        // And the resulting document is a well-formed, contiguous 5-row table + "after".
        let result = (t as NSString).replacingCharacters(in: NSRange(location: end, length: 0), with: "|  |  |\n")
        #expect(result == "| a | b |\n| - | - |\n| c | d |\n| e | f |\n|  |  |\nafter")
    }

    // MARK: - Gating

    @Test("Outside any table, all three keys fall through to native")
    func outsideTableIsNative() {
        let t = "just a paragraph"
        #expect(tab(t, caret: 3) == .allowDefault)
        #expect(backtab(t, caret: 3) == .allowDefault)
        #expect(newline(t, caret: 3) == .allowDefault)
    }

    @Test("A ranged selection inside a table falls through to native")
    func rangedSelectionIsNative() {
        let t = Self.table
        let sel = NSRange(location: at("a", in: t), length: 3)
        #expect(MarkdownTableHandler.tab(currentText: t, selection: sel, configuration: config) == .allowDefault)
        #expect(MarkdownTableHandler.newline(currentText: t, selection: sel, configuration: config) == .allowDefault)
    }

    @Test("Disabling tableNavigationEnabled reverts all three keys to native")
    func disabledIsNative() {
        var off = MarkdownEditorConfiguration.default
        off.lists.tableNavigationEnabled = false
        let t = Self.table
        let caret = NSRange(location: at("a", in: t), length: 0)
        #expect(MarkdownTableHandler.tab(currentText: t, selection: caret, configuration: off) == .allowDefault)
        #expect(MarkdownTableHandler.backtab(currentText: t, selection: caret, configuration: off) == .allowDefault)
        #expect(MarkdownTableHandler.newline(currentText: t, selection: caret, configuration: off) == .allowDefault)
    }

    @Test("tableNavigationEnabled defaults to enabled")
    func defaultsEnabled() {
        #expect(MarkdownEditorConfiguration.default.lists.tableNavigationEnabled)
    }

    // MARK: - Cell-boundary edge cases

    @Test("A caret resting on a pipe between two cells belongs to the cell before it")
    func caretOnInteriorPipe() {
        let t = Self.table
        // The pipe between "a" and "b": index just after "a " — find the 2nd '|'.
        let firstPipe = at("|", in: t)
        let afterA = (t as NSString).range(of: "|", options: [], range: NSRange(location: firstPipe + 1, length: (t as NSString).length - firstPipe - 1)).location
        // Tab from the pipe (treated as end of cell "a") advances to "b".
        #expect(tab(t, caret: afterA) == .moveCaret(at("b", in: t)))
    }

    @Test("An embedded table (preceded by prose) navigates relative to its own cells")
    func embeddedTable() {
        let prose = "intro text\n\n"
        let t = prose + Self.table
        #expect(tab(t, caret: at("a", in: t)) == .moveCaret(at("b", in: t)))
    }

    @Test("A ragged row with fewer columns clamps Enter to that row's last cell")
    func raggedRowClampsColumn() {
        // Header has 3 cols; the body row below has only 2 — Enter from header col 2
        // (the 3rd cell) clamps to the body row's last (2nd) cell.
        let t = "| a | b | g |\n| - | - | - |\n| c | d |"
        // header col 2 is "g"; body row has cells "c","d" → clamp to "d".
        #expect(newline(t, caret: at("g", in: t)) == .moveCaret(at("d", in: t)))
    }

    @Test("An all-dashes DATA row is not misclassified as a separator (positional detection)")
    func dashOnlyDataRowIsNavigable() {
        // rows[2] is `| - | - |` — all dashes, so content-based separator detection
        // would wrongly skip it (desyncing from the renderer, which draws it as data
        // and would let Enter split it). Positional detection (separator = line 1
        // only) keeps it a real data row: Enter from it must move down, not append,
        // and Tab within it must walk its cells.
        let t = "| a | b |\n| - | - |\n| - | - |\n| c | d |"
        // The all-dashes data row is rows[2]. Find its first "-" after the separator.
        let sepEnd = NSMaxRange((t as NSString).range(of: "| - | - |"))
        let dashRowDash = (t as NSString).range(of: "-", options: [], range: NSRange(location: sepEnd, length: (t as NSString).length - sepEnd)).location
        // Enter from the all-dashes data row → moves down into "| c | d |" (col 0 = "c"),
        // NOT an appended row.
        #expect(newline(t, caret: dashRowDash) == .moveCaret(at("c", in: t)))
        // Tab within it → its second cell (the 2nd "-").
        let secondDash = (t as NSString).range(of: "-", options: [], range: NSRange(location: dashRowDash + 1, length: (t as NSString).length - dashRowDash - 1)).location
        #expect(tab(t, caret: dashRowDash) == .moveCaret(secondDash))
    }

    @Test("A caret in the separator row is redirected into the body, never a native split")
    func separatorRowCaretRedirected() {
        let t = Self.table
        // Caret on the first "-" of the separator row `| - | - |`.
        let dash = at("-", in: t)
        // Enter/Tab must NOT allowDefault (that would split the separator). Both
        // redirect to the first cell of the first body row ("c").
        #expect(newline(t, caret: dash) == .moveCaret(at("c", in: t)))
        #expect(tab(t, caret: dash) == .moveCaret(at("c", in: t)))
        // Shift-Tab from the separator goes up to the previous data row's last cell ("b").
        #expect(backtab(t, caret: dash) == .moveCaret(at("b", in: t)))
    }

    @Test("Enter in a header-only-plus-separator table appends the first body row")
    func headerOnlyTableAppends() {
        let t = "| a | b |\n| - | - |"
        let end = (t as NSString).length
        // No data row below the header → Enter appends a fresh row. col 0 → index 2.
        #expect(newline(t, caret: at("a", in: t)) == .replace(range: NSRange(location: end, length: 0), text: "\n|  |  |", caret: end + 2))
    }

    @Test("Single-column table navigates and appends correctly")
    func singleColumnTable() {
        let t = "| a |\n| - |\n| b |"
        // Tab from the only header cell → next data row's only cell ("b").
        #expect(tab(t, caret: at("a", in: t)) == .moveCaret(at("b", in: t)))
        // Enter on the last row → append a single-cell row "\n|  |", col 0 at index 2.
        let end = (t as NSString).length
        #expect(newline(t, caret: at("b", in: t)) == .replace(range: NSRange(location: end, length: 0), text: "\n|  |", caret: end + 2))
    }

    @Test("Append matches the rendered width when the separator has more columns than the header")
    func appendWidthFollowsSeparator() {
        // Regression (Codex backstop): the renderer derives width from
        // max(header, separator), so this table renders as TWO columns even though
        // the header/body each have one. The appended row must be 2 cells, not 1.
        let t = "| a |\n| - | - |\n| b |"
        let end = (t as NSString).length
        guard let layout = TableLayout.layout(containing: at("a", in: t), in: t) else {
            Issue.record("expected a table layout"); return
        }
        #expect(layout.columnCount == 2)
        // Enter on "b" (last row) → append "\n|  |  |" (two cells), col 0 at index 2.
        #expect(newline(t, caret: at("b", in: t)) == .replace(range: NSRange(location: end, length: 0), text: "\n|  |  |", caret: end + 2))
    }

    @Test("CRLF rows parse without a phantom trailing cell")
    func crlfRowsHaveNoPhantomCell() {
        // Regression (Codex backstop): lineRange includes "\r\n"; stripping only "\n"
        // used to leave a "\r" that defeated trailing-pipe removal, adding a phantom
        // cell. Each row here must have exactly 2 cells, and Tab/Enter target the
        // real cells.
        let t = "| a | b |\r\n| - | - |\r\n| c | d |"
        guard let layout = TableLayout.layout(containing: at("a", in: t), in: t) else {
            Issue.record("expected a table layout"); return
        }
        #expect(layout.rows[0].cells.count == 2)   // not 3 (no phantom)
        #expect(layout.columnCount == 2)
        // Tab from "a" → "b" (the real next cell, not a phantom).
        #expect(tab(t, caret: at("a", in: t)) == .moveCaret(at("b", in: t)))
        // Tab from "b" (last cell of header) → first cell of the next data row "c".
        #expect(tab(t, caret: at("b", in: t)) == .moveCaret(at("c", in: t)))
    }

    @Test("Multibyte (emoji) cell content keeps UTF-16 offsets consistent")
    func multibyteCellContent() {
        // "😀" is 2 UTF-16 units; navigation is offset-based, so the next-cell target
        // must still be the literal start of "z".
        let t = "| 😀 | z |\n| - | - |\n| c | d |"
        #expect(tab(t, caret: at("😀", in: t)) == .moveCaret(at("z", in: t)))
    }

    @Test("Empty cells expose a zero-length content target right after the pipe")
    func emptyCellTarget() {
        let t = "| a |  |\n| - | - |\n| c | d |"
        // Tab from "a" lands in the empty 2nd header cell. Its content is empty, so
        // the caret target is just past that cell's opening pipe.
        guard let layout = TableLayout.layout(containing: at("a", in: t), in: t) else {
            Issue.record("expected a table layout"); return
        }
        let secondCell = layout.rows[0].cells[1]
        #expect(secondCell.content.length == 0)
        #expect(tab(t, caret: at("a", in: t)) == .moveCaret(secondCell.content.location))
    }
}
