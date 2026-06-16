//
//  ClampedScrollView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Scroll view that keeps vertical scrolling within a clean top and bottom range.
import AppKit

final class ClampedScrollView: NSScrollView {
    /// Saved at the start of every live-resize (including spurious one-click resizes triggered by edge-cursor clicks) so the position is restored when the resize ends. Without this, NSScrollView's default top-anchor-during-resize would jolt a bottom-anchored user back up by hundreds of points on a single edge click.
    private var scrollYBeforeLiveResize: CGFloat?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        clampToInsets()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        scrollYBeforeLiveResize = contentView.bounds.origin.y
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if let y = scrollYBeforeLiveResize {
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: y))
            reflectScrolledClipView(contentView)
            clampToInsets()
        }
        scrollYBeforeLiveResize = nil
    }

    func clampToInsets() {
        guard let doc = documentView else { return }
        let minY = -contentInsets.top
        // Use the real content height (not the inflated frame) so small
        // documents can't scroll past their actual content. The document view is
        // always a `NativeTextViewContainer` (header band + text column).
        let container = doc as? NativeTextViewContainer
        var realHeight = container?.scrollableContentHeight ?? doc.bounds.height
        let b = contentView.bounds

        // `scrollableContentHeight` comes from a cached TextKit-2 measurement that can
        // under-measure. A continuous trackpad refreshes it mid-gesture, but a discrete
        // device (mouse wheel, Ploopy trackball) sends one event with no relayout — so a
        // stale-small height clamps the tick straight back = "scroll doesn't work". When
        // a clamp-back is imminent, force one fresh full-layout re-measure first. This is
        // self-limiting (only at the bottom) and still clamps to the real content height.
        if let textView = container?.textView,
           b.origin.y > realHeight - b.height {
            textView.pendingFullLayoutMeasure = true
            textView.recalcOverscroll(for: self)
            realHeight = container?.scrollableContentHeight ?? doc.bounds.height
        }

        let maxY = max(minY, realHeight - contentView.bounds.height)
        let clampedY = min(max(b.origin.y, minY), maxY)
        if clampedY != b.origin.y {
            contentView.scroll(to: NSPoint(x: b.origin.x, y: clampedY))
            reflectScrolledClipView(contentView)
        }
    }
}
