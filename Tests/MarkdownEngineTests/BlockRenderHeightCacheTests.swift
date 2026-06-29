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

    @Test("remove evicts a cached height (the narrow→wide table invalidation path)")
    func removeEvicts() {
        let cache = BlockRenderHeightCache()
        cache.store(height: 100, forSource: "| a | b |", fontSize: 17)
        #expect(cache.height(forSource: "| a | b |", fontSize: 17) == 100)
        // A table that re-renders wide evicts its stale narrow height so the reveal
        // path misses (→ natural reflow) instead of reserving the wrong footprint.
        cache.remove(forSource: "| a | b |", fontSize: 17)
        #expect(cache.height(forSource: "| a | b |", fontSize: 17) == nil)
    }

    @Test("remove of an absent key is a harmless no-op")
    func removeAbsentIsNoOp() {
        let cache = BlockRenderHeightCache()
        cache.remove(forSource: "absent", fontSize: 17)   // must not crash
        #expect(cache.height(forSource: "absent", fontSize: 17) == nil)
    }

    @Test("A later store overwrites an earlier height for the same key")
    func storeOverwrites() {
        let cache = BlockRenderHeightCache()
        cache.store(height: 50, forSource: "k", fontSize: 17)
        cache.store(height: 75, forSource: "k", fontSize: 17)
        #expect(cache.height(forSource: "k", fontSize: 17) == 75)
    }
}
