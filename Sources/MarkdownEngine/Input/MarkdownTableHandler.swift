//
//  MarkdownTableHandler.swift
//  MarkdownEngine
//
//  Grid navigation for GFM tables (plan 1.1): Tab / Shift-Tab walk across cells,
//  Enter moves to the cell directly below (appending a row from the last row).
//
//  This is the pure, cross-platform, side-effect-free decision layer — it mirrors
//  `MarkdownSeamlessInput` / `MarkdownLists.computeListInsertion`: it takes the whole
//  document plus the current selection and returns *what should happen*, which the
//  iOS `UITextView` and macOS `NSTextView` adapters apply identically. It never edits
//  a text view itself, so it's unit-testable (`MarkdownTableHandlerTests`).
//
//  Cell boundaries here intentionally MIRROR the renderer's `parseTableRow`
//  (`MarkdownStyler+Tables.swift`) — a naive split on `|`, outer pipes stripped,
//  whitespace trimmed — so the caret lands exactly on the cell text the user sees
//  drawn. Making this layer escape-aware (`\|`, pipes inside code spans) without
//  also teaching the renderer the same boundaries would desync the caret from the
//  grid; that's a deliberate joint follow-up, not part of this layer.
//

import Foundation

/// What should happen to a Tab / Shift-Tab / Enter pressed inside a table, in the
/// shape the platform adapters already understand (mirrors ``SeamlessEditDecision``
/// / ``ListInsertionDecision``).
enum TableEditDecision: Equatable {
    /// Not in a table (or feature disabled / ranged selection) — native behavior.
    case allowDefault
    /// Swallow the key and just move the collapsed caret to this location (no text
    /// change, so no undo step). Used for in-grid navigation.
    case moveCaret(Int)
    /// Replace `range` with `text` and place the caret at `caret` (one undoable
    /// edit). Used when navigation must also mutate text — appending a row, or
    /// inserting the newline that exits below a table with no trailing newline.
    case replace(range: NSRange, text: String, caret: Int)
}

enum MarkdownTableHandler {

    /// Where a collapsed caret sits relative to a table's grid.
    private enum CaretSite {
        /// In an editable data cell at `(row, col)`.
        case dataCell(TableLayout, row: Int, col: Int)
        /// Inside the table but not in a data cell — on the `| --- |` separator row
        /// or a border/whitespace gap. A raw Tab/Enter here would split a row, so it
        /// must still be handled: navigation redirects into the adjacent data row.
        case stray(TableLayout, row: Int)
    }

    // MARK: - Public decisions

    /// Tab: move to the next cell; at a row's last cell, to the next data row's
    /// first cell; at the very last cell of the table, exit below it.
    static func tab(
        currentText: String, selection: NSRange, configuration: MarkdownEditorConfiguration
    ) -> TableEditDecision {
        switch site(currentText, selection, configuration) {
        case .none:
            return .allowDefault
        case .dataCell(let layout, let row, let col):
            let cells = layout.rows[row].cells
            if col + 1 < cells.count {
                return .moveCaret(cells[col + 1].content.location)
            }
            if let next = layout.dataRow(after: row), let first = layout.rows[next].cells.first {
                return .moveCaret(first.content.location)
            }
            return exitBelow(layout, in: currentText)
        case .stray(let layout, let row):
            if let next = layout.dataRow(after: row), let first = layout.rows[next].cells.first {
                return .moveCaret(first.content.location)
            }
            return exitBelow(layout, in: currentText)
        }
    }

    /// Shift-Tab: move to the previous cell; at a row's first cell, to the previous
    /// data row's last cell; at the table's very first cell, fall through to native
    /// (no surprising "exit above").
    static func backtab(
        currentText: String, selection: NSRange, configuration: MarkdownEditorConfiguration
    ) -> TableEditDecision {
        switch site(currentText, selection, configuration) {
        case .none:
            return .allowDefault
        case .dataCell(let layout, let row, let col):
            if col > 0 {
                return .moveCaret(layout.rows[row].cells[col - 1].content.location)
            }
            if let prev = layout.dataRow(before: row), let last = layout.rows[prev].cells.last {
                return .moveCaret(last.content.location)
            }
            return .allowDefault
        case .stray(let layout, let row):
            if let prev = layout.dataRow(before: row), let last = layout.rows[prev].cells.last {
                return .moveCaret(last.content.location)
            }
            return .allowDefault
        }
    }

