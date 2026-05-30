//
//  BlockScopedTokenizer.swift
//  MarkdownEngine
//
//  The live tokenization pipeline. For each block from `BlockParser`:
//  block-level tokens (heading, blockquote, table, block LaTeX, code) come from
//  `BlockLevelTokenizer` (hand scanners, no regex), while ALL inline tokens come
//  from the AST (`InlineParser` → `InlineASTAdapter`). Results are offset back
//  into document coordinates. Fenced-code blocks emit only their code-block
//  token (no inline markup inside).
//

import Foundation

extension MarkdownTokenizer {

    /// Per-block memoization: a block's substring → its block-RELATIVE tokens.
    /// Per keystroke only the edited block's substring changes, so every other
    /// block hits the cache and only the edited one is re-parsed — O(change)
    /// instead of O(document). FIFO-capped so it can't grow unbounded; locked
    /// because indexing may tokenize off the main thread.
    private static let blockTokenLock = NSLock()
    private static var blockTokenCache: [String: [MarkdownToken]] = [:]
    private static var blockTokenOrder: [String] = []
    private static let blockTokenCacheCap = 4096

    /// The live tokenizer: legacy block-level tokens + inline AST tokens.
    /// Opaque fenced-code blocks emit only their code-block token (no inline
    /// markup inside — fixes the "inline parsed inside a code block" bug).
    static func parseTokensViaAST(in text: String) -> [MarkdownToken] {
        let ns = text as NSString
        var result: [MarkdownToken] = []
        for block in BlockParser.parse(text) {
            let delta = block.range.location
            let relTokens = cachedBlockTokens(kind: block.kind, sub: ns.substring(with: block.range))
            result.append(contentsOf: relTokens.map { $0.shifted(by: delta) })
        }
        return result
    }

    /// Cached block-relative tokens for `sub` (computed on miss). The token
    /// logic is unchanged — this only memoizes it.
    private static func cachedBlockTokens(kind: BlockKind, sub: String) -> [MarkdownToken] {
        blockTokenLock.lock()
        if let cached = blockTokenCache[sub] {
            blockTokenLock.unlock()
            return cached
        }
        blockTokenLock.unlock()

        let blockLevel = BlockLevelTokenizer.tokens(for: kind, in: sub as NSString)
        // Fenced code is opaque — no inline markup inside it.
        let inline = kind == .fencedCode
            ? []
            : InlineASTAdapter.tokens(from: InlineParser.parse(sub))
        let computed = blockLevel + inline

        blockTokenLock.lock()
        if blockTokenCache[sub] == nil {
            blockTokenCache[sub] = computed
            blockTokenOrder.append(sub)
            if blockTokenOrder.count > blockTokenCacheCap {
                blockTokenCache[blockTokenOrder.removeFirst()] = nil
            }
        }
        blockTokenLock.unlock()
        return computed
    }
}

private extension MarkdownToken {
    /// Returns a copy with every range moved forward by `delta` UTF-16 units.
    func shifted(by delta: Int) -> MarkdownToken {
        func move(_ r: NSRange) -> NSRange {
            NSRange(location: r.location + delta, length: r.length)
        }
        return MarkdownToken(
            kind: kind,
            range: move(range),
            contentRange: move(contentRange),
            markerRanges: markerRanges.map(move)
        )
    }
}
