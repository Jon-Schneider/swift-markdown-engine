//
//  MarkdownSeamlessInput.swift
//  MarkdownEngine
//
//  Caret & deletion behavior for seamless (always-hidden-marker) editing.
//
//  In `.seamless` mode the Markdown syntax characters (`> `, `# `, `- `,
//  `**…**`, …) still live in the text buffer but are never drawn. That makes
//  ordinary editing over them feel broken — pressing Backspace at the start of
//  a quoted line would "do nothing" (it nibbles an invisible `>`), and the
//  caret can land *inside* a zero-width marker. This type is the cross-platform,
//  pure decision layer that fixes that:
//
//   - `backspace(...)` detects the caret sitting at the start of an element's
//     visible content and removes the *entire* hidden marker in one edit
//     (unwrapping the block/inline element), instead of deleting one invisible
//     character at a time.
//
//  It is deliberately platform-agnostic and side-effect free so it can be unit
//  tested (see `SeamlessInputTests`) and driven identically by the macOS
//  `NSTextView` and iOS `UITextView` adapters. The marker characters are only
//  ever *removed* here — never inserted — so Markdown stays the storage format.
//
import Foundation

/// What should happen to a pending edit in seamless mode. Mirrors
/// ``ListInsertionDecision`` so platform adapters apply it the same way.
enum SeamlessEditDecision: Equatable {
    /// Let the system perform its normal edit (e.g. ordinary single-char delete).
    case allowDefault
    /// Replace `range` with `text` and place the caret at `caret`.
    case replace(range: NSRange, text: String, caret: Int)
}

enum MarkdownSeamlessInput {