    /// Enter: move to the same column in the next data row; on the last data row,
    /// append a fresh empty row (matching the column count) and land in that column.
    /// Always handled inside a table — a raw newline would split a row and corrupt
    /// the GFM table syntax.
    static func newline(
        currentText: String, selection: NSRange, configuration: MarkdownEditorConfiguration
    ) -> TableEditDecision {
        switch site(currentText, selection, configuration) {
        case .none:
            return .allowDefault
        case .dataCell(let layout, let row, let col):
            if let next = layout.dataRow(after: row) {
                let cells = layout.rows[next].cells
                // Clamp `col` to the target row when it is NARROWER (ragged rows);
                // a wider target keeps `col` as-is. Never fall through to append when
                // a next row genuinely exists.
                if let cell = col < cells.count ? cells[col] : cells.last {
                    return .moveCaret(cell.content.location)
                }
                return .moveCaret(layout.rows[next].lineContent.location)
            }
            return appendRow(layout, column: col, in: currentText)
        case .stray(let layout, let row):
            if let next = layout.dataRow(after: row), let first = layout.rows[next].cells.first {
                return .moveCaret(first.content.location)
            }
            return appendRow(layout, column: 0, in: currentText)
        }
    }

    // MARK: - Locate the caret's site

    /// Resolve the collapsed caret to a ``CaretSite``, or `nil` when navigation must
    /// not engage (feature off, ranged selection, or the caret isn't in a table).
    private static func site(
        _ text: String, _ selection: NSRange, _ configuration: MarkdownEditorConfiguration
    ) -> CaretSite? {
        guard configuration.lists.tableNavigationEnabled, selection.length == 0 else { return nil }
        guard let layout = TableLayout.layout(containing: selection.location, in: text) else { return nil }
        if let (row, col) = layout.cellPosition(of: selection.location) {
            return .dataCell(layout, row: row, col: col)
        }
        if let row = layout.rowIndex(containing: selection.location) {
            return .stray(layout, row: row)
        }
        return nil
    }

    // MARK: - Edits that change text

    /// Exit below the table: land at the start of the line after it. The parsed
    /// table range already includes its trailing newline when one exists, so its
    /// end is then exactly that next-line start — just move there. Only when the
    /// table ends at EOF with no trailing newline (char before `end` isn't `\n`) do
    /// we insert the newline that creates the line below.
    private static func exitBelow(_ layout: TableLayout, in text: String) -> TableEditDecision {
        let ns = text as NSString
        let end = NSMaxRange(layout.tableRange)
        if end > 0, end <= ns.length, ns.character(at: end - 1) == 0x0A {
            return .moveCaret(end)
        }
        return .replace(range: NSRange(location: end, length: 0), text: "\n", caret: end + 1)
    }

    /// Append an empty row (`|  |  |…|`, `columnCount` cells) after the table and
    /// land the caret in `column`'s cell. The inserted cells are two-space padded so
    /// they parse back to the same empty `content` location the caret targets.
    ///
    /// Where the new row + its newline go depends on whether the table already has a
    /// trailing newline (mirrors ``exitBelow``): a mid-document table's range ends at
    /// the *start of the following line*, so the row is inserted there followed by
    /// its own `\n` (keeping the following content on its own line); a table at EOF
    /// has no trailing newline, so the row is prefixed with the `\n` that starts it.
    private static func appendRow(_ layout: TableLayout, column: Int, in text: String) -> TableEditDecision {
        let cols = max(1, layout.columnCount)
        let rowText = "|" + String(repeating: "  |", count: cols)   // "|  |  |…|"
        let col = min(max(column, 0), cols - 1)
        let ns = text as NSString
        let end = NSMaxRange(layout.tableRange)

        if end > 0, end <= ns.length, ns.character(at: end - 1) == 0x0A {
            // Table range already covers its trailing newline → `end` is the next
            // line's start. Insert "<row>\n" so the following content stays below it.
            // In `rowText`, cell k's empty content is just past its opening pipe at
            // index 1 + 3*k.
            let insert = rowText + "\n"
            return .replace(range: NSRange(location: end, length: 0), text: insert, caret: end + 1 + 3 * col)
        }
        // EOF (no trailing newline): prefix the newline that starts the new row, so
        // cell k's content sits at index 2 + 3*k within the inserted "\n<row>".
        let insert = "\n" + rowText
        return .replace(range: NSRange(location: end, length: 0), text: insert, caret: end + 2 + 3 * col)
    }
}

