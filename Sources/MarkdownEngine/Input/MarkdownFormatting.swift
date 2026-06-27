//
//  MarkdownFormatting.swift
//  MarkdownEngine
//
//  Cross-platform Markdown formatting commands (bold / italic / heading / list)
//  for editor context menus. Given the document text and the current selection,
//  each command computes a pure `FormattingEdit` (range to replace, replacement
//  text, resulting selection) that the platform view applies.
//
//  The logic mirrors the macOS `ContextMenu` handlers; offsets are computed in
//  UTF-16 (NSRange) units throughout, so multi-byte content is handled correctly.
//

import Foundation

/// A formatting command a user can invoke from the editor menu.
public enum MarkdownFormattingCommand: Equatable {
    case bold
    case italic
    case heading(Int)
    case bulletList
    case numberedList
}

/// A pure edit: replace `range` with `text`, then select `selection`.
struct FormattingEdit: Equatable {
    let range: NSRange
    let text: String
    let selection: NSRange
}

enum MarkdownFormatting {

    /// The edit that applying `command` to `selection` in `text` should produce.
    static func edit(for command: MarkdownFormattingCommand, text: String, selection: NSRange) -> FormattingEdit {
        switch command {
        case .bold:
            return emphasisEdit(text: text, selection: selection, marker: "**", single: .bold, boldItalicResidual: "*")
        case .italic:
            return emphasisEdit(text: text, selection: selection, marker: "*", single: .italic, boldItalicResidual: "**")
        case .heading(let level):
            return headingEdit(text: text, selection: selection, level: level)
        case .bulletList:
            return listEdit(text: text, selection: selection, prefix: "- ")
        case .numberedList:
            return listEdit(text: text, selection: selection, prefix: "1. ")
        }
    }

    /// Whether `command` is already applied at `selection` (for menu on/off state).
    static func isActive(_ command: MarkdownFormattingCommand, text: String, selection: NSRange) -> Bool {
        let ns = text as NSString
        switch command {
        case .bold:
            return enclosingEmphasis(text: text, selection: selection, single: .bold) != nil
        case .italic:
            return enclosingEmphasis(text: text, selection: selection, single: .italic) != nil
        case .heading(let level):
            let line = ns.substring(with: ns.lineRange(for: selection)).trimmingCharacters(in: .whitespacesAndNewlines)
            return line.hasPrefix(String(repeating: "#", count: level) + " ")
        case .bulletList, .numberedList:
            let line = ns.substring(with: ns.lineRange(for: selection))
            return line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
                || line.hasPrefix("\t• ") || line.hasPrefix("1. ")
        }
    }

    // MARK: - Emphasis (bold / italic)

    private static func enclosesSelection(_ tokenRange: NSRange, _ selection: NSRange) -> Bool {
        selection.location >= tokenRange.location && NSMaxRange(selection) <= NSMaxRange(tokenRange)
    }

    private static func enclosingEmphasis(text: String, selection: NSRange, single: MarkdownTokenKind) -> MarkdownToken? {
        MarkdownTokenizer.parseTokensViaAST(in: text).first {
            ($0.kind == single || $0.kind == .boldItalic) && enclosesSelection($0.range, selection)
        }
    }

    private static func emphasisEdit(
        text: String, selection: NSRange, marker: String,
        single: MarkdownTokenKind, boldItalicResidual: String
    ) -> FormattingEdit {
        let ns = text as NSString

        // Already emphasized → toggle off (boldItalic keeps the other marker).
        if let token = enclosingEmphasis(text: text, selection: selection, single: single) {
            let residual = token.kind == .boldItalic ? boldItalicResidual : ""
            let content = ns.substring(with: token.contentRange)
            let newText = residual + content + residual
            let location = token.range.location + (residual as NSString).length
            return FormattingEdit(
                range: token.range, text: newText,
                selection: NSRange(location: location, length: (content as NSString).length)
            )
        }

        // Empty selection → insert the markers and park the caret between them.
        if selection.length == 0 {
            return FormattingEdit(
                range: selection, text: marker + marker,
                selection: NSRange(location: selection.location + (marker as NSString).length, length: 0)
            )
        }

        // Wrap the selection, keeping any leading/trailing whitespace outside the markers.
        let original = ns.substring(with: selection)
        let leadingCount = original.prefix { $0.isWhitespace }.count
        let trailingCount = original.reversed().prefix { $0.isWhitespace }.count
        let leading = String(original.prefix(leadingCount))
        let trailing = String(original.suffix(trailingCount))
        let coreStart = original.index(original.startIndex, offsetBy: leadingCount)
        let coreEnd = original.index(original.endIndex, offsetBy: -trailingCount)
        let core = coreStart <= coreEnd ? String(original[coreStart..<coreEnd]) : ""
        let newText = leading + marker + core + marker + trailing
        let location = selection.location + (leading as NSString).length + (marker as NSString).length
        return FormattingEdit(
            range: selection, text: newText,
            selection: NSRange(location: location, length: (core as NSString).length)
        )
    }

    // MARK: - Heading

    private static func headingEdit(text: String, selection: NSRange, level: Int) -> FormattingEdit {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        let originalLine = ns.substring(with: lineRange)
        var content = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
        while content.hasPrefix("#") { content.removeFirst() }
        content = content.trimmingCharacters(in: .whitespaces)
        let prefix = String(repeating: "#", count: level) + " "
        // Preserve the trailing newline so a non-final line isn't merged with the next.
        let suffix = originalLine.hasSuffix("\n") ? "\n" : ""
        let newLine = prefix + content + suffix
        let location = lineRange.location + (prefix as NSString).length
        return FormattingEdit(
            range: lineRange, text: newLine,
            selection: NSRange(location: location, length: (content as NSString).length)
        )
    }

    // MARK: - List

    private static func listEdit(text: String, selection: NSRange, prefix: String) -> FormattingEdit {
        let ns = text as NSString
        let startLine = ns.lineRange(for: selection)
        let originalLine = ns.substring(with: startLine)
        let lineText = originalLine.trimmingCharacters(in: .newlines)
        var content = lineText
        if content.hasPrefix(prefix) {
            // Strip an existing identical prefix before re-adding it below — idempotent.
            // (The menu disables the command when the line is already a list.)
            content = String(content.dropFirst(prefix.count))
        }
        let suffix = originalLine.hasSuffix("\n") ? "\n" : ""
        let newLine = prefix + content + suffix
        let location = startLine.location + (prefix as NSString).length
        return FormattingEdit(
            range: startLine, text: newLine,
            selection: NSRange(location: location, length: (content as NSString).length)
        )
    }
}