    /// ATX heading prefix, kept in lockstep with `BlockParser.isHeading` /
    /// `MarkdownAST.heading` so seamless edit/copy treat exactly the headings the
    /// styler hides: arbitrary leading spaces/tabs, 1–6 `#`, then ≥1 space (the
    /// parser requires a space, not a tab, after the hashes). Only the full match
    /// length (= content start) is used.
    static let headingPrefixRegex = try! NSRegularExpression(pattern: #"^[ \t]*(#{1,6}) +"#)

    /// Decide what Backspace should do in seamless mode.
    ///
    /// Fires only for a collapsed caret (`selection.length == 0`) that sits
    /// exactly at the start of a block element's visible content, where the
    /// preceding marker is hidden. In that case it returns a `.replace` that
    /// deletes the whole marker run (unwrapping to a plain paragraph) in a
    /// single undoable edit. Otherwise `.allowDefault`.
    ///
    /// Pure & cross-platform: `currentText` is the whole document, `selection`
    /// the current selected range (caret = `selection.location` when empty).
    static func backspace(
        currentText: String,
        selection: NSRange,
        configuration: MarkdownEditorConfiguration
    ) -> SeamlessEditDecision {
        // Only seamless mode rewrites Backspace; other modes keep native behavior.
        guard configuration.markers.visibility == .seamless else { return .allowDefault }
        // Backspace-to-unwrap is opt-out: when disabled, Backspace falls through
        // to the platform's native single-character delete.
        guard configuration.markers.seamlessBackspaceUnwrap else { return .allowDefault }
        guard selection.length == 0 else { return .allowDefault }

        let ns = currentText as NSString
        let caret = selection.location
        guard caret > 0, caret <= ns.length else { return .allowDefault }

        // Inside a fenced code block the contents are opaque, not Markdown — a
        // line like `# x` is literal code, so none of the marker heuristics apply.
        guard !isInFencedCode(ns: ns, location: caret) else { return .allowDefault }

        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let lineStart = lineRange.location
        // Caret must be *within* this line's leading run for an unwrap to make
        // sense; if it's already at line start there's no marker to its left.
        guard caret > lineStart else { return .allowDefault }

        // Line text without the trailing newline, for regex matching.
        var lineLen = lineRange.length
        if lineLen > 0 {
            let last = ns.character(at: lineStart + lineLen - 1)
            if last == 0x0A || last == 0x0D { lineLen -= 1 }
        }
        let line = ns.substring(with: NSRange(location: lineStart, length: lineLen))
        let lineNSLen = (line as NSString).length

        if let contentStart = blockContentStart(line: line, lineNSLen: lineNSLen, lineStart: lineStart),
           caret == contentStart {
            return unwrap(from: lineStart, toContentStart: contentStart)
        }

        // Inline: caret at the start of a span's content (`**|bold**`, `` `|code` ``,
        // `[|text](url)`, …) removes BOTH hidden markers by replacing the span
        // with its visible content.
        if let inline = inlineUnwrap(ns: ns, caret: caret) {
            return inline
        }

        // A rendered image / image-embed is atomic — Backspace at its trailing
        // edge deletes the whole token rather than nibbling one invisible code
        // unit of its hidden `![alt](url)` source (which would corrupt it).
        if let atomic = atomicTokenDeletion(ns: ns, caret: caret) {
            return atomic
        }

        return .allowDefault
    }

    // MARK: - Block detection

    /// Absolute index where a quoted/heading/unordered-list line's *content*
    /// begins (i.e. just past the hidden marker), or `nil` if the line has no
    /// hidden block marker. Ordered-list markers (`1. `) are intentionally
    /// excluded — their number stays visible in seamless mode, so a normal
    /// Backspace there is expected and correct.
    private static func blockContentStart(line: String, lineNSLen: Int, lineStart: Int) -> Int? {
        let fullRange = NSRange(location: 0, length: lineNSLen)

        // Blockquote: `> `, `>> `, `  > `… — always hidden.
        if let m = MarkdownLists.blockquoteRegex.firstMatch(in: line, range: fullRange),
           m.range.length > 0 {
            return lineStart + NSMaxRange(m.range)
        }

        // Heading: `# `…`###### ` — always hidden.
        if let m = headingPrefixRegex.firstMatch(in: line, range: fullRange) {
            return lineStart + NSMaxRange(m.range)
        }

        // List: unwrap only unordered / checkbox items (their `-`/`•`/`[ ]`
        // marker is hidden). Ordered items keep a visible number.
        if let m = MarkdownLists.listRegex.firstMatch(in: line, range: fullRange) {
            let isOrdered = m.range(at: 2).location != NSNotFound
            if !isOrdered {
                return lineStart + NSMaxRange(m.range)
            }
        }

        return nil
    }

    private static func unwrap(from lineStart: Int, toContentStart contentStart: Int) -> SeamlessEditDecision {
        let removal = NSRange(location: lineStart, length: contentStart - lineStart)
        return .replace(range: removal, text: "", caret: lineStart)
    }

    // MARK: - Inline detection

    /// If the caret sits at the start of an inline span's visible content,
    /// returns the edit that unwraps that span (replacing `**bold**` with
    /// `bold`, `` `code` `` with `code`, `[t](u)` with `t`, …). The *deepest*
    /// matching span wins so unwrap peels one nesting level at a time.
    private static func inlineUnwrap(ns: NSString, caret: Int) -> SeamlessEditDecision? {
        let paragraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        guard paragraph.length > 0 else { return nil }
        let nodes = InlineParser.parse(ns, range: paragraph)
        guard let span = deepestSpan(in: nodes, contentStartingAt: caret, ns: ns) else { return nil }
        let content = ns.substring(with: span.content)
        return .replace(range: span.full, text: content, caret: span.full.location)
    }

    /// If `caret` sits at the trailing edge of a rendered, atomic inline token
    /// (`![alt](url)` image or `![[target]]` embed), return the edit that
    /// removes the *whole* token — never a partial, source-corrupting delete.
    private static func atomicTokenDeletion(ns: NSString, caret: Int) -> SeamlessEditDecision? {
        let paragraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        guard paragraph.length > 0 else { return nil }
        for node in InlineParser.parse(ns, range: paragraph) {
            let range: NSRange
            switch node {
            case .image(let r, _, _, _), .imageEmbed(let r, _, _): range = r
            default: continue
            }
            if caret == NSMaxRange(range) {
                return .replace(range: range, text: "", caret: range.location)
            }
        }
        return nil
    }

    /// The full range + content range of the most deeply-nested unwrappable span
    /// whose content begins exactly at `caret`, searching `nodes` recursively.
    private static func deepestSpan(
        in nodes: [InlineNode], contentStartingAt caret: Int, ns: NSString
    ) -> (full: NSRange, content: NSRange)? {
        var best: (full: NSRange, content: NSRange)?
        func consider(_ full: NSRange, _ content: NSRange) {
            guard content.location == caret else { return }
            // Prefer the smallest (innermost) span.
            if best == nil || full.length < best!.full.length { best = (full, content) }
        }
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .emphasis(_, let range, let markers, let children):
                    consider(range, between(markers))
                    walk(children)
                case .strikethrough(let range, let markers, let children):
                    consider(range, between(markers))
                    walk(children)
                case .link(let range, let textRange, _, _, let children):
                    consider(range, textRange)
                    walk(children)
                case .code(let range, let content):
                    consider(range, content)
                case .wikiLink(let range, let name, _, _):
                    consider(range, name)
                case .inlineLatex(let range, let content, _):
                    consider(range, content)
                case .text, .image, .imageEmbed, .escape:
                    break   // no inline-text unwrap
                }
            }
        }
        walk(nodes)
        return best
    }

    /// Content span lying between an `[open, close]` marker pair.
    private static func between(_ markers: [NSRange]) -> NSRange {
        let start = NSMaxRange(markers[0])
        return NSRange(location: start, length: markers[1].location - start)
    }

    // MARK: - Hidden marker ranges (copy)

    /// Every hidden-marker character range in `text` for the configured mode
    /// (empty unless seamless). Used by `visibleText` to strip markers when
    /// copying. (The caret path does NOT use this — see `normalizedCaret`, which
    /// is line/paragraph-scoped to avoid a full-document parse per keystroke.)
    static func hiddenMarkerRanges(
        in text: String, configuration: MarkdownEditorConfiguration
    ) -> [NSRange] {
        guard configuration.markers.visibility == .seamless else { return [] }
        let ns = text as NSString
        var ranges: [NSRange] = []

        // Code-block ranges (opaque) — their interior lines are literal code, so
        // a `# x` / `- y` line inside one is NOT a block marker.
        let blocks = DocumentAST.parse(text)
        let codeRanges: [NSRange] = blocks.compactMap {
            if case .codeBlock(let r) = $0 { return r } else { return nil }
        }
        func inCode(_ loc: Int) -> Bool { codeRanges.contains { NSLocationInRange(loc, $0) } }

        // Block leading markers (`> `, `# `, unordered/checkbox `- `…), per line,
        // skipping any line that lies inside a fenced code block.
        var i = 0
        while i < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: i, length: 0))
            var lineLen = lineRange.length
            if lineLen > 0 {
                let last = ns.character(at: lineRange.location + lineLen - 1)
                if last == 0x0A || last == 0x0D { lineLen -= 1 }
            }
            if !inCode(lineRange.location) {
                let line = ns.substring(with: NSRange(location: lineRange.location, length: lineLen))
                if let contentStart = blockContentStart(
                    line: line, lineNSLen: (line as NSString).length, lineStart: lineRange.location
                ) {
                    ranges.append(NSRange(location: lineRange.location, length: contentStart - lineRange.location))
                }
            }
            let next = NSMaxRange(lineRange)
            if next <= i { break }
            i = next
        }

        // Inline markers (emphasis / strikethrough / code / link / wiki / latex),
        // plus the hidden ``` fence lines of fenced code blocks.
        for block in blocks {
            if case .codeBlock(let range) = block {
                ranges.append(contentsOf: codeFenceRanges(range, ns))
            } else {
                collectInlineMarkers(blockInlines(block), into: &ranges)
            }
        }
        return ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
    }

    /// The hidden opening (```lang⏎) and closing (```) fence ranges of a fenced
    /// code block, so copy-visible strips them and yields only the code.
    private static func codeFenceRanges(_ range: NSRange, _ ns: NSString) -> [NSRange] {
        let start = range.location
        let end = NSMaxRange(range)
        guard end > start else { return [] }
        // Opening fence line, including its trailing newline.
        var openEnd = start
        while openEnd < end, ns.character(at: openEnd) != 0x0A { openEnd += 1 }
        if openEnd < end { openEnd += 1 }
        let open = NSRange(location: start, length: openEnd - start)
        // Closing fence: the run of backticks on the block's last line.
        let lastLine = ns.lineRange(for: NSRange(location: max(start, end - 1), length: 0))
        var bt = lastLine.location
        while bt < NSMaxRange(lastLine), ns.character(at: bt) == 0x60 { bt += 1 }
        let close = NSRange(location: lastLine.location, length: bt - lastLine.location)
        var result = [open]
        // Skip the close fence when it coincides with the open line (an
        // unterminated ```), to avoid double-counting the same characters.
        if close.length > 0, close.location >= openEnd { result.append(close) }
        return result
    }

    /// Normalize a *collapsed* caret in seamless mode so it never rests somewhere
    /// the user can't see, in two cases:
    ///
    /// 1. The hidden block-marker "dead zone" at the start of a quoted/heading/
    ///    list line — where the next character typed would land *before* the
    ///    `> ` / `# ` / `- ` and silently break the block. The caret is pulled
    ///    forward to the visible content start; a single leftward step out of the
    ///    content (← from content start) is allowed to escape to the previous
    ///    line instead of bouncing back.
    /// 2. A *long, atomic* hidden inline run — a link's `](url)` tail or a whole
    ///    rendered `![alt](url)` image — which is zero-width but many characters,
    ///    so arrowing across it would freeze the caret for N keypresses. The
    ///    caret is pushed to the run's far edge in the direction of travel.
    ///
    /// Design notes (driven by review):
    /// - **Grapheme-safe**: this never reimplements character motion (no `±1`);
    ///   it only *post-adjusts* the caret the system already moved. Block math is
    ///   pure-ASCII line boundaries; inline runs come from the parser.
    /// - **Cheap**: the block check inspects only the caret's *line*; the inline
    ///   check parses only the caret's *paragraph*, and only when that line even
    ///   contains a `]` (so plain prose/headings/quotes stay parse-free).
    /// - **Short inline markers (`**`/`*`/`~~`/`` ` ``/`[[ ]]`/`$ $`) are
    ///   intentionally not snapped**: 1–2 zero-width chars is an imperceptible
    ///   extra press, and snapping them invites left/right-ambiguity misfires.
    ///   Only the unambiguous long runs above are handled.
    ///
    /// Returns `proposed` unchanged otherwise.
    static func normalizedCaret(
        text: String, proposed: Int, previous: Int, configuration: MarkdownEditorConfiguration
    ) -> Int {
        guard configuration.markers.visibility == .seamless else { return proposed }
        let ns = text as NSString
        guard proposed >= 0, proposed <= ns.length else { return proposed }
        // Code-block contents are opaque — don't treat code lines as markers.
        guard !isInFencedCode(ns: ns, location: proposed) else { return proposed }
        if let block = blockDeadZoneCaret(ns: ns, proposed: proposed, previous: previous) {
            return block
        }
        if let inline = atomicInlineCaret(ns: ns, proposed: proposed, previous: previous) {
            return inline
        }
        return proposed
    }

    /// Cheap, parse-free check: is the line containing `location` inside a
    /// ```` ``` ```` fenced code block? Counts fence-delimiter lines before it
    /// (an odd count ⇒ inside). Returns immediately when the document has no
    /// fences, so the common case costs only a substring search — this keeps the
    /// per-keystroke caret path free of a full document parse.
    static func isInFencedCode(ns: NSString, location: Int) -> Bool {
        guard ns.range(of: "```").location != NSNotFound else { return false }
        let loc = min(max(0, location), ns.length)
        let lineStart = ns.lineRange(for: NSRange(location: loc, length: 0)).location
        var fences = 0
        var i = 0
        while i < lineStart {
            let line = ns.lineRange(for: NSRange(location: i, length: 0))
            if lineIsFenceDelimiter(ns, line) { fences += 1 }
            let next = NSMaxRange(line)
            if next <= i { break }
            i = next
        }
        return fences % 2 == 1
    }

    /// Whether `line` is a ```` ``` ```` fence delimiter (≤3 spaces indent then
    /// ≥3 backticks).
    private static func lineIsFenceDelimiter(_ ns: NSString, _ line: NSRange) -> Bool {
        var i = line.location
        let end = NSMaxRange(line)
        var indent = 0
        while i < end, indent < 4, ns.character(at: i) == 0x20 { i += 1; indent += 1 }
        guard indent < 4 else { return false }
        var ticks = 0
        while i < end, ns.character(at: i) == 0x60 { ticks += 1; i += 1 }
        return ticks >= 3
    }

    /// Caret adjustment for the hidden block-marker dead zone (case 1 above), or
    /// `nil` if the caret isn't within a line's hidden `> `/`# `/`- ` run.
    private static func blockDeadZoneCaret(ns: NSString, proposed: Int, previous: Int) -> Int? {
        let line = ns.lineRange(for: NSRange(location: min(proposed, ns.length), length: 0))
        var lineLen = line.length
        if lineLen > 0 {
            let last = ns.character(at: line.location + lineLen - 1)
            if last == 0x0A || last == 0x0D { lineLen -= 1 }
        }
        let lineText = ns.substring(with: NSRange(location: line.location, length: lineLen))
        guard let contentStart = blockContentStart(
            line: lineText, lineNSLen: (lineText as NSString).length, lineStart: line.location
        ), contentStart > line.location else { return nil }
        guard proposed >= line.location, proposed < contentStart else { return nil }

        // A single leftward step out of the content escapes to the previous line
        // (rather than bouncing back to content start). On the first line there's
        // nowhere to go, so the caret stays at content start.
        let markerLen = contentStart - line.location
        if previous >= contentStart, previous - proposed <= markerLen {
            return line.location > 0 ? line.location - 1 : contentStart
        }
        return contentStart   // tap / forward arrival / Home → visible content start
    }

    /// Caret adjustment for a long atomic inline run (case 2 above), or `nil`.
    /// Snaps to the run's far edge in the direction of travel inferred from
    /// `previous`. Parses only the caret's paragraph, gated on a cheap `]` check.
    private static func atomicInlineCaret(ns: NSString, proposed: Int, previous: Int) -> Int? {
        let line = ns.lineRange(for: NSRange(location: min(proposed, ns.length), length: 0))
        // Links (`](url)`) and images (`![…]`) both contain `]`; nothing else we
        // snap does, so skip the parse for any line without one.
        guard ns.range(of: "]", options: [], range: line).location != NSNotFound else { return nil }
        let paragraph = ns.paragraphRange(for: NSRange(location: min(proposed, ns.length), length: 0))
        for run in atomicInlineRuns(in: InlineParser.parse(ns, range: paragraph))
        where proposed > run.location && proposed < NSMaxRange(run) {
            return proposed >= previous ? NSMaxRange(run) : run.location
        }
        return nil
    }

    /// Long, direction-unambiguous hidden inline runs: a link's `](url)` tail and
    /// whole `![alt](url)` / `![[embed]]` ranges. Recurses through emphasis/strike
    /// /link children. Short marker pairs are deliberately excluded.
    private static func atomicInlineRuns(in nodes: [InlineNode]) -> [NSRange] {
        var runs: [NSRange] = []
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .link(let range, let textRange, _, _, let children):
                    let tail = NSRange(location: NSMaxRange(textRange),
                                       length: NSMaxRange(range) - NSMaxRange(textRange))
                    if tail.length > 0 { runs.append(tail) }
                    walk(children)
                case .image(let range, _, _, _), .imageEmbed(let range, _, _):
                    runs.append(range)
                case .emphasis(_, _, _, let children):
                    walk(children)
                case .strikethrough(_, _, let children):
                    walk(children)
                default:
                    break
                }
            }
        }
        walk(nodes)
        return runs
    }

    // MARK: - Copy (visible text)

    /// The *visible* text of `selection` — the selected substring with every
    /// hidden marker removed — for placing on the pasteboard in seamless mode.
    /// (`> text` copies as `text`, `**b**` as `b`, `[t](u)` as `t`, ….) Ordered
    /// list numbers and other on-screen characters are preserved because they
    /// aren't hidden markers. Outside seamless mode the raw substring is returned.
    ///
    /// Note: the rendered bullet/checkbox *glyphs* (•, ☐) are decorations, not
    /// buffer text, so an unordered/checkbox item copies as just its content
    /// (`- [ ] task` → `task`). This is the deliberate "copy what's textual"
    /// contract; an embedder wanting round-trippable Markdown should copy the raw
    /// source instead (switch to `.revealOnEdit` semantics for that path).
    static func visibleText(
        of selection: NSRange, in text: String, configuration: MarkdownEditorConfiguration
    ) -> String {
        let ns = text as NSString
        let clamped = NSRange(
            location: min(max(0, selection.location), ns.length),
            length: max(0, min(selection.length, ns.length - min(max(0, selection.location), ns.length)))
        )
        guard configuration.markers.visibility == .seamless, clamped.length > 0 else {
            return ns.substring(with: clamped)
        }
        let hidden = hiddenMarkerRanges(in: text, configuration: configuration)
        let end = NSMaxRange(clamped)
        var kept: [NSRange] = []
        var cursor = clamped.location
        for r in hidden where NSMaxRange(r) > clamped.location && r.location < end {
            let cutStart = max(r.location, clamped.location)
            if cutStart > cursor {
                kept.append(NSRange(location: cursor, length: cutStart - cursor))
            }
            cursor = max(cursor, min(NSMaxRange(r), end))
        }
        if cursor < end { kept.append(NSRange(location: cursor, length: end - cursor)) }
        return kept.map { ns.substring(with: $0) }.joined()
    }

    private static func blockInlines(_ block: BlockNode) -> [InlineNode] {
        switch block {
        case .paragraph(_, let inlines), .heading(_, _, _, let inlines), .blockquote(_, let inlines):
            return inlines
        case .list(_, let items):
            return items.flatMap { $0.inlines }
        case .codeBlock, .blockLatex, .table, .thematicBreak, .blank:
            return []
        }
    }

    private static func collectInlineMarkers(_ nodes: [InlineNode], into ranges: inout [NSRange]) {
        for node in nodes {
            switch node {
            case .emphasis(_, _, let markers, let children),
                 .strikethrough(_, let markers, let children):
                ranges.append(contentsOf: markers)
                collectInlineMarkers(children, into: &ranges)
            case .code(let range, let content):
                ranges.append(NSRange(location: range.location, length: content.location - range.location))
                ranges.append(NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content)))
            case .link(let range, let textRange, _, _, let children):
                // The opening `[` and the trailing `](url)` are both hidden.
                ranges.append(NSRange(location: range.location, length: textRange.location - range.location))
                ranges.append(NSRange(location: NSMaxRange(textRange), length: NSMaxRange(range) - NSMaxRange(textRange)))
                collectInlineMarkers(children, into: &ranges)
            case .wikiLink(_, _, _, let markers), .inlineLatex(_, _, let markers):
                ranges.append(contentsOf: markers)
            case .image(let range, _, _, _), .imageEmbed(let range, _, _):
                ranges.append(range)   // rendered token is atomic
            case .escape(_, _, let marker):
                ranges.append(marker)
            case .text:
                break
            }
        }
    }
}
