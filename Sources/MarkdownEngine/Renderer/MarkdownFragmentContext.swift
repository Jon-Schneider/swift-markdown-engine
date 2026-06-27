//
//  MarkdownFragmentContext.swift
//  MarkdownEngine
//
//  Per-fragment rendering inputs that `MarkdownTextLayoutFragment`'s draw helpers
//  historically read directly off `NativeTextView` (via the macOS-only chain
//  `NSTextContainer.textView as? NativeTextView`). Neither `NSTextContainer.textView`
//  nor `NativeTextView` exists on iOS, so the fragment cannot reach a concrete view
//  type there. Instead the layout-manager delegate injects this context onto each
//  fragment, and the helpers query it.
//
//  It is a reference type queried *live* at draw time — selection and display scale
//  change after a fragment is created, so a value snapshot would go stale.
//
//  On macOS, `NativeTextView` itself conforms (below), reproducing the exact
//  expressions the helpers used before, so this indirection is behavior-neutral.
//  On iOS (Phase 2) the UITextView subclass will conform.
//

import Foundation

protocol MarkdownFragmentContext: AnyObject {
    /// Source of the active theme, syntax-highlighter, and paragraph metrics.
    var configuration: MarkdownEditorConfiguration { get }
    /// The editor's base body font — fallback when a run carries no explicit font.
    var baseFont: PlatformFont { get }
    /// Layout bridge used by the delegate to seed trailing-line metrics (FB15131180).
    var layoutBridge: LayoutBridge? { get }
    /// Document-level selected ranges with length > 0. A marker intersecting one of
    /// these is left undecorated so its highlighted raw character stays visible.
    var selectedDocumentRanges: [NSRange] { get }
    /// Backing/display scale used to pixel-snap fills and checkbox boxes.
    var displayScale: CGFloat { get }
}

#if os(macOS)
import AppKit

extension NativeTextView: MarkdownFragmentContext {
    /// Matches the historical `tv.selectedRanges.map { $0.rangeValue }.filter { $0.length > 0 }`.
    var selectedDocumentRanges: [NSRange] {
        selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
    }

    /// Matches the historical `window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0`.
    var displayScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }
}
#endif
