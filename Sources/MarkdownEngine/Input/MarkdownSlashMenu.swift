//
//  MarkdownSlashMenu.swift
//  MarkdownEngine
//
//  The "/" slash-command block-insert menu (plan item 3.2). The engine is host-driven: it
//  DETECTS an active slash trigger at the caret and publishes a `SlashMenuContext` (query +
//  source range + caret rect); the host renders the menu and, on selection, asks the engine to
//  insert a block via `MarkdownSlashMenu.insertEdit`. All logic here is pure and cross-platform
//  (UTF-16 / NSRange units), so it's unit-tested without a live text view.
//

import Foundation
import CoreGraphics

/// A block a user can insert from the slash menu (v1 set).
public enum MarkdownBlockInsert: String, CaseIterable, Equatable, Sendable {
    case heading1, heading2, heading3
    case bulletList, numberedList, checkbox
    case codeBlock, blockquote, table, divider
}

/// A slash-menu row, with the display metadata a host needs to render and filter it.
public struct MarkdownSlashMenuItem: Equatable, Identifiable, Sendable {
    public let block: MarkdownBlockInsert
    public let title: String
    public let systemImage: String
    /// Extra terms (besides the title) the filter matches against, e.g. "h1" / "todo".
    public let keywords: [String]
    public var id: MarkdownBlockInsert { block }
}

/// The active slash trigger at the caret, for a host to render the menu. Published by the editor
/// (mirrors `InlineLinkContext`): nil when the caret isn't in a `/command`.
public struct SlashMenuContext: Equatable {
    /// The text typed after `/` (e.g. "head" for `/head`); empty right after the `/`.
    public let query: String
    /// The full source range of the trigger including the leading `/`, for replacement on insert.
    public let sourceRange: NSRange
    /// Caret rect to anchor the menu, in the EDITOR HOST'S OVERLAY coordinate space — which differs
    /// by platform (same rect field, platform-specific space):
    /// - **iOS:** WINDOW coordinates — position a SwiftUI overlay in `.global` space (which equals
    ///   the window only for a full-screen host; otherwise map it through a known view's window).
    /// - **macOS:** the editor view's LOCAL (scroll-content) space — anchor an overlay placed
    ///   directly over the wrapper (AppKit window coords are y-flipped vs SwiftUI's `.global`, so
    ///   view-local is the clean anchor here).
    /// In both cases it reflects the on-screen caret position incl. scroll offset, captured at
    /// publish time — so it can lag a manual scroll while the menu stays open.
    public let anchorRect: CGRect

    public init(query: String, sourceRange: NSRange, anchorRect: CGRect) {
        self.query = query
        self.sourceRange = sourceRange
        self.anchorRect = anchorRect
    }
}

public enum MarkdownSlashMenu {

    /// The full v1 menu, in display order.
    public static let allItems: [MarkdownSlashMenuItem] = [
        .init(block: .heading1, title: "Heading 1", systemImage: "textformat.size.larger", keywords: ["h1", "title"]),
        .init(block: .heading2, title: "Heading 2", systemImage: "textformat.size", keywords: ["h2", "subtitle"]),
        .init(block: .heading3, title: "Heading 3", systemImage: "textformat.size.smaller", keywords: ["h3"]),
        .init(block: .bulletList, title: "Bulleted List", systemImage: "list.bullet", keywords: ["bullet", "unordered", "ul"]),
        .init(block: .numberedList, title: "Numbered List", systemImage: "list.number", keywords: ["ordered", "ol", "number"]),
        .init(block: .checkbox, title: "Checkbox", systemImage: "checklist", keywords: ["todo", "task", "check"]),
        .init(block: .codeBlock, title: "Code Block", systemImage: "curlybraces", keywords: ["code", "fence", "pre"]),
        .init(block: .blockquote, title: "Quote", systemImage: "text.quote", keywords: ["blockquote", "quote"]),
        .init(block: .table, title: "Table", systemImage: "tablecells", keywords: ["table", "grid"]),
        .init(block: .divider, title: "Divider", systemImage: "minus", keywords: ["divider", "rule", "hr", "separator"]),
    ]

