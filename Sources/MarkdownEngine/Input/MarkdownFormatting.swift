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
    case strikethrough
    case inlineCode
    case heading(Int)
    case bulletList
    case numberedList
    case blockquote
    case codeBlock
    /// Toggle a task checkbox on the caret's line: flip `[ ]`↔`[x]` on an existing task line,
    /// or add `- [ ] ` to a plain / bullet line.
    case toggleCheckbox
    /// Indent the caret's list line one level (prepend a tab). No-op off a list line.
    case indent
    /// Outdent the caret's list line one level (remove a leading tab / up to 2 spaces). No-op
    /// when off a list line or already at the root.
    case outdent
    /// Remove inline emphasis (bold / italic / strikethrough / inline-code) markers from
    /// the selection. A pure action, not a toggle — block-level prefixes (heading, list,
    /// blockquote) are cleared by toggling their own command off, not by this one.
    case clearFormatting
}

/// A pure edit: replace `range` with `text`, then select `selection`.
struct FormattingEdit: Equatable {
    let range: NSRange
    let text: String
    let selection: NSRange
}

/// The formatting active at the current selection, for a host formatting toolbar to
/// reflect (the macOS editor posts this as selection-changed notifications; the iOS
/// `MarkdownEditorController` publishes it). The host lights up Bold when `isBold`, shows
/// the active heading level, etc.
public struct MarkdownSelectionState: Equatable {
    public var isBold: Bool
    public var isItalic: Bool
    public var isStrikethrough: Bool
    public var isInlineCode: Bool
    /// 1...6 when the caret's line is a heading, else nil.
    public var headingLevel: Int?
    public var isBulletList: Bool
    public var isNumberedList: Bool
    public var isBlockquote: Bool
    public var isCodeBlock: Bool
    /// The caret's line is a checked task item (`- [x]`).
    public var isChecked: Bool

    public init(
        isBold: Bool = false,
        isItalic: Bool = false,
        isStrikethrough: Bool = false,
        isInlineCode: Bool = false,
        headingLevel: Int? = nil,
        isBulletList: Bool = false,
        isNumberedList: Bool = false,
        isBlockquote: Bool = false,
        isCodeBlock: Bool = false,
        isChecked: Bool = false
    ) {
        self.isBold = isBold
        self.isItalic = isItalic
        self.isStrikethrough = isStrikethrough
        self.isInlineCode = isInlineCode
        self.headingLevel = headingLevel
        self.isBulletList = isBulletList
        self.isNumberedList = isNumberedList
        self.isBlockquote = isBlockquote
        self.isCodeBlock = isCodeBlock
        self.isChecked = isChecked
    }
}

enum MarkdownFormatting {

    /// The edit that applying `command` to `selection` in `text` should produce.
    static func edit(for command: MarkdownFormattingCommand, text: String, selection: NSRange) -> FormattingEdit {
        switch command {
        case .bold:
            return emphasisEdit(text: text, selection: selection, marker: "**", single: .bold, boldItalicResidual: "*")
        case .italic:
            return emphasisEdit(text: text, selection: selection, marker: "*", single: .italic, boldItalicResidual: "**")
        case .strikethrough:
            return strikethroughEdit(text: text, selection: selection)
        case .inlineCode:
            return inlineCodeEdit(text: text, selection: selection)
        case .heading(let level):
            return headingEdit(text: text, selection: selection, level: level)
        case .bulletList:
            return listEdit(text: text, selection: selection, prefix: "- ")
        case .numberedList:
            return listEdit(text: text, selection: selection, prefix: "1. ")
        case .blockquote:
            return blockquoteEdit(text: text, selection: selection)
        case .codeBlock:
            return codeBlockEdit(text: text, selection: selection)
        case .toggleCheckbox:
            return toggleCheckboxEdit(text: text, selection: selection)
        case .indent:
            return indentEdit(text: text, selection: selection, outdent: false)
        case .outdent:
            return indentEdit(text: text, selection: selection, outdent: true)
        case .clearFormatting:
            return clearFormattingEdit(text: text, selection: selection)
        }
    }

