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
    /// never reveal in seamless — that is the whole point of the mode.
    ///
    /// 1.1 (tables) will add `.table` here, but that's NOT sufficient on its own: tables need the
    /// container→inline-cell propagation that today lives only in the reveal-on-edit branch
    /// (`activeContainers` below), and the ranged-selection rule for tables should match that
    /// branch. Adding `.table` here reveals the table's outer source but not its cells — 1.1 must
    /// extend the seamless path accordingly.
    static let seamlessRevealableBlockKinds: Set<MarkdownTokenKind> = [.blockLatex]

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
            // entered (block LaTeX today; tables via 1.1), whose raw source must reveal so it can
            // be edited. Inline rendered runs stay hidden.
            return tokenIndices(touching: selectionRange, in: tokens, text: text,
                                where: { seamlessRevealableBlockKinds.contains($0.kind) })
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

        // When a container token (e.g. a table) is active, every inline token inside it becomes active too.
        let activeContainers: [MarkdownToken] = indices.compactMap { idx in
            let token = tokens[idx]
            return token.kind == .table ? token : nil
        }
        if !activeContainers.isEmpty {
            for (i, token) in tokens.enumerated() where !indices.contains(i) {
                let tStart = token.range.location
                let tEnd = NSMaxRange(token.range)
                if activeContainers.contains(where: {
                    tStart >= $0.range.location && tEnd <= NSMaxRange($0.range)
                }) {
                    indices.insert(i)
                }
            }
        }
        return indices
    }

    /// Indices of tokens matching `predicate` that the selection touches: a ranged selection that
    /// overlaps the token, a caret strictly inside it, or a zero-length caret resting at a
    /// non-newline trailing edge. The seamless reveal hole uses this over a restricted set of block
    /// kinds. NOTE: this mirrors — but does not share — the reveal-on-edit branch's per-token
    /// containment; that branch additionally gates the intersection rule to LaTeX only and
    /// propagates active containers to their inline children. Keep the two in mind together if you
    /// change containment semantics (see `seamlessRevealableBlockKinds`).
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