    /// Items whose title, keywords, or block name contain `query` (case-insensitive). An empty
    /// query returns the full menu. Title/keyword prefix matches sort ahead of substring matches.
    public static func items(matching query: String) -> [MarkdownSlashMenuItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allItems }
        return allItems
            .compactMap { item -> (item: MarkdownSlashMenuItem, rank: Int)? in
                let haystacks = [item.title.lowercased()] + item.keywords.map { $0.lowercased() } + ["\(item.block)".lowercased()]
                guard let best = haystacks.compactMap({ rank(of: q, in: $0) }).min() else { return nil }
                return (item, best)
            }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : order(of: $0.item) < order(of: $1.item) }
            .map(\.item)
    }

    /// 0 = exact, 1 = prefix, 2 = substring, nil = no match — for ranking filter results.
    private static func rank(of query: String, in haystack: String) -> Int? {
        if haystack == query { return 0 }
        if haystack.hasPrefix(query) { return 1 }
        return haystack.contains(query) ? 2 : nil
    }

    private static func order(of item: MarkdownSlashMenuItem) -> Int {
        allItems.firstIndex { $0.block == item.block } ?? .max
    }

    // MARK: - Trigger detection

    /// The active slash trigger for a zero-length caret in `text`, or nil. A trigger is a `/` at
    /// line start or immediately after whitespace, followed by a run of non-whitespace (the query)
    /// up to the caret — so mid-word slashes (`a/b`), URLs (`http://`), and a `/` followed by a
    /// space all close the menu.
    public static func trigger(in text: String, caret: Int) -> (query: String, sourceRange: NSRange)? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        var index = caret
        while index > 0 {
            let character = ns.character(at: index - 1)
            if character == 0x2F {                          // '/'
                let slash = index - 1
                let precededOK = slash == 0 || isWhitespace(ns.character(at: slash - 1))
                guard precededOK else { return nil }
                let query = ns.substring(with: NSRange(location: index, length: caret - index))
                return (query, NSRange(location: slash, length: caret - slash))
            }
            if isWhitespace(character) { return nil }        // whitespace before any `/` → no trigger
            index -= 1
        }
        return nil
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        // Match the Unicode whitespace/newline set (incl. nbsp, U+2028/2029, NEL) so trigger
        // detection agrees with how `getLineStart` splits lines.
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: - Block insertion

    /// The edit that inserts `block`, replacing the `/query` (`sourceRange`) on its line. Line-level
    /// blocks (headings, lists, checkbox, quote, code) prefix/wrap the line's remaining content;
    /// table and divider drop in starter markdown. Pure — apply via the platform's undoable-edit path
    /// for single-step undo. (Internal: returns the internal `FormattingEdit`; hosts go through the
    /// controller's `insertBlock`.)
    static func insertEdit(_ block: MarkdownBlockInsert, replacing sourceRange: NSRange, in text: String) -> FormattingEdit {
        let ns = text as NSString
        // The host hands back a PUBLISHED (potentially stale) range; never trust it. An OOB range
        // would crash `getLineStart`/`lineRange` with NSRangeException — so no-op out of bounds.
        guard sourceRange.location >= 0, NSMaxRange(sourceRange) <= ns.length else {
            let safe = max(0, min(sourceRange.location, ns.length))
            return FormattingEdit(range: NSRange(location: safe, length: 0), text: "", selection: NSRange(location: safe, length: 0))
        }

        // Split the line via getLineStart so the terminator boundary matches `lineRange` for EVERY
        // Unicode line separator (CR/LF/CRLF, U+2028/2029, NEL, FF), not just ASCII.
        var lineStart = 0, contentsEnd = 0, lineEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: sourceRange)
        let lineText = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        let terminator = ns.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))

        // The line content with the `/query` removed (the slash trigger lives within this line).
        let relativeQuery = NSRange(location: sourceRange.location - lineStart, length: sourceRange.length)
        let cleaned = (lineText as NSString).replacingCharacters(in: relativeQuery, with: "")

        let rendered = render(block, content: cleaned, lineStart: lineStart)
        return FormattingEdit(
            range: NSRange(location: lineStart, length: lineEnd - lineStart),
            text: rendered.text + terminator, selection: rendered.selection
        )
    }

    /// Build a block's replacement text + resulting selection for a line starting at `lineStart`
    /// whose remaining content (after removing the `/query`) is `content`.
    private static func render(_ block: MarkdownBlockInsert, content: String, lineStart: Int) -> (text: String, selection: NSRange) {
        func prefixed(_ prefix: String) -> (String, NSRange) {
            // Caret right after the marker, before any remaining content.
            (prefix + content, NSRange(location: lineStart + (prefix as NSString).length, length: 0))
        }
        switch block {
        case .heading1:    return prefixed("# ")
        case .heading2:    return prefixed("## ")
        case .heading3:    return prefixed("### ")
        case .bulletList:  return prefixed("- ")
        case .numberedList: return prefixed("1. ")
        case .checkbox:    return prefixed("- [ ] ")
        case .blockquote:  return prefixed("> ")
        case .codeBlock:
            // Fenced block; caret on the (blank) code line.
            let text = "```\n" + content + "\n```"
            return (text, NSRange(location: lineStart + 4, length: 0))           // after "```\n"
        case .divider:
            // Thematic break on its own line; any remaining content moves below it, with the caret
            // following onto that content line.
            if content.isEmpty {
                return ("---", NSRange(location: lineStart + 3, length: 0))       // after "---"
            }
            return ("---\n" + content, NSRange(location: lineStart + 4, length: 0))  // start of the content line
        case .table:
            // GFM starter table; select the first header cell's placeholder so the user types over it.
            let header = "| Column 1 | Column 2 |"
            let text = header + "\n| --- | --- |\n|  |  |" + (content.isEmpty ? "" : "\n" + content)
            return (text, NSRange(location: lineStart + 2, length: 8))           // "Column 1"
        }
    }
}