    /// Whether `command` is already applied at `selection` (for menu on/off state).
    static func isActive(_ command: MarkdownFormattingCommand, text: String, selection: NSRange) -> Bool {
        let ns = text as NSString
        switch command {
        case .bold:
            return enclosingToken(text: text, selection: selection, kinds: [.bold, .boldItalic]) != nil
        case .italic:
            return enclosingToken(text: text, selection: selection, kinds: [.italic, .boldItalic]) != nil
        case .strikethrough:
            return enclosingToken(text: text, selection: selection, kinds: [.strikethrough]) != nil
        case .inlineCode:
            return enclosingToken(text: text, selection: selection, kinds: [.inlineCode]) != nil
        case .clearFormatting:
            // An action, never an "on" state; enabled iff there's inline emphasis to clear.
            return false
        case .heading(let level):
            let line = ns.substring(with: ns.lineRange(for: selection)).trimmingCharacters(in: .whitespacesAndNewlines)
            return line.hasPrefix(String(repeating: "#", count: level) + " ")
        case .bulletList:
            let line = ns.substring(with: ns.lineRange(for: selection))
            return line.range(of: bulletLinePattern, options: .regularExpression) != nil
        case .numberedList:
            let line = ns.substring(with: ns.lineRange(for: selection))
            return line.range(of: orderedLinePattern, options: .regularExpression) != nil
        case .blockquote:
            let line = ns.substring(with: ns.lineRange(for: selection))
            return isBlockquoteLine(line)
        case .codeBlock:
            return enclosingToken(text: text, selection: selection, kinds: [.codeBlock]) != nil
        case .toggleCheckbox:
            // "On" == the line is a CHECKED task (menu checkmark / toolbar highlight).
            let line = ns.substring(with: ns.lineRange(for: selection)).trimmingCharacters(in: .newlines)
            return isCheckedTaskLine(line)
        case .indent, .outdent:
            return false   // actions, never an "on" state
        }
    }

    /// The active formatting at `selection`, for a host toolbar. Uses `tokens` (the view's
    /// already-parsed cache) for the bold/italic check so it doesn't re-tokenize on every
    /// caret move; heading/list are cheap line-prefix checks.
    static func selectionState(text: String, selection: NSRange, tokens: [MarkdownToken]) -> MarkdownSelectionState {
        let ns = text as NSString
        let isBold = tokens.contains { ($0.kind == .bold || $0.kind == .boldItalic) && enclosesSelection($0.range, selection) }
        let isItalic = tokens.contains { ($0.kind == .italic || $0.kind == .boldItalic) && enclosesSelection($0.range, selection) }
        let isStrikethrough = tokens.contains { $0.kind == .strikethrough && enclosesSelection($0.range, selection) }
        let isInlineCode = tokens.contains { $0.kind == .inlineCode && enclosesSelection($0.range, selection) }

        let line = ns.substring(with: ns.lineRange(for: selection))
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let headingLevel = (1...6).first { trimmed.hasPrefix(String(repeating: "#", count: $0) + " ") }
        let isBulletList = line.range(of: bulletLinePattern, options: .regularExpression) != nil
        let isNumberedList = line.range(of: orderedLinePattern, options: .regularExpression) != nil
        let isBlockquote = isBlockquoteLine(line)
        let isCodeBlock = tokens.contains { $0.kind == .codeBlock && enclosesSelection($0.range, selection) }
        let isChecked = isCheckedTaskLine(trimmed)

        return MarkdownSelectionState(
            isBold: isBold, isItalic: isItalic,
            isStrikethrough: isStrikethrough, isInlineCode: isInlineCode,
            headingLevel: headingLevel,
            isBulletList: isBulletList, isNumberedList: isNumberedList,
            isBlockquote: isBlockquote, isCodeBlock: isCodeBlock,
            isChecked: isChecked
        )
    }

