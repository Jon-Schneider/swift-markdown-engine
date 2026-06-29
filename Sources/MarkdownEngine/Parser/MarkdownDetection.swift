//
//  MarkdownDetection.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Helper checks for questions like "is the cursor inside code or LaTeX?"
// and "which Markdown part is currently active?".
import Foundation

enum MarkdownDetection {

    // MARK: - Active Token Indices

    /// Block-level rendered elements whose raw source reveals on caret entry even in SEAMLESS
    /// mode, so they can be edited (the "reveal hole", plan 1.2). Inline elements ($x$, **bold**)
    /// never reveal in seamless — that is the whole point of the mode. A container kind here
    /// (`.table`) also marks the tokens nested in its range active via `propagateActiveContainers`.
    /// That's load-bearing for cell content whose styler renders an overlay keyed off
    /// `activeTokenIndices` and does NOT skip table interiors — images / links / embeds — which must
    /// show their raw `![…]` / `[…](…)` source, not a rendered overlay, when the table is revealed.
    /// (Plain cell text and inline `$…$` / `**bold**` reveal regardless, because the table styler
    /// paints the whole range as plain body text and the inline-LaTeX styler skips table interiors.)
    static let seamlessRevealableBlockKinds: Set<MarkdownTokenKind> = [.blockLatex, .table]

    static func computeActiveTokenIndices(
        selectionRange: NSRange,
        tokens: [MarkdownToken],
        in text: NSString,
        suppressed: Bool = false,
        markerVisibility: MarkerVisibility
    ) -> Set<Int> {
        // Read-only mode (no caret) hides all tokens regardless of any trailing selection.
        if suppressed { return [] }
        switch markerVisibility {
        case .seamless:
            // Seamless hides every marker EXCEPT a block-level rendered element the caret has
            // entered (block LaTeX, table), whose raw source must reveal so it can be edited.
            // Inline rendered runs outside such a block stay hidden. A revealed container (table)
            // propagates to its inline children so the whole block's source shows.
            let blocks = tokenIndices(touching: selectionRange, in: tokens, text: text,
                                      where: { seamlessRevealableBlockKinds.contains($0.kind) })
            return propagateActiveContainers(blocks, tokens: tokens)
        case .revealAll: return Set(tokens.indices)  // "show raw Markdown" escape hatch
        case .revealOnEdit: break
        }
        var indices: Set<Int> = []
        let caretLocation = selectionRange.location
        for (index, token) in tokens.enumerated() {
            let start = token.range.location
            let end = NSMaxRange(token.range)
            if selectionRange.length > 0 && (token.kind == .inlineLatex || token.kind == .blockLatex) && NSIntersectionRange(selectionRange, token.range).length > 0 {
                indices.insert(index)
                continue
            }
            if caretLocation >= start && caretLocation < end {
                indices.insert(index)
                continue
            }
            if caretLocation == end {
                let lastIndex = end - 1
                if lastIndex >= start && lastIndex < text.length {
                    let lastChar = text.substring(with: NSRange(location: lastIndex, length: 1))
                    if lastChar != "\n" {
                        indices.insert(index)
                    }
                }
            }
        }

        return propagateActiveContainers(indices, tokens: tokens)
    }

    /// When a container token (a `.table`) is active, every token nested inside its range becomes
    /// active too. This is load-bearing for cell content whose styler keys off `activeTokenIndices`
    /// without skipping table interiors — images / links / embeds: without propagation a revealed
    /// table would render an overlay over the raw `![…]` / `[…](…)` source. (Inline LaTeX is skipped
    /// inside tables by its own styler, so propagation is inert for it; plain cell text reveals via
    /// the table styler painting the range as plain text.) Shared by the seamless and reveal-on-edit
    /// paths so the two stay in lockstep. Returns `indices` unchanged when no active container is present.
    private static func propagateActiveContainers(_ indices: Set<Int>, tokens: [MarkdownToken]) -> Set<Int> {
        let activeContainers: [MarkdownToken] = indices.compactMap { idx in
            tokens[idx].kind == .table ? tokens[idx] : nil
        }
        guard !activeContainers.isEmpty else { return indices }
        var result = indices
        for (i, token) in tokens.enumerated() where !result.contains(i) {
            let tStart = token.range.location
            let tEnd = NSMaxRange(token.range)
            if activeContainers.contains(where: { tStart >= $0.range.location && tEnd <= NSMaxRange($0.range) }) {
                result.insert(i)
            }
        }
        return result
    }

