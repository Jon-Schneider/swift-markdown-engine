//
//  BlockRenderHeightCacheTests.swift
//  MarkdownEngineTests
//
//  Unit tests for the per-editor rendered-block height cache used by the seamless
//  reveal-height reservation (block LaTeX, plan 1.2; narrow tables, plan 1.1 follow-up).
//

import Foundation
import CoreGraphics
import Testing
@testable import MarkdownEngine

@Suite("BlockRenderHeightCache")
struct BlockRenderHeightCacheTests {

    @Test("Stores and reads back a height for a (source, fontSize) key")
    func storeAndRead() {
        let cache = BlockRenderHeightCache()
        cache.store(height: 42, forSource: "$$x$$", fontSize: 17)
        #expect(cache.height(forSource: "$$x$$", fontSize: 17) == 42)
    }

    @Test("A miss returns nil")
    func miss() {
        let cache = BlockRenderHeightCache()
        #expect(cache.height(forSource: "never", fontSize: 17) == nil)
    }

    @Test("The key is qualified by font size")
    func fontSizeQualifiesKey() {
        let cache = BlockRenderHeightCache()
        cache.store(height: 42, forSource: "$$x$$", fontSize: 17)
        #expect(cache.height(forSource: "$$x$$", fontSize: 20) == nil)
    }

    @Test("A non-positive height is not stored (guards a degenerate render)")
    func nonPositiveHeightIgnored() {
        let cache = BlockRenderHeightCache()
        cache.store(height: 0, forSource: "z", fontSize: 17)
        cache.store(height: -5, forSource: "z", fontSize: 17)
        #expect(cache.height(forSource: "z", fontSize: 17) == nil)
    }

    @Test("Width-aware lookup reserves while the block is narrow at the current width")
    func widthAwareLookupNarrow() {
        let cache = BlockRenderHeightCache()
        // A table rendered with intrinsic content width 300.
        cache.store(height: 100, forSource: "| a | b |", fontSize: 17, contentWidth: 300)
        // Container 360 ≥ 300 → still narrow → the height is reservable.
        #expect(cache.height(forSource: "| a | b |", fontSize: 17, maxContentWidth: 360) == 100)
    }

    @Test("Width-aware lookup rejects once the block is wider than the container (resize→wide)")
    func widthAwareLookupRejectsWide() {
        let cache = BlockRenderHeightCache()
        cache.store(height: 100, forSource: "| a | b |", fontSize: 17, contentWidth: 300)
        // After a shrink to 250 < 300 the table is now wide → the narrow reservation
        // must be rejected WITHOUT the table re-rendering, so the reveal reflows naturally.
        #expect(cache.height(forSource: "| a | b |", fontSize: 17, maxContentWidth: 250) == nil)
    }

    @Test("A width-independent entry (block LaTeX, no contentWidth) ignores the width gate")
    func widthIndependentEntryAlwaysReservable() {
        let cache = BlockRenderHeightCache()
        cache.store(height: 80, forSource: "$$x$$", fontSize: 17)   // contentWidth defaults to nil
        // Even a tiny container doesn't reject it — block LaTeX reveal is width-independent.
        #expect(cache.height(forSource: "$$x$$", fontSize: 17, maxContentWidth: 10) == 80)
        // And the plain (width-unaware) lookup still returns it.
        #expect(cache.height(forSource: "$$x$$", fontSize: 17) == 80)
    }

    @Test("A later store overwrites an earlier height for the same key")
    func storeOverwrites() {
        let cache = BlockRenderHeightCache()
        cache.store(height: 50, forSource: "k", fontSize: 17)
        cache.store(height: 75, forSource: "k", fontSize: 17)
        #expect(cache.height(forSource: "k", fontSize: 17) == 75)
    }
}
