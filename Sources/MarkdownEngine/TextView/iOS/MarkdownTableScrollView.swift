//
//  MarkdownTableScrollView.swift
//  MarkdownEngine
//
//  iOS horizontal-scroll overlay for wide GFM tables — the UIKit analog of the macOS
//  `WideTableOverlay` (NSScrollView). A wide table is rendered to a single image whose
//  natural width exceeds the text column; the styler emits it as a clipped block tagged
//  with `.scrollableBlock*` attributes, and the layout fragment SKIPS drawing it
//  (`scrollableBlockNaturalWidth` is its cue), reserving blank space. This overlay sits
//  over that space, hosts the full-width image, and provides native horizontal scrolling.
//
//  It's added as a subview of the `MarkdownUITextView` (itself a `UIScrollView`), so it
//  lives in content coordinates and scrolls vertically with the text automatically. Its
//  own content overflows only horizontally, so vertical pans propagate to the text view
//  (the standard nested horizontal-in-vertical scroll behavior) while horizontal pans
//  scroll the table.
//

#if canImport(UIKit)
import UIKit

// MARK: - Overlay view

final class MarkdownTableScrollView: UIScrollView, UIScrollViewDelegate {

    /// Hash of the table source; key for offset persistence + reconcile lookup.
    let sourceID: Int

    /// Document index of the table anchor; a tap on the image moves the caret here
    /// (which makes the table "active" → it re-renders as editable source).
    var anchorTextLocation: Int

    /// Weak parent ref for offset persistence + caret forwarding.
    private weak var ownerTextView: MarkdownUITextView?

    private let tableImageView: UIImageView

    init(sourceID: Int, image: PlatformImage, ownerTextView: MarkdownUITextView, anchorLocation: Int) {
        self.sourceID = sourceID
        self.anchorTextLocation = anchorLocation
        self.ownerTextView = ownerTextView
        self.tableImageView = UIImageView(image: image)

        super.init(frame: .zero)

        tableImageView.frame = CGRect(origin: .zero, size: image.size)
        tableImageView.contentMode = .topLeft
        addSubview(tableImageView)
        contentSize = image.size

        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = false
        // Content overflows only horizontally → the vertical axis has no scroll room, so
        // vertical pans bubble up to the text view. `alwaysBounceHorizontal` keeps the
        // horizontal gesture engaged even for a barely-overflowing table.
        alwaysBounceHorizontal = true
        alwaysBounceVertical = false
        // Don't let safe-area / keyboard insets shift the table image.
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        delegate = self

        // A tap drops the caret into the table (switching it to editable source mode).
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Swap the rendered image after a restyle regenerated it (theme / Dynamic Type),
    /// preserving the current scroll offset.
    func updateImage(_ image: PlatformImage) {
        guard tableImageView.image !== image else { return }
        tableImageView.image = image
        tableImageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
    }

    var horizontalOffset: CGFloat {
        get { contentOffset.x }
        set { contentOffset = CGPoint(x: max(0, newValue), y: 0) }
    }

    @objc private func handleTap() {
        guard let owner = ownerTextView else { return }
        let docLength = (owner.text as NSString).length
        let location = max(0, min(anchorTextLocation, docLength))
        owner.becomeFirstResponder()
        // Moving the caret into the table triggers a restyle; the table becomes active
        // (source shown, no `.scrollableBlock*` attrs) and the reconcile removes this overlay.
        owner.selectedRange = NSRange(location: location, length: 0)
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        ownerTextView?.tableHorizontalScrollOffsets[sourceID] = contentOffset.x
    }
}

// MARK: - MarkdownUITextView reconcile

extension MarkdownUITextView {

    /// Coalesce overlay reconciles to one per runloop tick (restyle/layout can fire
    /// bursts). The first run (no overlays yet) is synchronous to avoid a load-time flash.
    func updateTableScrollOverlays() {
        if tableScrollOverlays.isEmpty {
            performTableScrollOverlayUpdate()
            return
        }
        if pendingTableScrollOverlayUpdate { return }
        pendingTableScrollOverlayUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingTableScrollOverlayUpdate = false
            self.performTableScrollOverlayUpdate()
        }
    }

    /// Walk storage; create / position / destroy overlays to match the `.scrollableBlock*` attrs.
    func performTableScrollOverlayUpdate() {
        guard let layoutBridge, let tlm = textLayoutManager else {
            removeAllTableScrollOverlays()
            return
        }
        let storage = textStorage
        let container = textContainer
        let containerWidth = container.size.width
        guard containerWidth.isFinite, containerWidth > 0 else { return }

        let fullRange = NSRange(location: 0, length: storage.length)

        // Cheap presence-check first: skip the full-document layout pass when the doc has
        // no wide tables. enumerateAttribute stops on the first hit.
        var hasAnyWideTable = false
        storage.enumerateAttribute(.scrollableBlockSourceID, in: fullRange, options: []) { value, _, stop in
            if value is Int { hasAnyWideTable = true; stop.pointee = true }
        }
        guard hasAnyWideTable else {
            removeAllTableScrollOverlays()
            return
        }

        // Settle layout before measuring — stale fragments would yield wrong anchor rects.
        tlm.ensureLayout(for: tlm.documentRange)

        var seenSourceIDs: Set<Int> = []
        storage.enumerateAttribute(.scrollableBlockSourceID, in: fullRange, options: []) { value, attrRange, _ in
            guard let sourceID = value as? Int,
                  let image = storage.attribute(.latexImage, at: attrRange.location, effectiveRange: nil) as? PlatformImage
            else { return }
            seenSourceIDs.insert(sourceID)

            let anchorRect = layoutBridge.boundingRect(forCharacterRange: attrRange, in: container)
            guard !anchorRect.isEmpty else { return }

            let totalHeight = (storage.attribute(.scrollableBlockTotalHeight, at: attrRange.location, effectiveRange: nil) as? CGFloat)
                ?? image.size.height
            // boundingRect is in container coords; add the text container inset to reach
            // the view's content coordinate space (where this overlay subview lives).
            let overlayFrame = CGRect(
                x: textContainerInset.left + anchorRect.minX,
                y: textContainerInset.top + anchorRect.minY,
                width: containerWidth,
                height: totalHeight
            )

            if let existing = tableScrollOverlays[sourceID] {
                if !existing.frame.equalTo(overlayFrame) { existing.frame = overlayFrame }
                existing.updateImage(image)
                existing.anchorTextLocation = attrRange.location
            } else {
                let overlay = MarkdownTableScrollView(
                    sourceID: sourceID, image: image,
                    ownerTextView: self, anchorLocation: attrRange.location
                )
                overlay.frame = overlayFrame
                addSubview(overlay)
                tableScrollOverlays[sourceID] = overlay
                let savedOffset = tableHorizontalScrollOffsets[sourceID] ?? 0
                if savedOffset > 0 { overlay.horizontalOffset = savedOffset }
            }
        }

        for (sourceID, overlay) in tableScrollOverlays where !seenSourceIDs.contains(sourceID) {
            overlay.removeFromSuperview()
            tableScrollOverlays.removeValue(forKey: sourceID)
        }
    }

    /// Drop all overlays synchronously (document reset / no-wide-table path).
    func removeAllTableScrollOverlays() {
        for (_, overlay) in tableScrollOverlays { overlay.removeFromSuperview() }
        tableScrollOverlays.removeAll()
    }
}
#endif