// MARK: - Table layout (cell ranges)

/// Pipe-delimited structure of a single GFM table, resolved on demand from the
/// document text. Rows are in document order and INCLUDE the separator row (flagged),
/// so column indices line up with what's rendered; navigation walks `dataRows` only.
struct TableLayout: Equatable {
    struct Cell: Equatable {
        /// Span between this cell's two bounding pipes (includes padding spaces).
        /// Used for hit-testing which cell the caret is in.
        let outer: NSRange
        /// Trimmed editable content span — the caret target. Zero-length, located at
        /// `outer.location` (just past the opening pipe), for an empty cell.
        let content: NSRange
    }
    struct Row: Equatable {
        /// The row's line, excluding the trailing line terminator.
        let lineContent: NSRange
        /// The `| --- | :-: |` delimiter row — structural, never a navigation target.
        let isSeparator: Bool
        let cells: [Cell]
    }

    let tableRange: NSRange
    let rows: [Row]

    /// Rendered column count — `max(header, separator)`, mirroring the renderer's
    /// `parseTableSource` (`max(header.count, alignments.count)`), which DERIVES the
    /// table width from those two rows only (body rows are padded/truncated to it).
    /// New appended rows match this so they line up with the drawn grid even when the
    /// separator declares more columns than the header (`| a |\n| - | - |`).
    var columnCount: Int {
        let header = rows.first?.cells.count ?? 0
        let separator = rows.count > 1 ? rows[1].cells.count : 0
        return max(header, separator)
    }

    /// Next data (non-separator) row after `row`, or `nil` at the last one.
    func dataRow(after row: Int) -> Int? {
        rows.indices.first { $0 > row && !rows[$0].isSeparator }
    }
    /// Previous data (non-separator) row before `row`, or `nil` at the first one.
    func dataRow(before row: Int) -> Int? {
        rows.indices.reversed().first { $0 < row && !rows[$0].isSeparator }
    }

    /// Index of the row (any kind) whose line contains `caret`, or `nil`.
    func rowIndex(containing caret: Int) -> Int? {
        rows.indices.first {
            NSLocationInRange(caret, rows[$0].lineContent) || caret == NSMaxRange(rows[$0].lineContent)
        }
    }

    /// `(rowIndex, colIndex)` of the data cell containing `caret`, or `nil` if the
    /// caret isn't within a data row's cell.
    func cellPosition(of caret: Int) -> (row: Int, col: Int)? {
        for (r, row) in rows.enumerated() where !row.isSeparator {
            guard NSLocationInRange(caret, row.lineContent) || caret == NSMaxRange(row.lineContent) else { continue }
            for (c, cell) in row.cells.enumerated()
            where NSLocationInRange(caret, cell.outer) || caret == NSMaxRange(cell.outer) {
                return (r, c)
            }
            // Caret on this line but outside every cell's pipe-bounded span (e.g. on
            // the leading pipe or in trailing whitespace) → clamp to the nearest end.
            if let first = row.cells.first, caret <= first.outer.location { return (r, 0) }
            if !row.cells.isEmpty { return (r, row.cells.count - 1) }
        }
        return nil
    }

    // MARK: Build

