//
//  MarkdownListHandler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Makes list editing feel natural by continuing items, handling indentation,
// and applying spacing/alignment that keeps lists easy to read.
//
// `MarkdownLists` is split by platform: the pure parsing/decision helpers
// (regexes, `indentLevel`, `blockquoteContinuedPaste`, `computeListInsertion`)
// are cross-platform and used by the shared styler and the iOS input path; the
// `NSTextView`-driven apply methods are macOS-only (gated).
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Decision returned by `MarkdownLists.computeListInsertion` — what should happen
/// to a pending text insertion. Platform adapters apply it to their text view.
enum ListInsertionDecision: Equatable {
    /// Let the system insert the replacement string normally.
    case allowDefault
    /// Swallow the input; perform no edit (e.g. Tab at max nesting depth).
    case block
    /// Replace `range` with `text` and place the caret at `caret`.
    case replace(range: NSRange, text: String, caret: Int)
}

struct MarkdownLists {
    #if os(macOS)
    /// Returns whether the edit was actually applied (a vetoed `shouldChangeText`
    /// leaves the document untouched, so callers must not move the caret).
    @discardableResult
    static func performEdit(_ textView: NSTextView, replace range: NSRange, with string: String) -> Bool {
        let ns = textView.string as NSString
        let loc = min(range.location, ns.length)
        let maxLen = ns.length - loc
        let len = min(range.length, max(0, maxLen))
        let safeRange = NSRange(location: loc, length: len)

        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator { coord.isProgrammaticEdit = true }
        defer {
            if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator { coord.isProgrammaticEdit = false }
        }

        guard textView.shouldChangeText(in: safeRange, replacementString: string) else { return false }
        textView.textStorage?.replaceCharacters(in: safeRange, with: string)
        textView.didChangeText()
        return true
    }
    #endif