    // MARK: - Inline emphasis (bold / italic / strikethrough / inline-code)

    private static func enclosesSelection(_ tokenRange: NSRange, _ selection: NSRange) -> Bool {
        selection.location >= tokenRange.location && NSMaxRange(selection) <= NSMaxRange(tokenRange)
    }

    /// The first token of one of `kinds` that fully encloses `selection`, if any.
    private static func enclosingToken(text: String, selection: NSRange, kinds: Set<MarkdownTokenKind>) -> MarkdownToken? {
        MarkdownTokenizer.parseTokensViaAST(in: text).first {
            kinds.contains($0.kind) && enclosesSelection($0.range, selection)
        }
    }

    /// Bold / italic: nests with the shared `*` runs, so toggling off a `boldItalic` token
    /// leaves the other marker (`boldItalicResidual`) behind.
    private static func emphasisEdit(
        text: String, selection: NSRange, marker: String,
        single: MarkdownTokenKind, boldItalicResidual: String
    ) -> FormattingEdit {
        let ns = text as NSString
        if let token = enclosingToken(text: text, selection: selection, kinds: [single, .boldItalic]) {
            let residual = token.kind == .boldItalic ? boldItalicResidual : ""
            return toggleOffEdit(ns: ns, token: token, residual: residual)
        }
        return wrapOrInsertEdit(ns: ns, selection: selection, marker: marker)
    }

    /// Strikethrough is a symmetric `~~` wrap. The GFM scanner won't form a span when the content
    /// contains a tilde (even backslash-escaped) OR when the selection abuts a literal tilde in the
    /// surrounding text (`~~~foo~~` is an unbalanced run). Rather than enumerate those cases, the
    /// wrap is `verified`: if the proposed markup doesn't parse back to a strikethrough span we
    /// refuse it (identity edit → a clean no-op via each platform's identity guard). Toggle-off and
    /// empty-insert are unaffected.
    private static func strikethroughEdit(text: String, selection: NSRange) -> FormattingEdit {
        let ns = text as NSString
        if let token = enclosingToken(text: text, selection: selection, kinds: [.strikethrough]) {
            return toggleOffEdit(ns: ns, token: token, residual: "")
        }
        let edit = wrapOrInsertEdit(ns: ns, selection: selection, marker: "~~")
        // An empty-selection insert (`~~~~` with the caret between) intentionally has no content to
        // parse — skip verification, which would otherwise reject it.
        guard selection.length > 0 else { return edit }
        return verifiedWrap(edit, formsKind: .strikethrough, in: text, selection: selection)
    }

    /// Inline code differs from a plain symmetric wrap: per CommonMark a code span's delimiter must
    /// be a backtick run LONGER than any run inside the content, otherwise the inner run closes the
    /// span early. So the wrap picks a fence of `maxInnerRun + 1` backticks and pads with a space
    /// when the core abuts a backtick (the renderer strips one leading+trailing space symmetrically).
    /// A literal backtick immediately OUTSIDE the selection still merges with the fence into one run,
    /// which the `verified` re-parse catches → no-op. Toggle-off and empty-insert match the others.
    private static func inlineCodeEdit(text: String, selection: NSRange) -> FormattingEdit {
        let ns = text as NSString
        if let token = enclosingToken(text: text, selection: selection, kinds: [.inlineCode]) {
            return toggleOffEdit(ns: ns, token: token, residual: "")
        }
        if selection.length == 0 {
            return wrapOrInsertEdit(ns: ns, selection: selection, marker: "`")
        }

        let (leading, core, trailing) = splitEdgeWhitespace(ns.substring(with: selection))
        let fence = backtickFence(enclosing: core)
        let pad = (core.hasPrefix("`") || core.hasSuffix("`")) ? " " : ""
        let newText = leading + fence + pad + core + pad + fence + trailing
        let location = selection.location
            + (leading as NSString).length + (fence as NSString).length + (pad as NSString).length
        let edit = FormattingEdit(
            range: selection, text: newText,
            selection: NSRange(location: location, length: (core as NSString).length)
        )
        return verifiedWrap(edit, formsKind: .inlineCode, in: text, selection: selection)
    }