    private static let pipe: unichar = 0x7C        // |
    private static func isWS(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    /// Build the layout for the table that contains `caret` (a caret at the table's
    /// very end counts as inside its last cell), or `nil` if `caret` isn't in a table.
    static func layout(containing caret: Int, in text: String) -> TableLayout? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        // Block-level parse only (no inline ASTs): we just need the `.table` range.
        var tableRange: NSRange?
        for block in BlockParser.parse(text) where block.kind == .table {
            if NSLocationInRange(caret, block.range) || caret == NSMaxRange(block.range) {
                tableRange = block.range
                break
            }
        }
        guard let tr = tableRange else { return nil }

        var rows: [Row] = []
        let end = NSMaxRange(tr)
        var i = tr.location
        var index = 0
        while i < end {
            let lineRange = ns.lineRange(for: NSRange(location: i, length: 0))
            var contentLen = lineRange.length
            // Strip the trailing line terminator, including a full CRLF — otherwise a
            // leftover `\r` (which `cellRanges` doesn't trim) defeats the trailing-pipe
            // check and a phantom final cell appears on CRLF documents.
            if contentLen > 0 {
                let last = ns.character(at: lineRange.location + contentLen - 1)
                if last == 0x0A {
                    contentLen -= 1
                    if contentLen > 0, ns.character(at: lineRange.location + contentLen - 1) == 0x0D {
                        contentLen -= 1   // CRLF
                    }
                } else if last == 0x0D {
                    contentLen -= 1       // lone CR
                }
            }
            // Clamp to the table range (defensive; lines never exceed it in practice).
            let lineContent = NSRange(
                location: lineRange.location,
                length: min(contentLen, end - lineRange.location)
            )
            // The separator is POSITIONAL: within a `.table` block the tokenizer
            // guarantees the header is line 0 and the `|---|` separator is line 1
            // (`BlockLevelTokenizer.table` requires exactly that), and the block has
            // no interior blank lines. Detecting it by content instead would misflag
            // a legitimate all-dashes data row (`| - | - |`) as a separator — which
            // both desyncs from the renderer (it only treats line 1 as the separator)
            // and would let a native newline split that row.
            let separator = (index == 1)
            // Parse cells for EVERY row, including the separator: navigation skips the
            // separator (via `isSeparator`), but `columnCount` must count its cells to
            // match the renderer's `max(header, separator)` width.
            let cells = cellRanges(in: lineContent, ns: ns)
            rows.append(Row(lineContent: lineContent, isSeparator: separator, cells: cells))
            let next = NSMaxRange(lineRange)
            if next <= i { break }
            i = next
            index += 1
        }
        return TableLayout(tableRange: tr, rows: rows)
    }

    /// Cells of one table row, mirroring the renderer's `parseTableRow`: trim the
    /// line, drop one leading and one trailing pipe, split the interior on every `|`.
    private static func cellRanges(in line: NSRange, ns: NSString) -> [Cell] {
        var start = line.location
        var end = NSMaxRange(line)
        while start < end, isWS(ns.character(at: start)) { start += 1 }
        while end > start, isWS(ns.character(at: end - 1)) { end -= 1 }
        guard start < end else { return [] }
        if ns.character(at: start) == pipe { start += 1 }
        if end > start, ns.character(at: end - 1) == pipe { end -= 1 }
        guard start <= end else { return [] }

        var cells: [Cell] = []
        var cellStart = start
        var i = start
        func emit(upTo cellEnd: Int) {
            let outer = NSRange(location: cellStart, length: cellEnd - cellStart)
            cells.append(Cell(outer: outer, content: trimmed(outer, in: ns)))
        }
        while i < end {
            if ns.character(at: i) == pipe {
                emit(upTo: i)
                cellStart = i + 1
            }
            i += 1
        }
        emit(upTo: end)   // final cell after the last interior pipe
        return cells
    }

    /// Trimmed content span of a cell; zero-length at `outer.location` when empty.
    private static func trimmed(_ outer: NSRange, in ns: NSString) -> NSRange {
        var s = outer.location
        var e = NSMaxRange(outer)
        while s < e, isWS(ns.character(at: s)) { s += 1 }
        while e > s, isWS(ns.character(at: e - 1)) { e -= 1 }
        guard s < e else { return NSRange(location: outer.location, length: 0) }
        return NSRange(location: s, length: e - s)
    }
}