    /// Indices of tokens matching `predicate` that the selection touches: a ranged selection that
    /// overlaps the token, a caret strictly inside it, or a zero-length caret resting at a
    /// non-newline trailing edge. The seamless reveal hole uses this over a restricted set of block
    /// kinds. Container→child propagation is shared (`propagateActiveContainers`, applied after this
    /// in both paths). NOTE: this still mirrors — not shares — the reveal-on-edit branch's per-token
    /// containment loop; the one semantic difference is the ranged-selection rule (reveal-on-edit
    /// gates intersection to LaTeX kinds, this applies it to every matched kind). Keep them in lockstep
    /// if you change containment.
    private static func tokenIndices(
        touching selectionRange: NSRange,
        in tokens: [MarkdownToken],
        text: NSString,
        where predicate: (MarkdownToken) -> Bool
    ) -> Set<Int> {
        var indices: Set<Int> = []
        let caretLocation = selectionRange.location
        for (index, token) in tokens.enumerated() where predicate(token) {
            let start = token.range.location
            let end = NSMaxRange(token.range)
            if selectionRange.length > 0 {
                if NSIntersectionRange(selectionRange, token.range).length > 0 { indices.insert(index) }
            } else if caretLocation >= start && caretLocation < end {
                indices.insert(index)
            } else if caretLocation == end, end - 1 >= start, end - 1 < text.length,
                      text.substring(with: NSRange(location: end - 1, length: 1)) != "\n" {
                indices.insert(index)
            }
        }
        return indices
    }

    // MARK: - Code Block Detection

    /// Slow: parses tokens each call
    static func isInsideCodeBlock(range: NSRange, in text: String) -> Bool {
        let codeTokens = MarkdownTokenizer.parseTokensViaAST(in: text).filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
        return isInsideCodeBlock(range: range, codeTokens: codeTokens)
    }

    static func isInsideCodeBlock(location: Int, in text: String) -> Bool {
        isInsideCodeBlock(range: NSRange(location: location, length: 0), in: text)
    }

    /// Fast: uses pre-parsed tokens
    static func isInsideCodeBlock(range: NSRange, codeTokens: [MarkdownToken]) -> Bool {
        guard !codeTokens.isEmpty else { return false }
        for token in codeTokens {
            let start = token.range.location
            let end = start + token.range.length
            if range.length == 0 {
                if range.location >= start && range.location <= end { return true }
            } else {
                if range.location < end && range.location + range.length > start { return true }
            }
        }
        return false
    }

    static func isInsideCodeBlock(location: Int, codeTokens: [MarkdownToken]) -> Bool {
        isInsideCodeBlock(range: NSRange(location: location, length: 0), codeTokens: codeTokens)
    }

    // MARK: - LaTeX Detection

    static func isInsideLatex(location: Int, in text: String) -> Bool {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let latexTokens = tokens.filter { $0.kind == .inlineLatex || $0.kind == .blockLatex }
        return isInsideLatex(location: location, latexTokens: latexTokens)
    }

    static func isInsideLatex(location: Int, latexTokens: [MarkdownToken]) -> Bool {
        guard !latexTokens.isEmpty else { return false }
        for token in latexTokens {
            let start = token.range.location
            let end = start + token.range.length
            if location >= start && location <= end { return true }
        }
        return false
    }

}