    /// Apply `edit` to `text` and confirm a token of `formsKind` now encloses the wrapped content
    /// (`edit.selection`). If the parser won't form that span — an unescapable inner char, a fence
    /// that merges with a neighboring delimiter run, or any other quirk — refuse the edit and
    /// return an identity no-op rather than leave visible, unparseable markers in the document.
    private static func verifiedWrap(
        _ edit: FormattingEdit, formsKind: MarkdownTokenKind, in text: String, selection: NSRange
    ) -> FormattingEdit {
        let ns = text as NSString
        let applied = ns.replacingCharacters(in: edit.range, with: edit.text)
        let formed = MarkdownTokenizer.parseTokensViaAST(in: applied).contains {
            $0.kind == formsKind && enclosesSelection($0.range, edit.selection)
        }
        return formed ? edit : FormattingEdit(range: selection, text: ns.substring(with: selection), selection: selection)
    }

    /// The shortest backtick run that can fence `content` without an inner run closing it early
    /// (one longer than the longest backtick run inside).
    private static func backtickFence(enclosing content: String) -> String {
        var longest = 0, current = 0
        for character in content {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return String(repeating: "`", count: longest + 1)
    }

    /// Replace an enclosing emphasis token with `residual` + content + `residual`,
    /// selecting the residual-wrapped content.
    private static func toggleOffEdit(ns: NSString, token: MarkdownToken, residual: String) -> FormattingEdit {
        let content = ns.substring(with: token.contentRange)
        let newText = residual + content + residual
        let location = token.range.location + (residual as NSString).length
        return FormattingEdit(
            range: token.range, text: newText,
            selection: NSRange(location: location, length: (content as NSString).length)
        )
    }

    /// Apply `marker` to `selection`: an empty selection inserts the markers with the caret
    /// between them; a non-empty selection wraps it, keeping edge whitespace outside.
    private static func wrapOrInsertEdit(ns: NSString, selection: NSRange, marker: String) -> FormattingEdit {
        if selection.length == 0 {
            return FormattingEdit(
                range: selection, text: marker + marker,
                selection: NSRange(location: selection.location + (marker as NSString).length, length: 0)
            )
        }

        let (leading, core, trailing) = splitEdgeWhitespace(ns.substring(with: selection))
        let newText = leading + marker + core + marker + trailing
        let location = selection.location + (leading as NSString).length + (marker as NSString).length
        return FormattingEdit(
            range: selection, text: newText,
            selection: NSRange(location: location, length: (core as NSString).length)
        )
    }

    /// Split `s` into (leading whitespace, core, trailing whitespace) so a wrap can keep the
    /// edge whitespace outside the markers. The trailing run is clamped so it never overlaps the
    /// leading one — without this, an all-whitespace `s` counts the same run on both ends and the
    /// wrap would duplicate it (e.g. "   " → "   ****   ").
    private static func splitEdgeWhitespace(_ s: String) -> (leading: String, core: String, trailing: String) {
        let leadingCount = s.prefix { $0.isWhitespace }.count
        let trailingCount = min(s.reversed().prefix { $0.isWhitespace }.count, s.count - leadingCount)
        let leading = String(s.prefix(leadingCount))
        let trailing = String(s.suffix(trailingCount))
        let coreStart = s.index(s.startIndex, offsetBy: leadingCount)
        let coreEnd = s.index(s.endIndex, offsetBy: -trailingCount)
        let core = coreStart <= coreEnd ? String(s[coreStart..<coreEnd]) : ""
        return (leading, core, trailing)
    }

    // MARK: - Clear formatting

    /// Inline-emphasis kinds whose markers `clearFormatting` strips.
    private static let inlineEmphasisKinds: Set<MarkdownTokenKind> =
        [.bold, .italic, .boldItalic, .strikethrough, .inlineCode]

    /// Remove the syntax of every inline-emphasis token that touches `selection`, leaving the
    /// content. Operates over the union of the affected tokens (so a caret inside a single span,
    /// or a selection straddling several, both clear cleanly). A no-op when nothing is emphasized.
    private static func clearFormattingEdit(text: String, selection: NSRange) -> FormattingEdit {
        let ns = text as NSString
        let affected = MarkdownTokenizer.parseTokensViaAST(in: text).filter {
            inlineEmphasisKinds.contains($0.kind) && tokenTouches($0.range, selection)
        }
        guard !affected.isEmpty else {
            // Nothing to clear → identity edit (leave text and selection unchanged).
            return FormattingEdit(range: selection, text: ns.substring(with: selection), selection: selection)
        }

        let start = affected.map(\.range.location).min()!
        let end = affected.map { NSMaxRange($0.range) }.max()!
        let unionRange = NSRange(location: start, length: end - start)

        // Each affected token contributes disjoint replacements within the union:
        //  - inline code: replace the WHOLE span with its content, backslash-escaped — the former
        //    code text may itself be Markdown (e.g. `*x*`, or a bare backtick from a padded span),
        //    so escaping keeps it inert plain text instead of re-forming emphasis on the next parse;
        //  - other emphasis: delete the non-content runs (markers + any padding), keeping the inner
        //    content (and any nested tokens, which are handled by their own entries).
        var replacements: [(range: NSRange, text: String)] = []
        for token in affected {
            if token.kind == .inlineCode {
                replacements.append((token.range, escapingInlineDelimiters(ns.substring(with: token.contentRange))))
            } else {
                for run in nonContentRuns(of: token) { replacements.append((run, "")) }
            }
        }

        // Apply descending by location so earlier edits don't shift later offsets; dedup guards a
        // future parser reporting a shared run, and the bounds check guards overlap (today's AST
        // emits only disjoint runs) so a bad range skips instead of crashing.
        var seen = Set<String>()
        let ordered = replacements
            .filter { seen.insert("\($0.range.location):\($0.range.length)").inserted }
            .sorted { $0.range.location > $1.range.location }
        let mutable = NSMutableString(string: ns.substring(with: unionRange))
        for replacement in ordered {
            let relative = NSRange(
                location: replacement.range.location - unionRange.location, length: replacement.range.length
            )
            guard relative.location >= 0, NSMaxRange(relative) <= mutable.length else { continue }
            mutable.replaceCharacters(in: relative, with: replacement.text)
        }
        let cleared = mutable as String
        return FormattingEdit(
            range: unionRange, text: cleared,
            selection: NSRange(location: unionRange.location, length: (cleared as NSString).length)
        )
    }

    /// ASCII delimiters that can (re)start an inline construct in this engine; backslash-escaping
    /// them renders the literal character, so former inline-code content stays inert plain text.
    /// (`\` first so an escape we add isn't itself re-interpreted; `<` guards autolinks/raw HTML,
    /// `$` guards inline LaTeX, `[` covers links/wiki-links/images.)
    private static let inlineDelimitersToEscape: Set<Character> = ["\\", "`", "*", "_", "~", "[", "]", "<", "$"]

    private static func escapingInlineDelimiters(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for character in s {
            if inlineDelimitersToEscape.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// The parts of `token.range` not covered by `token.contentRange` — the markers, plus any
    /// syntactic padding (e.g. inline-code's CommonMark space padding). Deleting these leaves
    /// exactly the rendered content. `contentRange` is a single contiguous span inside `range`,
    /// so there are at most a leading and a trailing run.
    private static func nonContentRuns(of token: MarkdownToken) -> [NSRange] {
        let range = token.range, content = token.contentRange
        var runs: [NSRange] = []
        if content.location > range.location {
            runs.append(NSRange(location: range.location, length: content.location - range.location))
        }
        let contentEnd = NSMaxRange(content), rangeEnd = NSMaxRange(range)
        if rangeEnd > contentEnd {
            runs.append(NSRange(location: contentEnd, length: rangeEnd - contentEnd))
        }
        return runs
    }

    /// Whether `tokenRange` overlaps `selection`, or contains a zero-length caret selection.
    private static func tokenTouches(_ tokenRange: NSRange, _ selection: NSRange) -> Bool {
        if NSIntersectionRange(tokenRange, selection).length > 0 { return true }
        return enclosesSelection(tokenRange, selection)
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

    // MARK: - Blockquote

    /// One level of blockquote marker at a line start: up to 3 leading spaces/tabs, a `>`, and an
    /// optional single following space/tab — matching the block tokenizer's marker scan
    /// (`BlockLevelTokenizer`, legacy `^[ \t]{0,3}((?:>[ \t]?)+)`). Detection and the toggle both
    /// use this so they agree with how the line actually renders (incl. indented/imported quotes).
    private static let blockquoteMarkerPattern = #"^[ \t]{0,3}>[ \t]?"#

    private static func isBlockquoteLine(_ line: String) -> Bool {
        line.range(of: blockquoteMarkerPattern, options: .regularExpression) != nil
    }

    /// Toggle a `> ` prefix on the caret's line (single-line, matching the list/heading
    /// convention). Toggling off removes ONE level of quoting (`>> x` → `> x`, `> x` → `x`,
    /// `   > x` → `x`).
    private static func blockquoteEdit(text: String, selection: NSRange) -> FormattingEdit {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        let (lineText, suffix) = splitLineTerminator(lineRange, in: ns)

        let newLine: String         // full replacement line (sans the preserved newline)
        let visibleStart: Int       // where the non-marker text begins, to select like list/heading
        let visibleText: String
        if let marker = lineText.range(of: blockquoteMarkerPattern, options: .regularExpression) {
            visibleText = String(lineText[marker.upperBound...])   // toggle off one level
            newLine = visibleText
            visibleStart = lineRange.location
        } else {
            visibleText = lineText                                 // apply
            newLine = "> " + lineText
            visibleStart = lineRange.location + 2
        }
        return FormattingEdit(
            range: lineRange, text: newLine + suffix,
            selection: NSRange(location: visibleStart, length: (visibleText as NSString).length)
        )
    }

    // MARK: - Code block (fenced)

    /// Wrap the selection's line(s) in a ``` fence, or unwrap when the caret is already inside a
    /// fenced block. This engine's block tokenizer closes a fence on ANY line that starts with
    /// three backticks (it ignores CommonMark's longer-fence rule), so a body that itself contains
    /// a ``` line can't be fenced cleanly — `verifiedWrap` catches that and makes it a no-op rather
    /// than emit a block that closes early.
    private static func codeBlockEdit(text: String, selection: NSRange) -> FormattingEdit {
        let ns = text as NSString

        // Toggle off: caret inside an existing fenced block → replace the whole block with its
        // code, dropping the line terminator that preceded the closing fence.
        if let token = enclosingToken(text: text, selection: selection, kinds: [.codeBlock]) {
            let terminator = trailingLineTerminatorLength(of: token.contentRange, in: ns)
            let innerRange = NSRange(location: token.contentRange.location, length: token.contentRange.length - terminator)
            let inner = ns.substring(with: innerRange)
            return FormattingEdit(
                range: token.range, text: inner,
                selection: NSRange(location: token.range.location, length: (inner as NSString).length)
            )
        }

        let lineRange = ns.lineRange(for: selection)
        // Split off the line's terminator (LF / CR / CRLF) so it's preserved after the closing
        // fence rather than embedded in the fenced body.
        let terminator = trailingLineTerminatorLength(of: lineRange, in: ns)
        let bodyRange = NSRange(location: lineRange.location, length: lineRange.length - terminator)
        let body = ns.substring(with: bodyRange)
        let trailingNewline = terminator > 0 ? ns.substring(with: NSRange(location: NSMaxRange(bodyRange), length: terminator)) : ""
        let newText = "```\n" + body + "\n```" + trailingNewline
        let location = lineRange.location + 4   // after "```\n"
        let edit = FormattingEdit(
            range: lineRange, text: newText,
            selection: NSRange(location: location, length: (body as NSString).length)
        )
        // An empty body is an intentional empty-block insert (caret on the blank line) — the parser
        // won't form a token over nothing, so skip verification there.
        guard !body.isEmpty else { return edit }
        return verifiedWrap(edit, formsKind: .codeBlock, in: text, selection: selection)
    }

    /// The UTF-16 length (0, 1, or 2) of the line terminator at the end of `range` in `ns` — a
    /// CRLF pair, or a lone LF/CR. Lets terminator handling work on CR/CRLF documents, not just LF.
    private static func trailingLineTerminatorLength(of range: NSRange, in ns: NSString) -> Int {
        let end = NSMaxRange(range)
        guard end > range.location else { return 0 }
        if range.length >= 2, ns.character(at: end - 2) == 0x0D, ns.character(at: end - 1) == 0x0A { return 2 }
        let last = ns.character(at: end - 1)
        return (last == 0x0A || last == 0x0D) ? 1 : 0
    }

    /// Split a line range into (content, original terminator). The line-prefix commands rebuild a
    /// line and re-append its terminator — using the EXACT original (CRLF/CR/LF) instead of a hard
    /// `\n` so they don't rewrite or drop line endings on non-LF documents.
    private static func splitLineTerminator(_ lineRange: NSRange, in ns: NSString) -> (line: String, terminator: String) {
        let terminatorLength = trailingLineTerminatorLength(of: lineRange, in: ns)
        let line = ns.substring(with: NSRange(location: lineRange.location, length: lineRange.length - terminatorLength))
        let terminator = terminatorLength > 0
            ? ns.substring(with: NSRange(location: NSMaxRange(lineRange) - terminatorLength, length: terminatorLength))
            : ""
        return (line, terminator)
    }

    // MARK: - List marker patterns (shared by detection + the list-structure commands)

    // Mirrors the AST's `listItem` (MarkdownAST.swift) — the source of truth for what becomes a
    // list/task node: leading spaces/tabs, then a bullet `-*+` or an ordered `N` (≤ 9 digits) ended
    // by `.` or `)`, then a space OR tab separator. NOTE: `•` is deliberately excluded — it's a
    // render-time glyph painted over a hidden `-`/`*`/`+`, never a source marker the AST recognizes,
    // so emitting `• [ ]` would never style as a task.
    /// A bullet line.
    static let bulletLinePattern = #"^[ \t]*[-*+][ \t]"#
    /// An ordered line (`N.` or `N)`, ≤ 9 digits — a 10+-digit run renders as plain text).
    static let orderedLinePattern = #"^[ \t]*\d{1,9}[.)][ \t]"#
    /// Any list marker (bullet or ordered) at line start.
    private static let listMarkerPrefix = #"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]"#

    /// A list line whose marker is immediately followed by a `[ ]`/`[x]`/`[X]` box (the engine
    /// accepts upper- or lower-case x as checked).
    private static func isTaskLine(_ line: String) -> Bool {
        line.range(of: #"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]\[[ xX]\]"#, options: .regularExpression) != nil
    }

    private static func isCheckedTaskLine(_ line: String) -> Bool {
        line.range(of: #"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]\[[xX]\]"#, options: .regularExpression) != nil
    }

    /// Toggle a task checkbox on the caret's line. An existing task line flips `[ ]`↔`[x]`
    /// (length-preserving, lowercase `x` on check — matching the tap-toggle); a bullet line gains
    /// a `[ ] ` after its marker; a plain line becomes `- [ ] …`.
    private static func toggleCheckboxEdit(text: String, selection: NSRange) -> FormattingEdit {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        let (lineText, suffix) = splitLineTerminator(lineRange, in: ns)

        // 1) Existing task line → flip the box. Length-preserving, so the caret stays valid.
        if let box = lineText.range(of: #"\[[ xX]\]"#, options: .regularExpression),
           isTaskLine(lineText) {
            let isChecked = lineText[box].contains("x") || lineText[box].contains("X")
            var newLine = lineText
            newLine.replaceSubrange(box, with: isChecked ? "[ ]" : "[x]")
            return FormattingEdit(range: lineRange, text: newLine + suffix, selection: selection)
        }

        // 2) List line without a box (bullet or numbered) → insert "[ ] " after the marker.
        if let marker = lineText.range(of: listMarkerPrefix, options: .regularExpression) {
            let head = String(lineText[..<marker.upperBound])
            let visible = String(lineText[marker.upperBound...])
            let newLine = head + "[ ] " + visible
            let visibleStart = lineRange.location + (head as NSString).length + 4   // after "[ ] "
            return FormattingEdit(
                range: lineRange, text: newLine + suffix,
                selection: NSRange(location: visibleStart, length: (visible as NSString).length)
            )
        }

        // 3) Plain line → make it an unchecked task item.
        let newLine = "- [ ] " + lineText
        return FormattingEdit(
            range: lineRange, text: newLine + suffix,
            selection: NSRange(location: lineRange.location + 6, length: (lineText as NSString).length)   // after "- [ ] "
        )
    }

    // MARK: - Indent / outdent (list lines)

    /// A bullet/numbered/checkbox list line (optionally already indented).
    private static func isListItemLine(_ line: String) -> Bool {
        line.range(of: listMarkerPrefix, options: .regularExpression) != nil
    }

    /// Indent (prepend a tab) or outdent (strip one leading tab / up to 2 spaces — the engine's
    /// "1 tab or 2 spaces = 1 level") the caret's list line. A no-op off a list line, and outdent
    /// is a no-op at the root (no leading whitespace). The caret tracks the shift.
    private static func indentEdit(text: String, selection: NSRange, outdent: Bool) -> FormattingEdit {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        let (lineText, suffix) = splitLineTerminator(lineRange, in: ns)

        let identity = FormattingEdit(range: selection, text: ns.substring(with: selection), selection: selection)
        guard isListItemLine(lineText) else { return identity }

        if outdent {
            let removed: Int
            if lineText.hasPrefix("\t") { removed = 1 }
            else if lineText.hasPrefix("  ") { removed = 2 }
            else if lineText.hasPrefix(" ") { removed = 1 }
            else { return identity }                       // already at the root
            let newLine = String(lineText.dropFirst(removed))
            // Map both selection ends left past the removed indent (clamped to the line start), so a
            // selection that covered the stripped whitespace shrinks instead of running out of range.
            let newStart = max(lineRange.location, selection.location - removed)
            let newEnd = max(lineRange.location, NSMaxRange(selection) - removed)
            return FormattingEdit(
                range: lineRange, text: newLine + suffix,
                selection: NSRange(location: newStart, length: newEnd - newStart)
            )
        }

        let newLine = "\t" + lineText
        return FormattingEdit(
            range: lineRange, text: newLine + suffix,
            selection: NSRange(location: selection.location + 1, length: selection.length)   // tab shifts caret +1
        )
    }
}