    // Markers: `-`/`*`/`+` (raw Markdown) + legacy `•` (rendered, never typed).
    static let listRegex = try! NSRegularExpression(
        pattern: #"^\s*((?:(\d+)\.|[-•*+])(?:\s+\[[ xX]\])?\s+)"#
    )
    /// Blockquote line: ≤3 indent + `>` marker run; group 1 = whitespace, group 2 = markers.
    // Trailing `[ \t]*` so the prefix length covers the space(s) the continuation
    // inserts (`markers + " "`) — otherwise exiting an empty quote leaves a stray
    // space (greedy like listRegex's `\s+`).
    static let blockquoteRegex = try! NSRegularExpression(
        pattern: #"^( {0,3})(>+(?:[ \t]+>+)*)[ \t]*"#
    )
    static let dashNoSpaceRegex = try! NSRegularExpression(pattern: #"^\s*-(?!\s)"#)
    static let leadingWhitespaceRegex = try! NSRegularExpression(pattern: #"^\s*"#)

    static func indentLevel(from leadingWhitespace: String) -> Int {
        let tabCount = leadingWhitespace.filter { $0 == "\t" }.count
        let spaceCount = leadingWhitespace.filter { $0 == " " }.count
        return tabCount + (spaceCount / 2)
    }

    /// Decision that removes the current line's leading marker and parks the caret at
    /// line start (exit an empty list/quote item on Enter). Pure — cross-platform.
    private static func removeLinePrefixDecision(
        currentText: String,
        currentLineRange: NSRange,
        prefixLength: Int
    ) -> ListInsertionDecision {
        let lineEnd = currentLineRange.location + currentLineRange.length
        let hasNewline = currentLineRange.length > 0
            && (currentText as NSString)
                .substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n"
        let maxBodyLen = hasNewline ? currentLineRange.length - 1 : currentLineRange.length
        let removalLength = min(prefixLength, maxBodyLen)
        let removalRange = NSRange(location: currentLineRange.location, length: removalLength)
        return .replace(range: removalRange, text: "", caret: currentLineRange.location)
    }

    /// Mirror Enter-key quote continuation for multi-line pastes: when `location`
    /// sits on a blockquote line, prefix every line after the first with that
    /// line's `>` marker run so the whole paste stays inside the quote. Returns
    /// `pasted` unchanged when it has no newline or the caret isn't in a quote.
    static func blockquoteContinuedPaste(_ pasted: String, at location: Int, in document: String) -> String {
        guard pasted.contains("\n") else { return pasted }
        let ns = document as NSString
        guard location >= 0, location <= ns.length else { return pasted }
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        let nsLine = ns.substring(with: lineRange) as NSString
        guard let match = blockquoteRegex.firstMatch(
            in: nsLine as String,
            range: NSRange(location: 0, length: nsLine.length)
        ) else { return pasted }
        let ws = nsLine.substring(with: match.range(at: 1))
        let markers = nsLine.substring(with: match.range(at: 2))
        let prefix = ws + markers + " "
        return pasted.replacingOccurrences(of: "\n", with: "\n" + prefix)
    }

    // MARK: - Input Handling

    /// Pure, cross-platform list/blockquote/indent/auto-pair input logic. Given the
    /// current document text and the pending edit, decides whether the system should
    /// insert normally (`.allowDefault`), the input should be swallowed (`.block`),
    /// or a specific replacement should be performed (`.replace`). Both the macOS
    /// `handleInsertion` adapter and the iOS `UITextViewDelegate` drive this — the
    /// caret in each `.replace` is explicit so both platforms land identically
    /// (including the continuation cases, where macOS previously relied on the
    /// natural post-replace caret = range start + inserted length).
    static func computeListInsertion(
        currentText: String,
        affectedCharRange: NSRange,
        replacementString: String?,
        configuration: MarkdownEditorConfiguration
    ) -> ListInsertionDecision {
        guard let replacementString = replacementString else { return .allowDefault }

        // Fast path: skip the expensive isInsideCodeBlock scan for ordinary typing.
        if replacementString.count == 1,
           let ch = replacementString.first,
           ch != ">" && ch != "[" && ch != "(" && ch != "{" &&
           ch != "\t" && ch != " " && ch != "\n" {
            return .allowDefault
        }

        let listsEnabled = configuration.lists.helpersEnabled
        let autoClosePairsEnabled = configuration.lists.autoClosePairsEnabled

        func autoPair(open openChar: String, close closeChar: String) -> ListInsertionDecision {
            .replace(range: affectedCharRange,
                     text: "\(openChar)\(closeChar)",
                     caret: affectedCharRange.location + openChar.count)
        }

        let isInCodeBlock = currentText.contains("`")
            ? MarkdownDetection.isInsideCodeBlock(location: affectedCharRange.location, in: currentText)
            : false

        if replacementString == ">" && affectedCharRange.length == 0 && !isInCodeBlock {
            let insertionLocation = affectedCharRange.location
            guard insertionLocation > 0 else { return .allowDefault }
            let nsText = currentText as NSString
            let previousCharRange = NSRange(location: insertionLocation - 1, length: 1)
            let previousChar = nsText.substring(with: previousCharRange)
            if previousChar == "-" {
                return .replace(range: previousCharRange, text: "→", caret: insertionLocation)
            }
        }

        // Autocomplete Obsidian-style node brackets and single square brackets
        if replacementString == "[" {
            let nsText = currentText as NSString
            let insertionLocation = affectedCharRange.location
            if insertionLocation > 0 {
                let prevChar = nsText.substring(with: NSRange(location: insertionLocation - 1, length: 1))
                if prevChar == "[" {
                    let hasAutoCloseBracket = insertionLocation < nsText.length
                        && nsText.substring(with: NSRange(location: insertionLocation, length: 1)) == "]"
                    if hasAutoCloseBracket {
                        // Collapse auto-paired "[]" into "[[]]" without changing surrounding text.
                        return .replace(range: NSRange(location: insertionLocation - 1, length: 2),
                                        text: "[[]]", caret: insertionLocation + 1)
                    } else {
                        // If the char to the right is not "]" (e.g. newline), do not delete it.
                        return .replace(range: affectedCharRange, text: "[]]", caret: insertionLocation + 1)
                    }
                }
            }
            guard autoClosePairsEnabled else { return .allowDefault }
            return autoPair(open: "[", close: "]")
        }

        // Autocomplete parentheses / braces
        if replacementString == "(" || replacementString == "{" {
            guard autoClosePairsEnabled else { return .allowDefault }
            let closeChar = (replacementString == "(") ? ")" : "}"
            return autoPair(open: replacementString, close: closeChar)
        }

        // TAB: indent list items (skip in code blocks)
        if replacementString == "\t" && !isInCodeBlock {
            guard listsEnabled else { return .allowDefault }
            let nsText = currentText as NSString
            let insertionLocation = affectedCharRange.location
            let safeLocTAB = min(affectedCharRange.location, nsText.length)
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocTAB, length: 0))
            let currentLine = nsText.substring(with: currentLineRange)
            if MarkdownLists.listRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) != nil {
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                    let ws = (currentLine as NSString).substring(with: wsMatch.range)
                    let level = MarkdownLists.indentLevel(from: ws)
                    if level >= MarkdownEditorConfiguration.default.lists.maximumNestingLevel {
                        return .block
                    }
                }
                return .replace(range: NSRange(location: currentLineRange.location, length: 0),
                                text: "\t", caret: insertionLocation + 1)
            }
            if MarkdownLists.dashNoSpaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) != nil {
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                    let ws = (currentLine as NSString).substring(with: wsMatch.range)
                    let level = MarkdownLists.indentLevel(from: ws)
                    if level >= MarkdownEditorConfiguration.default.lists.maximumNestingLevel { return .block }
                }
                return .replace(range: NSRange(location: currentLineRange.location, length: 0),
                                text: "\t", caret: insertionLocation + 1)
            }
            return .allowDefault
        }

        // ENTER: list continuation/outdent
        if replacementString == "\n" {
            let nsText = currentText as NSString
            let safeLocENTER = min(affectedCharRange.location, nsText.length)
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocENTER, length: 0))
            let currentLine = nsText.substring(with: currentLineRange).trimmingCharacters(in: .whitespacesAndNewlines)

            // Horizontal rules render via the styler; source stays literal `---` so files round-trip.

            if currentLine.range(of: "^```\\w*$", options: .regularExpression) != nil {
                let textBeforeLine = nsText.substring(to: currentLineRange.location)
                let openingCount = textBeforeLine.components(separatedBy: "```").count - 1
                let afterLineStart = currentLineRange.location + currentLineRange.length
                let hasClosingAfter: Bool = {
                    guard afterLineStart < nsText.length else { return false }
                    return nsText.substring(from: afterLineStart).contains("```")
                }()
                let lineEnd = currentLineRange.location + max(0, currentLineRange.length - 1)
                let cursorAtLineEnd = affectedCharRange.location >= lineEnd

                if openingCount.isMultiple(of: 2) && cursorAtLineEnd && !hasClosingAfter {
                    let insertionLocation = affectedCharRange.location
                    return .replace(range: affectedCharRange, text: "\n\n```", caret: insertionLocation + 1)
                }
            }

            // Skip list / blockquote continuation in code blocks.
            guard listsEnabled && !isInCodeBlock else { return .allowDefault }

            // Blockquote continuation: `> foo` → `\n> `, `>>>` stays `>>>`, empty marker → exit.
            let quoteLine = nsText.substring(with: currentLineRange)
            if let quoteMatch = MarkdownLists.blockquoteRegex.firstMatch(
                in: quoteLine,
                range: NSRange(location: 0, length: quoteLine.utf16.count)
            ) {
                let ws = (quoteLine as NSString).substring(with: quoteMatch.range(at: 1))
                let markers = (quoteLine as NSString).substring(with: quoteMatch.range(at: 2))
                let prefixLength = quoteMatch.range.length
                let contentStart = quoteMatch.range.location + prefixLength
                let contentLength = quoteLine.utf16.count - contentStart
                let contentText = (quoteLine as NSString)
                    .substring(with: NSRange(location: contentStart, length: contentLength))
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if contentText.isEmpty {
                    return removeLinePrefixDecision(
                        currentText: currentText,
                        currentLineRange: currentLineRange,
                        prefixLength: prefixLength
                    )
                }
                let insertText = "\n" + ws + markers + " "
                return .replace(range: affectedCharRange, text: insertText,
                                caret: affectedCharRange.location + (insertText as NSString).length)
            }

            let listLine = nsText.substring(with: currentLineRange)
            if let match = MarkdownLists.listRegex.firstMatch(in: listLine, range: NSRange(location: 0, length: listLine.utf16.count)) {
                let contentStart = match.range.location + match.range.length
                let contentLength = listLine.utf16.count - contentStart
                let contentRangeLocal = NSRange(location: contentStart, length: contentLength)
                let contentText = (listLine as NSString).substring(with: contentRangeLocal).trimmingCharacters(in: .whitespacesAndNewlines)
                if contentText.isEmpty {
                    return removeLinePrefixDecision(
                        currentText: currentText,
                        currentLineRange: currentLineRange,
                        prefixLength: match.range.location + match.range.length
                    )
                }
                let leadingWhitespace: String
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: listLine, range: NSRange(location: 0, length: listLine.utf16.count)) {
                    leadingWhitespace = (listLine as NSString).substring(with: wsMatch.range)
                } else {
                    leadingWhitespace = ""
                }
                let markerRaw = (listLine as NSString).substring(with: match.range(at: 1))
                let marker = markerRaw.trimmingCharacters(in: .whitespaces)
                let hasCheckbox = marker.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil
                let newListItem: String
                if match.range(at: 2).location != NSNotFound,
                   let number = Int((listLine as NSString).substring(with: match.range(at: 2))) {
                    if hasCheckbox {
                        newListItem = "\n" + leadingWhitespace + "\(number + 1). [ ] "
                    } else {
                        newListItem = "\n" + leadingWhitespace + "\(number + 1). "
                    }
                } else {
                    // Continue with the user's marker char (legacy `•` → `-`), keeping leading whitespace.
                    let bulletChar = (marker.first == "•") ? "-" : String(marker.prefix(1))
                    if hasCheckbox {
                        newListItem = "\n" + leadingWhitespace + bulletChar + " [ ] "
                    } else {
                        newListItem = "\n" + leadingWhitespace + bulletChar + " "
                    }
                }
                return .replace(range: affectedCharRange, text: newListItem,
                                caret: affectedCharRange.location + (newListItem as NSString).length)
            }
        }

        return .allowDefault
    }

    #if os(macOS)
    /// macOS adapter: resolve the cross-platform decision and apply it to an
    /// `NSTextView`. Behavior-identical to the pre-extraction inline logic — the
    /// `.replace` caret matches what `performEdit`'s `replaceCharacters` produced
    /// (and the auto-pair / collapse cases keep their explicit caret).
    static func handleInsertion(textView: NSTextView, affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let config = (textView as? NativeTextView)?.configuration ?? .default
        switch computeListInsertion(
            currentText: textView.string,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString,
            configuration: config
        ) {
        case .allowDefault:
            return true
        case .block:
            return false
        case .replace(let range, let text, let caret):
            // Only move the caret if the edit actually applied — a vetoed
            // shouldChangeText leaves the document and selection untouched.
            if performEdit(textView, replace: range, with: text) {
                textView.setSelectedRange(NSRange(location: caret, length: 0))
            }
            return false
        }
    }
    #endif
}
