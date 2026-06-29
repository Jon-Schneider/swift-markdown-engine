//
//  BlockRenderHeightCache.swift
//  MarkdownEngine
//
//  Per-editor cache of a rendered standalone block's footprint height, keyed by its (trimmed)
//  source + font size. Plan 1.2: when a block-LaTeX is revealed in seamless mode (the reveal
//  hole), its rendered formula is replaced by the raw `$$…$$` source — which is usually a
//  different height, so the block would collapse/grow and jump the content below. The block-LaTeX
//  styler WRITES the measured formula height here whenever it renders the image, and READS it when
//  the block is revealed to reserve that height.
//
//  Lookup-only on the reveal path: a miss (the source was edited since it last rendered, or never
//  rendered) just means no reservation — the revealed source flows at its natural height. So
//  editing a revealed block never triggers a re-render purely to measure, and the reservation is
//  stable across the enter/exit transition (when the source is unchanged).
//

import CoreGraphics

/// Not thread-safe by design: all four styling call sites (`MarkdownStyler.styleAttributes` and
/// `TextStylingService.restyle`, from the iOS view and the macOS coordinator) run synchronously on
/// the main thread, so reads/writes never race. (The `DispatchQueue.main.async` blocks in the
/// restyle paths are post-layout reconcile, not styling.)
final class BlockRenderHeightCache {
    private struct Key: Hashable {
        let source: String
        let fontSize: CGFloat
    }

    private var heights: [Key: CGFloat] = [:]
    /// Soft bound, sized well beyond any realistic document's distinct-formula count. On overflow
    /// the whole map is cleared (heights are cheap to recompute — re-stored on the next render of
    /// each block). A pathological doc with more distinct formulas than this could clear entries
    /// mid-restyle, degrading some reservations to natural reflow — never a crash.
    private let capacity = 4096

    func height(forSource source: String, fontSize: CGFloat) -> CGFloat? {
        heights[Key(source: source, fontSize: fontSize)]
    }

    func store(height: CGFloat, forSource source: String, fontSize: CGFloat) {
        guard height > 0 else { return }
        if heights.count >= capacity { heights.removeAll(keepingCapacity: true) }
        heights[Key(source: source, fontSize: fontSize)] = height
    }

    /// Evict a cached height. Used when a block can no longer reserve safely (e.g. a
    /// table that previously rendered narrow now renders wide): the key is only
    /// source+fontSize, so without an explicit eviction the stale narrow height would
    /// be reserved on reveal after a width change.
    func remove(forSource source: String, fontSize: CGFloat) {
        heights[Key(source: source, fontSize: fontSize)] = nil
    }
}
