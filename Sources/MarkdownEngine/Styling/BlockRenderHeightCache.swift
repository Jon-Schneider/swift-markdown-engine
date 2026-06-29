//
//  BlockRenderHeightCache.swift
//  MarkdownEngine
//
//  Per-editor cache of a rendered standalone block's footprint height, keyed by its (trimmed)
//  source + font size. Plan 1.2: when a block-LaTeX is revealed in seamless mode (the reveal
//  hole), its rendered formula is replaced by the raw `$$…$$` source — which is usually a
//  different height, so the block would collapse/grow and jump the content below. The block-LaTeX
//  styler WRITES the measured formula height here whenever it renders the image, and READS it when
//  the block is revealed to reserve that height. The same machinery serves narrow tables (plan 1.1
//  follow-up).
//
//  Lookup-only on the reveal path: a miss (the source was edited since it last rendered, or never
//  rendered) just means no reservation — the revealed source flows at its natural height. So
//  editing a revealed block never triggers a re-render purely to measure, and the reservation is
//  stable across the enter/exit transition (when the source is unchanged).
//
//  Width-dependent blocks: a table's reveal reservation is valid only while the table is NARROW at
//  the current container width (a wide table's revealed source wraps and its rendered footprint adds
//  a scroller strip, so a single height can't be reserved across it). The entry therefore records the
//  block's intrinsic `contentWidth`; the width-aware lookup rejects it once the container is narrower
//  than that — so a resize/rotation that turns a narrow table wide stops reserving WITHOUT needing the
//  table to re-render first (the macOS width-change restyle doesn't re-render narrow tables). Blocks
//  with no width dependence (block LaTeX) store `contentWidth == nil` and use the plain lookup.
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
    private struct Entry {
        let height: CGFloat
        /// Intrinsic rendered width of the block, for width-dependent reveal validity
        /// (tables). `nil` for blocks whose reveal is valid at any width (block LaTeX).
        let contentWidth: CGFloat?
    }

    private var entries: [Key: Entry] = [:]
    /// Soft bound, sized well beyond any realistic document's distinct-block count. On overflow
    /// the whole map is cleared (heights are cheap to recompute — re-stored on the next render of
    /// each block). A pathological doc with more distinct blocks than this could clear entries
    /// mid-restyle, degrading some reservations to natural reflow — never a crash.
    private let capacity = 4096

    /// Height for a width-INDEPENDENT block (block LaTeX): the stored height regardless of any
    /// recorded content width.
    func height(forSource source: String, fontSize: CGFloat) -> CGFloat? {
        entries[Key(source: source, fontSize: fontSize)]?.height
    }

    /// Height for a width-DEPENDENT block (a table): valid only while the block is still narrow at
    /// the current container width. Returns `nil` when the recorded `contentWidth` exceeds
    /// `maxContentWidth` (the block is now wide — e.g. after a resize/rotation — so its narrow
    /// reservation no longer applies), without the block needing to re-render first.
    func height(forSource source: String, fontSize: CGFloat, maxContentWidth: CGFloat) -> CGFloat? {
        guard let entry = entries[Key(source: source, fontSize: fontSize)] else { return nil }
        if let width = entry.contentWidth, width > maxContentWidth + 0.5 { return nil }
        return entry.height
    }

    func store(height: CGFloat, forSource source: String, fontSize: CGFloat, contentWidth: CGFloat? = nil) {
        guard height > 0 else { return }
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[Key(source: source, fontSize: fontSize)] = Entry(height: height, contentWidth: contentWidth)
    }
}
