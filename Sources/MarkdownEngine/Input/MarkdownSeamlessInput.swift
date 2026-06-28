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

    /// Blockquote prefix, kept in lockstep with `BlockParser.isBlockquote`, which
    /// allows up to three leading *spaces or tabs* before the `>` run. The shared
    /// ``MarkdownLists/blockquoteRegex`` only tolerates leading spaces (it drives
    /// list-indent math), so seamless detection uses its own pattern — otherwise a
    /// tab-indented quote (`\t> x`) gets its marker hidden by the styler while
    /// backspace/caret/copy fail to recognize the hidden prefix. The `>` run +
    /// trailing whitespace semantics match the shared regex; only the indent class
    /// differs (`[ \t]{0,3}` vs `{0,3}` spaces).
    static let blockquotePrefixRegex = try! NSRegularExpression(
        pattern: #"^[ \t]{0,3}(>+(?:[ \t]+>+)*)[ \t]*"#
    )

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

        // Atomic full-line elements (fire at a line start, before the "marker to
        // the left" guard below): Backspace at the start of a fenced code block's
        // first body line unwraps the whole block to a plain paragraph; Backspace
        // at the start of the line after a thematic break removes the rule line.
        if let fullLine = fullLineElementBackspace(ns: ns, caret: caret) {
            return fullLine
        }

        // Inside a fenced code block the contents are opaque, not Markdown — a
        // line like `# x` is literal code, so none of the marker heuristics apply.
        // (The body-start unwrap was already handled just above.)
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

        if let contentStart = blockContentStart(line: line, lineNSLen: lineNSLen, lineStart: lineStart, includeOrdered: true),
           caret == contentStart {
            // A heading/quote/list-looking line that actually lives inside an
            // opaque block-LaTeX (`$$…$$`) or table is literal content, not a
            // Markdown marker — never unwrap it. (Fenced code is already excluded
            // above.) Parsed lazily, only now that a prefix has matched.
            guard !isInLatexOrTable(ns: ns, location: caret) else { return .allowDefault }
            return unwrap(from: lineStart, toContentStart: contentStart)
        }

        // Inline: caret at the start of a span's content (`**|bold**`, `` `|code` ``,
        // `[|text](url)`, …). The hidden opening marker is zero-width, so Backspace
        // deletes the visible character *before* it (seamless) rather than stripping
        // the formatting.
        if let inline = inlineBackspace(ns: ns, caret: caret) {
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

    /// Absolute index where a quoted/heading/list line's *content* begins (i.e.
    /// just past the hidden marker), or `nil` if the line has no qualifying block
    /// marker.
    ///
    /// Ordered-list markers split into two cases by how the styler draws them:
    ///
    /// - **Plain ordered (`1. `)** — the number is **drawn** in seamless mode (the
    ///   styler's bullet decoration only fires for non-ordered items:
    ///   `MarkdownASTStyler`, `else if !item.ordered`). So it is *not* a hidden
    ///   marker for copy (`hiddenMarkerRanges` must keep the number) or the caret
    ///   dead-zone (the caret may rest on a visible digit). Only the Backspace-
    ///   unwrap path (1.3) treats `1. ` as removable, opting in via
    ///   `includeOrdered: true`; every other caller keeps the default.
    /// - **Ordered checkbox (`1. [ ] `)** — the styler's checkbox branch (`if let
    ///   box = item.checkbox`, which precedes the `else if !item.ordered`) clears
    ///   the `1.` marker and draws a ☐ glyph, so the whole `1. [ ] ` prefix is
    ///   *hidden* exactly like `- [ ] `. It therefore qualifies for **every**
    ///   caller (copy strips it, caret snaps past it, Backspace unwraps it),
    ///   regardless of `includeOrdered` — otherwise it would copy invisible buffer
    ///   text while the identically-rendered `- [ ] ` copies clean.
    private static func blockContentStart(line: String, lineNSLen: Int, lineStart: Int, includeOrdered: Bool = false) -> Int? {
        let fullRange = NSRange(location: 0, length: lineNSLen)

        // Blockquote: `> `, `>> `, `  > `, `\t> `… — always hidden. Tab-tolerant to
        // match `BlockParser.isBlockquote` (see `blockquotePrefixRegex`).
        if let m = blockquotePrefixRegex.firstMatch(in: line, range: fullRange),
           m.range.length > 0 {
            return lineStart + NSMaxRange(m.range)
        }

        // Heading: `# `…`###### ` — always hidden.
        if let m = headingPrefixRegex.firstMatch(in: line, range: fullRange) {
            return lineStart + NSMaxRange(m.range)
        }

        // List markers. Unordered / checkbox markers (`-`/`•`/`[ ]`) are hidden, so
        // they qualify for every caller. A *plain* ordered number (`1. `) is drawn,
        // so it qualifies only when the caller opts in (Backspace-unwrap). An
        // ordered *checkbox* (`1. [ ] `) has its marker hidden by the styler's
        // checkbox branch — same as `- [ ] ` — so it qualifies for every caller.
        if let m = MarkdownLists.listRegex.firstMatch(in: line, range: fullRange) {
            let orderedDigits = m.range(at: 2)               // ordered digit run; .location == NSNotFound for bullets
            let isOrdered = orderedDigits.location != NSNotFound
            // Parser parity: `listRegex` accepts an unbounded digit run, but the
            // AST/`BlockParser` cap an ordered marker at 9 digits (`digits < 9`).
            // A longer run (`1234567890. item`) is NOT parsed/styled as a list, so
            // its prefix is literal visible text — never a hidden/unwrappable
            // marker. Disqualify it so Backspace there is an ordinary delete.
            guard !isOrdered || orderedDigits.length <= 9 else { return nil }
            let hasCheckbox = (line as NSString).substring(with: m.range(at: 1)).contains("[")
            if !isOrdered || hasCheckbox || includeOrdered {
                return lineStart + NSMaxRange(m.range)
            }
        }

        return nil
    }

    private static func unwrap(from lineStart: Int, toContentStart contentStart: Int) -> SeamlessEditDecision {
        let removal = NSRange(location: lineStart, length: contentStart - lineStart)
        return .replace(range: removal, text: "", caret: lineStart)
    }

    // MARK: - Full-line hidden elements (delete)

    /// Atomic Backspace for the two full-line hidden elements, both triggered at a
    /// *line start*:
    /// - **Code fence**: at the start of a fenced block's first body line, unwrap
    ///   the whole block to a plain paragraph (drop both fence lines, keep the
    ///   body text) in one edit.
    /// - **Thematic break**: at the start of the line *after* a `---`/`***`/`___`
    ///   rule, remove the entire rule line.
    ///
    /// Returns `nil` (→ native delete) anywhere else. A cheap per-line pre-check
    /// gates the single structural parse, so ordinary Backspaces never parse.
    private static func fullLineElementBackspace(ns: NSString, caret: Int) -> SeamlessEditDecision? {
        let line = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
        // Only at a line start, and only when the line above could be one of the
        // two elements — otherwise there's nothing atomic to delete here.
        guard caret == line.location, line.location > 0 else { return nil }
        let prevLine = ns.lineRange(for: NSRange(location: line.location - 1, length: 0))
        let prevLooksThematic = lineLooksLikeThematicBreak(ns, prevLine)
        let prevLooksFence = lineIsFenceDelimiter(ns, prevLine)
        guard prevLooksThematic || prevLooksFence else { return nil }

        let blocks = DocumentAST.parse(ns as String)

        // Thematic break directly above → delete the whole rule line (+ newline).
        if prevLooksThematic, blocks.contains(where: {
            if case .thematicBreak(let r) = $0 { return NSLocationInRange(prevLine.location, r) }
            return false
        }) {
            return .replace(
                range: NSRange(location: prevLine.location, length: line.location - prevLine.location),
                text: "", caret: prevLine.location
            )
        }

        // Start of a fenced code body (the line above is this block's open fence)
        // → unwrap the block: replace the whole block range with just its body.
        for case .codeBlock(let range) in blocks where NSLocationInRange(caret, range) {
            let firstLine = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let bodyStart = NSMaxRange(firstLine)
            guard caret == bodyStart else { continue }
            // Exclude the closing fence line — but only if there *is* one. An
            // unterminated fence (open ``` with no close) is a block through EOF
            // per `BlockParser`, so its last line is body content, not a fence;
            // dropping it would lose text.
            let blockEnd = NSMaxRange(range)
            let lastLine = ns.lineRange(for: NSRange(location: max(range.location, blockEnd - 1), length: 0))
            let bodyEnd = lineIsFenceDelimiter(ns, lastLine) ? lastLine.location : blockEnd
            let body = bodyEnd > bodyStart
                ? ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                : ""
            return .replace(range: range, text: body, caret: range.location)
        }
        return nil
    }

    // MARK: - Inline detection

    /// Backspace at the start of an inline span's visible content. Because the
    /// span's opening marker is hidden (zero-width) in seamless mode, a *seamless*
    /// Backspace deletes the visible character before the marker — a space/letter
    /// is removed, a newline merges lines — rather than stripping the formatting.
    /// This is what the user means by "backspace the previous character"; a native
    /// delete here would instead nibble one `*`/`` ` `` and corrupt the source.
    ///
    /// The visible character is found by skipping the contiguous run of hidden
    /// markers immediately left of the caret (the span's own opening marker, plus
    /// any nested-inner or block markers it abuts), scoped to the caret's paragraph
    /// + line so there's no full-document parse. When *nothing* visible precedes
    /// the span (it's the block's first content, or the document start), it falls
    /// back to unwrapping the span — the safe, non-corrupting option there.
    private static func inlineBackspace(ns: NSString, caret: Int) -> SeamlessEditDecision? {
        // O(1) pre-gate: an inline span's hidden opening marker always ends in one
        // of `* _ ~ ` [ $`, so if the character left of the caret isn't one, no span
        // starts here — skip the paragraph parse entirely (ordinary prose deletes).
        guard caret > 0, isInlineOpenerChar(ns.character(at: caret - 1)) else { return nil }
        let paragraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        guard paragraph.length > 0 else { return nil }
        let nodes = InlineParser.parse(ns, range: paragraph)
        guard let span = deepestSpan(in: nodes, contentStartingAt: caret, ns: ns) else { return nil }
        // Inside an opaque block-LaTeX (`$$…$$`) or table the `**`/`` ` ``/`[]()`
        // are literal AND drawn (the styler doesn't hide them there), so they are
        // not zero-width — never delete "across" them. (Fenced code is already
        // excluded by the caller.) Parsed lazily, only now that a span matched.
        guard !isInLatexOrTable(ns: ns, location: caret) else { return nil }

        // Hidden marker ranges left of the caret, scoped to this paragraph + line:
        // the paragraph's inline markers, plus the current line's block marker
        // (`# `, `> `, `- `…) if any.
        var hidden: [NSRange] = []
        collectInlineMarkers(nodes, into: &hidden)
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        var lineLen = line.length
        if lineLen > 0 {
            let last = ns.character(at: line.location + lineLen - 1)
            if last == 0x0A || last == 0x0D { lineLen -= 1 }
        }
        let lineText = ns.substring(with: NSRange(location: line.location, length: lineLen))
        if let contentStart = blockContentStart(
            line: lineText, lineNSLen: (lineText as NSString).length, lineStart: line.location
        ) {
            hidden.append(NSRange(location: line.location, length: contentStart - line.location))
        }

        // Skip the contiguous run of hidden markers immediately left of the caret.
        var scan = caret
        var moved = true
        while moved {
            moved = false
            for r in hidden where r.length > 0 && NSMaxRange(r) == scan {
                scan = r.location
                moved = true
                break
            }
        }

        guard scan > 0 else {
            // Nothing visible precedes the span — fall back to unwrapping it
            // (replacing `**bold**` with `bold`), which avoids corrupting markers.
            let content = ns.substring(with: span.content)
            return .replace(range: span.full, text: content, caret: span.full.location)
        }
        // Grapheme-safe delete of the visible character before the hidden run.
        var prev = ns.rangeOfComposedCharacterSequence(at: scan - 1)
        // `rangeOfComposedCharacterSequence` does not combine a CRLF line break, so
        // a span at the start of a `\r\n` line would leave a stray `\r`. Extend a
        // lone `\n` to include a preceding `\r` so the line-merge is clean.
        if prev.length == 1, ns.character(at: prev.location) == 0x0A,
           prev.location > 0, ns.character(at: prev.location - 1) == 0x0D {
            prev = NSRange(location: prev.location - 1, length: 2)
        }
        return .replace(range: prev, text: "", caret: prev.location)
    }

    /// If `caret` sits at the trailing edge of a rendered, atomic inline token
    /// (`![alt](url)` image or `![[target]]` embed), return the edit that
    /// removes the *whole* token — never a partial, source-corrupting delete.
    private static func atomicTokenDeletion(ns: NSString, caret: Int) -> SeamlessEditDecision? {
        // O(1) pre-gate: an image / embed ends in `)` or `]`, so other deletes skip
        // the parse. Inside an opaque block-LaTeX / table an `![a](u)` is literal,
        // not a rendered token, so it must not be atomically deleted.
        guard caret > 0 else { return nil }
        let before = ns.character(at: caret - 1)
        guard before == 0x29 || before == 0x5D else { return nil }   // ) ]
        let paragraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        guard paragraph.length > 0 else { return nil }
        for node in InlineParser.parse(ns, range: paragraph) {
            let range: NSRange
            switch node {
            case .image(let r, _, _, _), .imageEmbed(let r, _, _): range = r
            default: continue
            }
            if caret == NSMaxRange(range) {
                guard !isInLatexOrTable(ns: ns, location: caret) else { return nil }
                return .replace(range: range, text: "", caret: range.location)
            }
        }
        return nil
    }

    /// Whether `c` is the last character of some inline span's hidden opening
    /// marker — `*`, `_`, `~`, `` ` ``, `[` (link / wiki-link), or `$` (inline
    /// LaTeX). Used as an O(1) gate so a span-start parse only runs when the caret
    /// could actually sit just past an opening marker.
    private static func isInlineOpenerChar(_ c: unichar) -> Bool {
        switch c {
        case 0x2A, 0x5F, 0x7E, 0x60, 0x5B, 0x24: return true   // * _ ~ ` [ $
        default: return false
        }
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

        let blocks = DocumentAST.parse(text)
        // Opaque-block ranges (fenced code + block LaTeX + tables) — their interior
        // lines are literal content, so a `# x` / `- y` line inside one is NOT a
        // block marker and must not be stripped.
        let opaqueRanges: [NSRange] = blocks.compactMap {
            switch $0 {
            case .codeBlock(let r), .blockLatex(let r), .table(let r): return r
            default: return nil
            }
        }
        func inOpaqueBlock(_ loc: Int) -> Bool { opaqueRanges.contains { NSLocationInRange(loc, $0) } }

        // Block leading markers (`> `, `# `, unordered/checkbox `- `…), per line,
        // skipping any line that lies inside an opaque rendered block.
        var i = 0
        while i < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: i, length: 0))
            var lineLen = lineRange.length
            if lineLen > 0 {
                let last = ns.character(at: lineRange.location + lineLen - 1)
                if last == 0x0A || last == 0x0D { lineLen -= 1 }
            }
            if !inOpaqueBlock(lineRange.location) {
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
        // Hidden *full-line* elements (a thematic-break rule, or a code-fence
        // delimiter line) are never a valid caret resting spot in seamless mode —
        // step over them to the adjacent editable line. Checked before the
        // fenced-code guard because a close-fence line counts as "inside" code yet
        // must still be skipped.
        if let skipped = fullLineHiddenElementCaret(ns: ns, proposed: proposed, previous: previous) {
            return skipped
        }
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

    /// True if `location` lies inside a block-LaTeX (`$$…$$`) or GFM table block —
    /// opaque rendered content whose interior lines are NOT Markdown, so block
    /// marker heuristics must not fire there. Costs one structural parse, so
    /// callers invoke it *lazily*, only once a block-marker prefix has already
    /// matched at the caret — keeping the common per-keystroke path parse-free.
    /// (Fenced code is handled separately by the cheaper ``isInFencedCode``, which
    /// every caller runs first.)
    private static func isInLatexOrTable(ns: NSString, location: Int) -> Bool {
        for block in DocumentAST.parse(ns as String) {
            switch block {
            case .blockLatex(let r), .table(let r):
                if NSLocationInRange(location, r) { return true }
            default:
                break
            }
        }
        return false
    }

    /// Whether `line` is a ```` ``` ```` fence delimiter: ≥3 backticks at
    /// **column 0**. Mirrors `BlockParser.isFence` (`hasPrefix("```")`), which
    /// does *not* allow leading indent — an indented `  ``` ` is not a fence to
    /// the parser, so the styler renders the lines after it as ordinary Markdown
    /// and seamless detection must agree (otherwise it would suppress
    /// unwrap/caret-snap on a real heading as if it were inside code).
    private static func lineIsFenceDelimiter(_ ns: NSString, _ line: NSRange) -> Bool {
        var i = line.location
        let end = NSMaxRange(line)
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
        // A marker-looking line inside opaque block LaTeX / a table is literal, not
        // a hidden marker — don't snap the caret out of it. (Fenced code already
        // excluded by `normalizedCaret`.) Parsed lazily, only after a prefix match.
        guard !isInLatexOrTable(ns: ns, location: proposed) else { return nil }

        // A single leftward step out of the content escapes to the previous line
        // (rather than bouncing back to content start). On the first line there's
        // nowhere to go, so the caret stays at content start.
        let markerLen = contentStart - line.location
        if previous >= contentStart, previous - proposed <= markerLen {
            return line.location > 0 ? line.location - 1 : contentStart
        }
        return contentStart   // tap / forward arrival / Home → visible content start
    }

    /// Snap a collapsed caret off a *hidden full-line element* — a thematic-break
    /// rule (`---`/`***`/`___`) or a code-fence delimiter line (```` ``` ````) — to
    /// the nearest editable line in the direction of travel. In seamless mode these
    /// lines render as a rule / collapse to zero width, so a caret resting on them
    /// (and any typing there) would silently mutate invisible syntax.
    ///
    /// Expands to the maximal contiguous run of hidden lines around the caret, then
    /// lands on the editable boundary in the travel direction (falling back to the
    /// other side at a document edge) — so stacked elements (an empty code block, a
    /// rule immediately followed by a fence) are skipped in one step. The code
    /// *body* between fences is editable and never skipped.
    ///
    /// Returns `nil` in the common case, decided by a cheap per-line pre-check
    /// before any parse.
    private static func fullLineHiddenElementCaret(ns: NSString, proposed: Int, previous: Int) -> Int? {
        let startLine = ns.lineRange(for: NSRange(location: min(proposed, ns.length), length: 0))
        // Cheap gate: only a fence-delimiter- or thematic-break-looking line can be
        // a hidden full-line element, so prose/headings/quotes never trigger a parse.
        guard lineIsFenceDelimiter(ns, startLine) || lineLooksLikeThematicBreak(ns, startLine) else { return nil }

        let blocks = DocumentAST.parse(ns as String)
        let thematic: [NSRange] = blocks.compactMap { if case .thematicBreak(let r) = $0 { return r } else { return nil } }
        let code: [NSRange] = blocks.compactMap { if case .codeBlock(let r) = $0 { return r } else { return nil } }
        func isHidden(_ line: NSRange) -> Bool {
            if thematic.contains(where: { NSLocationInRange(line.location, $0) }) { return true }
            // A code-fence *delimiter* line (open/close) — never an editable body line.
            return code.contains(where: { NSLocationInRange(line.location, $0) }) && lineIsFenceDelimiter(ns, line)
        }
        guard isHidden(startLine) else { return nil }

        var runStart = startLine.location
        var runEnd = NSMaxRange(startLine)
        while runStart > 0 {
            let prev = ns.lineRange(for: NSRange(location: runStart - 1, length: 0))
            if isHidden(prev) { runStart = prev.location } else { break }
        }
        while runEnd < ns.length {
            let next = ns.lineRange(for: NSRange(location: runEnd, length: 0))
            if isHidden(next) { runEnd = NSMaxRange(next) } else { break }
        }
        let hasBefore = runStart > 0           // → end of the line before the run
        let hasAfter = runEnd < ns.length      // → start of the line after the run
        let forward = proposed >= previous
        if forward {
            if hasAfter { return runEnd }
            if hasBefore { return runStart - 1 }
        } else {
            if hasBefore { return runStart - 1 }
            if hasAfter { return runEnd }
        }
        return nil   // entire document is hidden lines — nothing editable to snap to
    }

    /// Cheap, parse-free check: does `line` look like a thematic break — a solid run
    /// of ≥3 of one of `-`/`*`/`_`, after optional surrounding whitespace? Mirrors
    /// `BlockParser.isThematicBreak`. This engine has no setext-heading rule, so a
    /// `---` line is never a heading underline; the only false positive is a `---`
    /// *inside* a code body, which callers reject via AST confirmation.
    private static func lineLooksLikeThematicBreak(_ ns: NSString, _ line: NSRange) -> Bool {
        var i = line.location
        let end = NSMaxRange(line)
        while i < end, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }   // trim leading WS
        var j = end
        while j > i {
            let c = ns.character(at: j - 1)
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { j -= 1 } else { break }      // trim trailing WS/newline
        }
        guard j - i >= 3 else { return false }
        let first = ns.character(at: i)
        guard first == 0x2D || first == 0x2A || first == 0x5F else { return false }            // - * _
        var k = i
        while k < j {
            if ns.character(at: k) != first { return false }
            k += 1
        }
        return true
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
