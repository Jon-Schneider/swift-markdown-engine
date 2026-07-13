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

    private static let composableInlineKinds: Set<MarkdownTokenKind> = [
        .bold, .italic, .boldItalic, .strikethrough,
    ]

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
            return listEdit(text: text, selection: selection, prefix: "- ", ownPattern: bulletLinePattern)
        case .numberedList:
            return listEdit(text: text, selection: selection, prefix: "1. ", ownPattern: orderedLinePattern)
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
            return inlineFormattingIsActive(
                text: text, selection: selection,
                tokens: MarkdownTokenizer.parseTokensViaAST(in: text),
                kinds: [.bold, .boldItalic]
            )
        case .italic:
            return inlineFormattingIsActive(
                text: text, selection: selection,
                tokens: MarkdownTokenizer.parseTokensViaAST(in: text),
                kinds: [.italic, .boldItalic]
            )
        case .strikethrough:
            return inlineFormattingIsActive(
                text: text, selection: selection,
                tokens: MarkdownTokenizer.parseTokensViaAST(in: text),
                kinds: [.strikethrough]
            )
        case .inlineCode:
            return enclosingToken(text: text, selection: selection, kinds: [.inlineCode]) != nil
        case .clearFormatting:
            // An action, never an "on" state; enabled iff there's inline emphasis to clear.
            return false
        case .heading(let level):
            return linesTouched(by: selection, in: ns).allSatisfy { headingLevel(in: $0.content) == level }
        case .bulletList:
            return linesTouched(by: selection, in: ns).allSatisfy {
                $0.content.range(of: bulletLinePattern, options: .regularExpression) != nil
            }
        case .numberedList:
            return linesTouched(by: selection, in: ns).allSatisfy {
                $0.content.range(of: orderedLinePattern, options: .regularExpression) != nil
            }
        case .blockquote:
            return linesTouched(by: selection, in: ns).allSatisfy { isBlockquoteLine($0.content) }
        case .codeBlock:
            return enclosingFencedCodeRange(text: text, selection: selection) != nil
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
        let isBold = inlineFormattingIsActive(
            text: text, selection: selection, tokens: tokens, kinds: [.bold, .boldItalic]
        )
        let isItalic = inlineFormattingIsActive(
            text: text, selection: selection, tokens: tokens, kinds: [.italic, .boldItalic]
        )
        let isStrikethrough = inlineFormattingIsActive(
            text: text, selection: selection, tokens: tokens, kinds: [.strikethrough]
        )
        let isInlineCode = tokens.contains { $0.kind == .inlineCode && enclosesSelection($0.range, selection) }

        let lines = linesTouched(by: selection, in: ns)
        let firstHeadingLevel = lines.first.flatMap { headingLevel(in: $0.content) }
        let selectedHeadingLevel = firstHeadingLevel.flatMap { level in
            lines.allSatisfy { headingLevel(in: $0.content) == level } ? level : nil
        }
        let isBulletList = lines.allSatisfy {
            $0.content.range(of: bulletLinePattern, options: .regularExpression) != nil
        }
        let isNumberedList = lines.allSatisfy {
            $0.content.range(of: orderedLinePattern, options: .regularExpression) != nil
        }
        let isBlockquote = lines.allSatisfy { isBlockquoteLine($0.content) }
        let isCodeBlock = tokens.contains { $0.kind == .codeBlock && enclosesSelection($0.range, selection) }
        let firstLine = lines[0].content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isChecked = isCheckedTaskLine(firstLine)

        return MarkdownSelectionState(
            isBold: isBold, isItalic: isItalic,
            isStrikethrough: isStrikethrough, isInlineCode: isInlineCode,
            headingLevel: selectedHeadingLevel,
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
        if selection.length == 0,
           let token = enclosingToken(text: text, selection: selection, kinds: [single, .boldItalic]) {
            let residual = token.kind == .boldItalic ? boldItalicResidual : ""
            return toggleOffEdit(ns: ns, token: token, residual: residual)
        }
        guard selection.length > 0 else {
            return wrapOrInsertEdit(ns: ns, selection: selection, marker: marker)
        }
        return aggregateInlineFormattingEdit(
            text: text, selection: selection, marker: marker,
            kinds: [single, .boldItalic], boldItalicResidual: boldItalicResidual
        )
    }

    /// Strikethrough is a symmetric `~~` wrap. The GFM scanner won't form a span when the content
    /// contains a tilde (even backslash-escaped) OR when the selection abuts a literal tilde in the
    /// surrounding text (`~~~foo~~` is an unbalanced run). Rather than enumerate those cases, the
    /// wrap is `verified`: if the proposed markup doesn't parse back to a strikethrough span we
    /// refuse it (identity edit → a clean no-op via each platform's identity guard). Toggle-off and
    /// empty-insert are unaffected.
    private static func strikethroughEdit(text: String, selection: NSRange) -> FormattingEdit {
        let ns = text as NSString
        if selection.length == 0,
           let token = enclosingToken(text: text, selection: selection, kinds: [.strikethrough]) {
            return toggleOffEdit(ns: ns, token: token, residual: "")
        }
        guard selection.length > 0 else {
            return wrapOrInsertEdit(ns: ns, selection: selection, marker: "~~")
        }
        return aggregateInlineFormattingEdit(
            text: text, selection: selection, marker: "~~",
            kinds: [.strikethrough], boldItalicResidual: ""
        )
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

    /// Apply one inline style across a ranged selection using aggregate toggle semantics. Inline
    /// emphasis cannot cross a physical newline in this engine, so each selected line segment gets
    /// its own marker pair. Existing matching tokens cover their visible content; only uncovered
    /// runs gain markers unless every visible selected character is already covered, in which case
    /// all matching tokens touched by the selection lose that style together.
    private static func aggregateInlineFormattingEdit(
        text: String,
        selection: NSRange,
        marker: String,
        kinds: Set<MarkdownTokenKind>,
        boldItalicResidual: String
    ) -> FormattingEdit {
        let ns = text as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let segments = inlineSelectionSegments(selection, in: ns, tokens: tokens)
        let rawSyntaxRanges = inlineSyntaxRanges(selection: selection, in: ns, tokens: tokens)
        let syntaxRanges = mergedRanges(rawSyntaxRanges)
        let visibilityRanges = mergedRanges(
            syntaxRanges + tokens
                .filter { $0.kind == .backslashEscape }
                .flatMap { nonContentRuns(of: $0) }
        )
        guard let visibleBounds = visibleSelectionBounds(
            segments: segments, in: ns, syntaxRanges: visibilityRanges
        ) else {
            if segments.contains(where: { segment in
                syntaxRanges.contains { NSIntersectionRange(segment, $0).length > 0 }
            }) {
                return FormattingEdit(
                    range: selection,
                    text: ns.substring(with: selection),
                    selection: selection
                )
            }
            // Preserve the established empty/all-whitespace behavior (insert a marker pair after
            // the whitespace) rather than treating a selection with no visible glyphs as "all on".
            return wrapOrInsertEdit(ns: ns, selection: selection, marker: marker)
        }

        let matchingTokens = tokens.filter { kinds.contains($0.kind) }
        if inlineFormattingIsActive(
            text: text, selection: selection, tokens: tokens, kinds: kinds
        ) {
            var mutations: [(range: NSRange, text: String)] = []
            for token in matchingTokens {
                let residual = token.kind == .boldItalic ? boldItalicResidual : ""
                mutations.append(contentsOf: inlineRemovalMutations(
                    token: token,
                    segments: segments,
                    syntaxRanges: syntaxRanges,
                    tokens: tokens,
                    kinds: kinds,
                    ns: ns,
                    marker: marker,
                    residual: residual
                ))
            }
            let edit = inlineMutationEdit(
                in: ns, selection: selection, visibleBounds: visibleBounds, mutations: mutations
            )
            let applied = ns.replacingCharacters(in: edit.range, with: edit.text)
            let appliedTokens = MarkdownTokenizer.parseTokensViaAST(in: applied)
            guard !inlineFormattingIsActive(
                text: applied, selection: edit.selection, tokens: appliedTokens, kinds: kinds
            ) else {
                return FormattingEdit(
                    range: selection,
                    text: ns.substring(with: selection),
                    selection: selection
                )
            }
            return edit
        }

        // Matching tokens are already styled and therefore block their whole source ranges. Every
        // token's non-content syntax is also blocked so a heading/list/link/emphasis marker stays
        // outside the new marker pair; the selected visible text inside it is formatted instead.
        // A different emphasis style is valid nested content for this command. Let the new marker
        // wrap its source delimiters as part of one contiguous run; treating those delimiters as
        // blockers creates adjacent star runs such as `***hel****lo*` that cannot be parsed reliably.
        let composableMarkerRanges = tokens
            .filter { composableInlineKinds.contains($0.kind) && !kinds.contains($0.kind) }
            .flatMap { nonContentRuns(of: $0) }
        let applicationSyntaxRanges = mergedRanges(rawSyntaxRanges.filter { syntaxRange in
            !composableMarkerRanges.contains(where: { $0 == syntaxRange })
        })
        let blockedRanges = matchingTokens.map(\.range) + applicationSyntaxRanges
        let uncovered = uncoveredInlineRanges(segments: segments, blockedRanges: blockedRanges, in: ns)
        let mutations = inlineApplicationMutations(
            uncoveredRanges: uncovered,
            matchingTokens: matchingTokens,
            marker: marker
        )
        guard !mutations.isEmpty else {
            return FormattingEdit(range: selection, text: ns.substring(with: selection), selection: selection)
        }

        let edit = inlineMutationEdit(
            in: ns, selection: selection, visibleBounds: visibleBounds, mutations: mutations
        )
        let applied = ns.replacingCharacters(in: edit.range, with: edit.text)
        let appliedTokens = MarkdownTokenizer.parseTokensViaAST(in: applied)
        guard inlineFormattingIsActive(
            text: applied, selection: edit.selection, tokens: appliedTokens, kinds: kinds
        ) else {
            // Refuse any delimiter combination the parser cannot represent rather than persist raw,
            // visible Markdown markers (for example a strike containing a literal tilde).
            return FormattingEdit(range: selection, text: ns.substring(with: selection), selection: selection)
        }
        return edit
    }

    /// Selected non-terminator portions of each physical line, with edge whitespace excluded so
    /// formatting keeps it outside the inserted delimiters just like the established single-line
    /// path. A selection of an escaped character expands backward over its hidden backslash so new
    /// delimiters wrap the escape pair instead of splitting it.
    private static func inlineSelectionSegments(
        _ selection: NSRange,
        in ns: NSString,
        tokens: [MarkdownToken]
    ) -> [NSRange] {
        guard selection.length > 0 else { return [] }
        return linesTouched(by: selection, in: ns).compactMap { line in
            let contentRange = NSRange(
                location: line.range.location,
                length: (line.content as NSString).length
            )
            var intersection = NSIntersectionRange(selection, contentRange)
            guard intersection.length > 0 else { return nil }
            for escape in tokens where escape.kind == .backslashEscape
                && NSIntersectionRange(intersection, escape.range).length > 0 {
                intersection = NSIntersectionRange(NSUnionRange(intersection, escape.range), contentRange)
            }
            let selectedText = ns.substring(with: intersection)
            let (leading, core, _) = splitEdgeWhitespace(selectedText)
            let coreLength = (core as NSString).length
            guard coreLength > 0 else { return nil }
            return NSRange(
                location: intersection.location + (leading as NSString).length,
                length: coreLength
            )
        }
    }

    private static func inlineFormattingIsActive(
        text: String,
        selection: NSRange,
        tokens: [MarkdownToken],
        kinds: Set<MarkdownTokenKind>
    ) -> Bool {
        if selection.length == 0 {
            return tokens.contains { kinds.contains($0.kind) && enclosesSelection($0.range, selection) }
        }

        let ns = text as NSString
        let segments = inlineSelectionSegments(selection, in: ns, tokens: tokens)
        let syntaxRanges = mergedRanges(
            inlineSyntaxRanges(selection: selection, in: ns, tokens: tokens)
        )
        let visibilityRanges = mergedRanges(
            syntaxRanges + tokens
                .filter { $0.kind == .backslashEscape }
                .flatMap { nonContentRuns(of: $0) }
        )
        guard visibleSelectionBounds(segments: segments, in: ns, syntaxRanges: visibilityRanges) != nil else {
            return false
        }
        let styledRanges = mergedRanges(tokens.filter { kinds.contains($0.kind) }.map(\.range))
        for segment in segments {
            for location in segment.location..<NSMaxRange(segment) {
                if isInvisibleInlineSource(
                    at: location, in: ns, syntaxRanges: visibilityRanges
                ) {
                    continue
                }
                guard ranges(styledRanges, contain: location) else {
                    return false
                }
            }
        }
        return true
    }

    /// Syntax that should stay outside newly inserted inline delimiters. Token marker ranges cover
    /// parsed inline/heading/quote constructs; list markers are added explicitly because the list
    /// block token represents the whole item rather than exposing its source prefix as a token marker.
    private static func inlineSyntaxRanges(
        selection: NSRange,
        in ns: NSString,
        tokens: [MarkdownToken]
    ) -> [NSRange] {
        // An escape's backslash and escaped character are one visible source unit for formatting:
        // wrapping the pair yields `**\***`-style markup, while treating the slash as syntax would
        // insert the opening delimiter between them and create an invalid escape. Other token markers
        // remain protected from inline delimiters.
        var ranges = tokens
            .filter { $0.kind != .backslashEscape }
            .flatMap { nonContentRuns(of: $0) }
        ranges.append(contentsOf: opaqueInlineRanges(in: ns, tokens: tokens))
        ranges.append(contentsOf: tableSyntaxRanges(in: ns, tokens: tokens))
        for line in linesTouched(by: selection, in: ns) {
            var remaining = line.content
            var consumed = 0
            var foundMarker = true
            while foundMarker {
                foundMarker = false
                for pattern in blockMarkerPatterns {
                    guard let marker = remaining.range(of: pattern, options: .regularExpression) else { continue }
                    let markerLength = (String(remaining[..<marker.upperBound]) as NSString).length
                    ranges.append(NSRange(
                        location: line.range.location + consumed,
                        length: markerLength
                    ))
                    consumed += markerLength
                    remaining = String(remaining[marker.upperBound...])

                    if pattern == bulletLinePattern || pattern == orderedLinePattern,
                       let taskBox = remaining.range(of: leadingTaskBoxPattern, options: .regularExpression) {
                        let taskBoxLength = (String(remaining[..<taskBox.upperBound]) as NSString).length
                        ranges.append(NSRange(
                            location: line.range.location + consumed,
                            length: taskBoxLength
                        ))
                        consumed += taskBoxLength
                        remaining = String(remaining[taskBox.upperBound...])
                    }
                    foundMarker = true
                    break
                }
            }
        }
        return ranges
    }

    /// Constructs whose source cannot contain emphasis without changing meaning or becoming invalid.
    /// Their complete ranges are invisible to aggregate state and unavailable for mutations, so a
    /// multiline command still formats eligible prose before and after them.
    private static func opaqueInlineRanges(
        in ns: NSString,
        tokens: [MarkdownToken]
    ) -> [NSRange] {
        let opaqueTokenKinds: Set<MarkdownTokenKind> = [
            .inlineCode, .inlineLatex, .wikiLink, .imageEmbed, .imageLink,
        ]
        var ranges = tokens.compactMap { token in
            opaqueTokenKinds.contains(token.kind) ? token.range : nil
        }
        ranges.append(contentsOf: BlockParser.parse(ns as String).compactMap { block in
            switch block.kind {
            case .fencedCode, .blockLatex, .thematicBreak:
                return block.range
            default:
                return nil
            }
        })
        return ranges
    }

    /// First and one-past-last visible UTF-16 positions in the selected line segments. Syntax
    /// markers and whitespace do not carry a visible text style, so they do not influence aggregate
    /// state or the restored native selection.
    private static func visibleSelectionBounds(
        segments: [NSRange],
        in ns: NSString,
        syntaxRanges: [NSRange]
    ) -> (start: Int, end: Int)? {
        var start: Int?
        var end: Int?
        for segment in segments {
            for location in segment.location..<NSMaxRange(segment) where
                !isInvisibleInlineSource(at: location, in: ns, syntaxRanges: syntaxRanges) {
                if start == nil { start = location }
                end = location + 1
            }
        }
        guard let start, let end else { return nil }
        return (start: start, end: end)
    }

    private static func isInvisibleInlineSource(
        at location: Int,
        in ns: NSString,
        syntaxRanges: [NSRange]
    ) -> Bool {
        if ranges(syntaxRanges, contain: location) { return true }
        guard let scalar = UnicodeScalar(ns.character(at: location)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Remove the requested style only from the selected portion of a matching token. The original
    /// outer markers are removed, then the style is rebuilt around each unselected visible run. This
    /// keeps whitespace outside delimiters and places new markers inside nested link/emphasis syntax
    /// instead of splitting those constructs. Bold-italic selections get the residual style rebuilt
    /// around their selected runs as well.
    private static func inlineRemovalMutations(
        token: MarkdownToken,
        segments: [NSRange],
        syntaxRanges: [NSRange],
        tokens: [MarkdownToken],
        kinds: Set<MarkdownTokenKind>,
        ns: NSString,
        marker: String,
        residual: String
    ) -> [(range: NSRange, text: String)] {
        let selectedSegments = segments.compactMap { segment -> NSRange? in
            let intersection = NSIntersectionRange(segment, token.contentRange)
            return intersection.length > 0 ? intersection : nil
        }
        let selectedRanges = uncoveredInlineRanges(
            segments: selectedSegments,
            blockedRanges: syntaxRanges,
            in: ns
        )
        guard !selectedRanges.isEmpty else { return [] }

        let markerRuns = nonContentRuns(of: token)
        guard let openingMarker = markerRuns.first,
              let closingMarker = markerRuns.last,
              openingMarker != closingMarker else { return [] }

        let remainingRanges = uncoveredInlineRanges(
            segments: [token.contentRange],
            blockedRanges: syntaxRanges + selectedSegments,
            in: ns
        )
        let outerMarker = token.kind == .boldItalic ? marker + residual : marker
        let selectedMarker = token.kind == .boldItalic && !remainingRanges.isEmpty
            ? String(repeating: "_", count: (residual as NSString).length)
            : residual

        var openings: [Int: [String]] = [:]
        var closings: [Int: [String]] = [:]
        func rebuild(_ ranges: [NSRange], with marker: String) {
            guard !marker.isEmpty else { return }
            for range in ranges {
                openings[range.location, default: []].append(marker)
                closings[NSMaxRange(range), default: []].append(marker)
            }
        }
        rebuild(remainingRanges, with: outerMarker)
        rebuild(selectedRanges, with: selectedMarker)

        var mutations: [(range: NSRange, text: String)] = [
            (range: openingMarker, text: ""),
            (range: closingMarker, text: ""),
        ]
        // If rebuilding this style next to a nested `*`/`**` marker, the runs merge and change
        // delimiter matching. Normalize only nonmatching nested emphasis markers to equivalent
        // underscores when a new asterisk run actually touches that marker. Untouched intraword
        // `*bar*` must remain asterisks because `_bar_` would not parse between alphanumeric peers.
        func insertedAsteriskTouches(_ marker: NSRange) -> Bool {
            let boundaryTexts = openings[marker.location, default: []]
                + closings[marker.location, default: []]
                + openings[NSMaxRange(marker), default: []]
                + closings[NSMaxRange(marker), default: []]
            return boundaryTexts.contains { $0.contains("*") }
        }
        for nested in tokens where nested.range != token.range
            && enclosesSelection(token.contentRange, nested.range)
            && composableInlineKinds.contains(nested.kind)
            && !kinds.contains(nested.kind) {
            for nestedMarker in nonContentRuns(of: nested) {
                let source = ns.substring(with: nestedMarker)
                guard !source.isEmpty,
                      source.allSatisfy({ $0 == "*" }),
                      insertedAsteriskTouches(nestedMarker) else { continue }
                mutations.append((
                    range: nestedMarker,
                    text: String(repeating: "_", count: (source as NSString).length)
                ))
            }
        }
        for location in Set(openings.keys).union(closings.keys) {
            let text = closings[location, default: []].joined()
                + openings[location, default: []].joined()
            mutations.append((range: NSRange(location: location, length: 0), text: text))
        }
        return mutations
    }

    /// Table blocks are inline-bearing only inside their header/body cells. Pipes delimit cells and
    /// the second row defines column alignment, so inserting emphasis around either would turn the
    /// table into ordinary paragraphs. Protect those structural ranges while leaving cell text
    /// available to the aggregate inline formatter.
    private static func tableSyntaxRanges(
        in ns: NSString,
        tokens: [MarkdownToken]
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        let escapedPipeLocations = Set(tokens.compactMap { token -> Int? in
            guard token.kind == .backslashEscape,
                  token.contentRange.length == 1,
                  ns.character(at: token.contentRange.location) == 0x7C else { return nil }
            return token.contentRange.location
        })
        for table in tokens where table.kind == .table {
            var lineIndex = 0
            var location = table.range.location
            let tableEnd = NSMaxRange(table.range)
            while location < tableEnd {
                let physicalLine = ns.lineRange(for: NSRange(location: location, length: 0))
                let tableLine = NSIntersectionRange(physicalLine, table.range)
                guard tableLine.length > 0 else { break }

                if lineIndex == 1 {
                    ranges.append(tableLine)
                } else {
                    for pipeLocation in tableLine.location..<NSMaxRange(tableLine)
                    where ns.character(at: pipeLocation) == 0x7C
                        && !escapedPipeLocations.contains(pipeLocation) {
                        ranges.append(NSRange(location: pipeLocation, length: 1))
                    }
                }

                let nextLocation = NSMaxRange(physicalLine)
                guard nextLocation > location else { break }
                location = nextLocation
                lineIndex += 1
            }
        }
        return ranges
    }

    /// Source ranges that still need the requested style. Existing matching tokens and all syntax
    /// marker ranges partition each selected line; whitespace-only gaps are deliberately skipped.
    private static func uncoveredInlineRanges(
        segments: [NSRange],
        blockedRanges: [NSRange],
        in ns: NSString
    ) -> [NSRange] {
        var result: [NSRange] = []
        for segment in segments {
            let blockers = mergedRanges(blockedRanges.compactMap { blocked -> NSRange? in
                let intersection = NSIntersectionRange(segment, blocked)
                return intersection.length > 0 ? intersection : nil
            })
            var cursor = segment.location
            for blocker in blockers {
                appendVisibleInlineRange(
                    NSRange(location: cursor, length: blocker.location - cursor),
                    in: ns,
                    to: &result
                )
                cursor = max(cursor, NSMaxRange(blocker))
            }
            appendVisibleInlineRange(
                NSRange(location: cursor, length: NSMaxRange(segment) - cursor),
                in: ns,
                to: &result
            )
        }
        return result
    }

    /// Marker mutations for uncovered source runs. When a plain run directly touches an existing
    /// token of the exact requested style, move that token's boundary instead of emitting adjacent
    /// close/open runs (`**hel****lo**`); this keeps the stored Markdown compact as `**hello**`.
    /// Bold-italic tokens are not merged this way because their residual style must retain its own
    /// boundary when only bold or italic is being extended.
    private static func inlineApplicationMutations(
        uncoveredRanges: [NSRange],
        matchingTokens: [MarkdownToken],
        marker: String
    ) -> [(range: NSRange, text: String)] {
        var mutations: [(range: NSRange, text: String)] = []
        for range in uncoveredRanges {
            let leftToken = matchingTokens.first {
                $0.kind != .boldItalic && NSMaxRange($0.range) == range.location
            }
            let rightToken = matchingTokens.first {
                $0.kind != .boldItalic && $0.range.location == NSMaxRange(range)
            }

            if let closingMarker = leftToken.flatMap({ nonContentRuns(of: $0).last }) {
                mutations.append((range: closingMarker, text: ""))
            } else {
                mutations.append((
                    range: NSRange(location: range.location, length: 0),
                    text: marker
                ))
            }

            if let openingMarker = rightToken.flatMap({ nonContentRuns(of: $0).first }) {
                mutations.append((range: openingMarker, text: ""))
            } else {
                mutations.append((
                    range: NSRange(location: NSMaxRange(range), length: 0),
                    text: marker
                ))
            }
        }
        return mutations
    }

    private static func appendVisibleInlineRange(
        _ range: NSRange,
        in ns: NSString,
        to ranges: inout [NSRange]
    ) {
        guard range.length > 0 else { return }
        let text = ns.substring(with: range)
        let (leading, core, _) = splitEdgeWhitespace(text)
        let coreLength = (core as NSString).length
        guard coreLength > 0 else { return }
        ranges.append(NSRange(
            location: range.location + (leading as NSString).length,
            length: coreLength
        ))
    }

    private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
        var merged: [NSRange] = []
        for range in sorted {
            guard let last = merged.last, range.location <= NSMaxRange(last) else {
                merged.append(range)
                continue
            }
            merged[merged.count - 1] = NSRange(
                location: last.location,
                length: max(NSMaxRange(last), NSMaxRange(range)) - last.location
            )
        }
        return merged
    }

    /// Membership in sorted, disjoint ranges. Selection state is published while the user drags,
    /// so avoid scanning every token range for every UTF-16 code unit in a large selection.
    private static func ranges(_ ranges: [NSRange], contain location: Int) -> Bool {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let range = ranges[middle]
            if location < range.location {
                upper = middle
            } else if location >= NSMaxRange(range) {
                lower = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    /// Compose disjoint marker insertions/replacements into the one contiguous edit required by the
    /// platform text views, then map the selected visible bounds through those UTF-16 mutations.
    private static func inlineMutationEdit(
        in ns: NSString,
        selection: NSRange,
        visibleBounds: (start: Int, end: Int),
        mutations: [(range: NSRange, text: String)]
    ) -> FormattingEdit {
        var seen = Set<String>()
        let unique = mutations.filter {
            seen.insert("\($0.range.location):\($0.range.length):\($0.text)").inserted
        }
        guard !unique.isEmpty else {
            return FormattingEdit(range: selection, text: ns.substring(with: selection), selection: selection)
        }

        let editStart = min(selection.location, unique.map(\.range.location).min()!)
        let editEnd = max(NSMaxRange(selection), unique.map { NSMaxRange($0.range) }.max()!)
        let editRange = NSRange(location: editStart, length: editEnd - editStart)
        let mutable = NSMutableString(string: ns.substring(with: editRange))
        for mutation in unique.sorted(by: {
            $0.range.location == $1.range.location
                ? $0.range.length > $1.range.length
                : $0.range.location > $1.range.location
        }) {
            let relative = NSRange(
                location: mutation.range.location - editRange.location,
                length: mutation.range.length
            )
            mutable.replaceCharacters(in: relative, with: mutation.text)
        }

        let mappedStart = mappedInlinePosition(
            visibleBounds.start, through: unique, includingInsertionAtPosition: true
        )
        let mappedEnd = mappedInlinePosition(
            visibleBounds.end, through: unique, includingInsertionAtPosition: false
        )
        return FormattingEdit(
            range: editRange,
            text: mutable as String,
            selection: NSRange(location: mappedStart, length: max(0, mappedEnd - mappedStart))
        )
    }

    private static func mappedInlinePosition(
        _ position: Int,
        through mutations: [(range: NSRange, text: String)],
        includingInsertionAtPosition: Bool
    ) -> Int {
        var delta = 0
        for mutation in mutations.sorted(by: { $0.range.location < $1.range.location }) {
            let replacementLength = (mutation.text as NSString).length
            if mutation.range.length == 0 {
                if mutation.range.location < position
                    || (includingInsertionAtPosition && mutation.range.location == position) {
                    delta += replacementLength
                }
                continue
            }

            if NSMaxRange(mutation.range) <= position {
                delta += replacementLength - mutation.range.length
            } else if mutation.range.location <= position {
                return mutation.range.location + delta
                    + (includingInsertionAtPosition ? replacementLength : 0)
            }
        }
        return position + delta
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

    /// The complete source lines touched by `selection`, split into content and their exact line
    /// terminators. A caret on an empty document or after a trailing newline still represents one
    /// empty line, so block commands can insert a marker there.
    private static func linesTouched(
        by selection: NSRange,
        in ns: NSString
    ) -> [(range: NSRange, content: String, terminator: String)] {
        let affectedRange = ns.lineRange(for: selection)
        guard affectedRange.length > 0 else {
            return [(range: affectedRange, content: "", terminator: "")]
        }

        var lines: [(range: NSRange, content: String, terminator: String)] = []
        var location = affectedRange.location
        let affectedEnd = NSMaxRange(affectedRange)
        while location < affectedEnd {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            let (content, terminator) = splitLineTerminator(range, in: ns)
            lines.append((range: range, content: content, terminator: terminator))
            location = NSMaxRange(range)
        }
        return lines
    }

    /// Rebuild a touched line range from independently transformed block lines. The resulting native
    /// selection runs from the first line's visible content through the last line's visible content;
    /// intermediate Markdown markers necessarily remain inside that continuous selection.
    private static func blockLineEdit(
        lines: [(range: NSRange, content: String, terminator: String)],
        transform: (String) -> (text: String, contentRange: NSRange)
    ) -> FormattingEdit {
        var replacement = ""
        var replacementLength = 0
        var selectionStart = 0
        var selectionEnd = 0

        for (index, line) in lines.enumerated() {
            let transformed = transform(line.content)
            if index == 0 {
                selectionStart = transformed.contentRange.location
            }
            if index == lines.count - 1 {
                selectionEnd = replacementLength + NSMaxRange(transformed.contentRange)
            }
            replacement += transformed.text + line.terminator
            replacementLength += (transformed.text as NSString).length + (line.terminator as NSString).length
        }

        let firstLocation = lines[0].range.location
        let lastEnd = NSMaxRange(lines[lines.count - 1].range)
        return FormattingEdit(
            range: NSRange(location: firstLocation, length: lastEnd - firstLocation),
            text: replacement,
            selection: NSRange(
                location: firstLocation + selectionStart,
                length: selectionEnd - selectionStart
            )
        )
    }

    // MARK: - Heading

    private static func headingLevel(in line: String) -> Int? {
        let leadingWhitespace = (line as NSString).range(of: #"^[ \t]*"#, options: .regularExpression)
        let withoutIndent = (line as NSString).substring(from: NSMaxRange(leadingWhitespace))
        return (1...6).first { withoutIndent.hasPrefix(String(repeating: "#", count: $0) + " ") }
    }

    private static func headingEdit(text: String, selection: NSRange, level: Int) -> FormattingEdit {
        let ns = text as NSString
        let lines = linesTouched(by: selection, in: ns)
        // Aggregate toggle: a mixed selection is normalized to the requested level. Only when every
        // touched line is already at that level does the command turn all of them back into paragraphs.
        let removesHeading = lines.allSatisfy { headingLevel(in: $0.content) == level }
        let prefix = String(repeating: "#", count: level) + " "
        let prefixLength = (prefix as NSString).length
        return blockLineEdit(lines: lines) { line in
            var content = line.trimmingCharacters(in: .whitespaces)
            while content.hasPrefix("#") { content.removeFirst() }
            content = content.trimmingCharacters(in: .whitespaces)
            let contentLength = (content as NSString).length
            if removesHeading {
                return (text: content, contentRange: NSRange(location: 0, length: contentLength))
            }
            return (
                text: prefix + content,
                contentRange: NSRange(location: prefixLength, length: contentLength)
            )
        }
    }

    // MARK: - List

    private static func listEdit(text: String, selection: NSRange, prefix: String, ownPattern: String) -> FormattingEdit {
        let ns = text as NSString
        let lines = linesTouched(by: selection, in: ns)
        let removesList = lines.allSatisfy {
            $0.content.range(of: ownPattern, options: .regularExpression) != nil
        }
        let prefixLength = (prefix as NSString).length

        return blockLineEdit(lines: lines) { line in
            let lineNSString = line as NSString
            let ownMarker = lineNSString.range(of: ownPattern, options: .regularExpression)

            // Toggle off only when every line has this list style. Task items shed their checkbox
            // too, matching the established single-line behavior.
            if removesList, ownMarker.location != NSNotFound {
                let content = strippingLeadingTaskBox(lineNSString.substring(from: NSMaxRange(ownMarker)))
                return (
                    text: content,
                    contentRange: NSRange(location: 0, length: (content as NSString).length)
                )
            }

            // A line that already has the requested style remains untouched while the command fills
            // that style into the rest of a mixed selection.
            if ownMarker.location != NSNotFound {
                return (
                    text: line,
                    contentRange: NSRange(
                        location: NSMaxRange(ownMarker),
                        length: lineNSString.length - NSMaxRange(ownMarker)
                    )
                )
            }

            // Convert an existing other list marker rather than stacking the requested marker on it.
            var content = line
            for pattern in [bulletLinePattern, orderedLinePattern] {
                let marker = (content as NSString).range(of: pattern, options: .regularExpression)
                if marker.location != NSNotFound {
                    content = (content as NSString).substring(from: NSMaxRange(marker))
                    break
                }
            }
            return (
                text: prefix + content,
                contentRange: NSRange(location: prefixLength, length: (content as NSString).length)
            )
        }
    }

    // MARK: - Clear block (⌥⌘0 "paragraph")

    /// Heading marker, whitespace-tolerant (matches an INDENTED heading like `  ## x`, unlike a
    /// bare `^#`), so ⌥⌘0 agrees with the heading toggle-off (which trims leading whitespace).
    private static let headingMarkerPattern = #"^[ \t]*#{1,6}[ \t]"#

    /// The block-level line prefixes ⌥⌘0 strips, in the order they can nest at line start.
    private static let blockMarkerPatterns = [
        blockquoteMarkerPattern, headingMarkerPattern, bulletLinePattern, orderedLinePattern,
    ]

    private static let leadingTaskBoxPattern = #"^\[[ xX]\][ \t]?"#

    /// Strip a leading task-checkbox box (`[ ]` / `[x]` / `[X]`) plus one trailing space — used
    /// after a list marker is removed so `- [ ] x` clears to `x`, not `[ ] x`.
    private static func strippingLeadingTaskBox(_ line: String) -> String {
        guard let box = line.range(of: leadingTaskBoxPattern, options: .regularExpression) else { return line }
        return String(line[box.upperBound...])
    }

    /// Strip every block-level prefix on the caret's line — blockquote levels, heading, list
    /// marker, and a task box — turning it back into a plain paragraph. Backs the ⌥⌘0 keyboard
    /// shortcut. Complements the per-command toggle-off (a toolbar clears a block by re-tapping
    /// its button); this clears whatever block is there in one action. Loops to a fixpoint so a
    /// nested prefix (`> ## x`, `> - [ ] x`) is fully cleared, not just its outer marker. An
    /// already-plain line is an identity edit, skipped by the callers' identity guard.
    static func clearBlockEdit(text: String, selection: NSRange) -> FormattingEdit {
        let ns = text as NSString
        let lines = linesTouched(by: selection, in: ns)
        return blockLineEdit(lines: lines) { line in
            var content = line
            var strippedAny = true
            while strippedAny {
                strippedAny = false
                for pattern in blockMarkerPatterns {
                    if let marker = content.range(of: pattern, options: .regularExpression) {
                        content = String(content[marker.upperBound...])
                        strippedAny = true
                        break   // re-scan from the first pattern (markers can nest in any order)
                    }
                }
            }
            content = strippingLeadingTaskBox(content)
            return (
                text: content,
                contentRange: NSRange(location: 0, length: (content as NSString).length)
            )
        }
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

    /// Toggle a `> ` prefix on every touched line. A mixed selection gains quoting on its plain
    /// lines; when every line is quoted, the command removes ONE level from each (`>> x` → `> x`,
    /// `> x` → `x`, `   > x` → `x`).
    private static func blockquoteEdit(text: String, selection: NSRange) -> FormattingEdit {
        let ns = text as NSString
        let lines = linesTouched(by: selection, in: ns)
        let removesQuote = lines.allSatisfy { isBlockquoteLine($0.content) }

        return blockLineEdit(lines: lines) { line in
            let lineNSString = line as NSString
            let marker = lineNSString.range(of: blockquoteMarkerPattern, options: .regularExpression)
            if marker.location != NSNotFound {
                if removesQuote {
                    let content = lineNSString.substring(from: NSMaxRange(marker))
                    return (
                        text: content,
                        contentRange: NSRange(location: 0, length: (content as NSString).length)
                    )
                }
                return (
                    text: line,
                    contentRange: NSRange(
                        location: NSMaxRange(marker),
                        length: lineNSString.length - NSMaxRange(marker)
                    )
                )
            }
            return (
                text: "> " + line,
                contentRange: NSRange(location: 2, length: lineNSString.length)
            )
        }
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
        // code. Detected via `BlockParser`, which (unlike `parseTokensViaAST`) also recognizes an
        // UNTERMINATED fence (open ``` through EOF) — so an in-progress block unwraps instead of
        // getting re-wrapped.
        if let blockRange = enclosingFencedCodeRange(text: text, selection: selection) {
            let inner = fencedCodeInnerContent(blockRange, in: ns)
            return FormattingEdit(
                range: blockRange, text: inner,
                selection: NSRange(location: blockRange.location, length: (inner as NSString).length)
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

    /// The range of the fenced code block enclosing `selection`, if any — terminated OR unterminated
    /// (`BlockParser` consumes an open fence through EOF, which the token parser doesn't surface).
    private static func enclosingFencedCodeRange(text: String, selection: NSRange) -> NSRange? {
        BlockParser.parse(text)
            .first { $0.kind == .fencedCode && enclosesSelection($0.range, selection) }?
            .range
    }

    /// The code inside a fenced block: everything after the opening fence line, minus the closing
    /// fence line and the terminator before it when present (an unterminated block has neither).
    private static func fencedCodeInnerContent(_ blockRange: NSRange, in ns: NSString) -> String {
        let openLine = ns.lineRange(for: NSRange(location: blockRange.location, length: 0))
        let contentStart = min(NSMaxRange(openLine), NSMaxRange(blockRange))
        var contentEnd = NSMaxRange(blockRange)
        if contentEnd > contentStart {
            let lastLine = ns.lineRange(for: NSRange(location: contentEnd - 1, length: 0))
            // Match `BlockParser.isFence` EXACTLY — a column-0 `` ``` `` with no leading-whitespace
            // trim. An indented `   ``` ` is content to BlockParser (the fence stays open to EOF),
            // so trimming here would silently delete that line on unwrap.
            if lastLine.location >= contentStart, ns.substring(with: lastLine).hasPrefix("```") {
                contentEnd = lastLine.location   // drop the closing fence line…
                let body = NSRange(location: contentStart, length: contentEnd - contentStart)
                contentEnd -= trailingLineTerminatorLength(of: body, in: ns)   // …and its preceding terminator
            }
        }
        return contentEnd > contentStart
            ? ns.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart)) : ""
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
