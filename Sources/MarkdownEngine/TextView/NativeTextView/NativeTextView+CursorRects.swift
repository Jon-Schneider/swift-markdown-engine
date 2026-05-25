//
//  NativeTextView+CursorRects.swift
//  MarkdownEngine
//
//  Read-only cursor handling.
//
//  Since PR #31/#32 the text view is always `isSelectable = true` (so links
//  stay clickable when `isEditable == false`). A selectable NSTextView shows
//  the I-beam over its text — unwanted in read-only previews.
//
//  NSTextView installs a tracking area with .mouseMoved/.cursorUpdate and sets
//  the I-beam from its mouseMoved handler. Its .cursorUpdate path does not
//  reach an override, and plain cursor rects lose to that runtime cursor set
//  (confirmed via logging). So we override mouseMoved/mouseEntered and set the
//  cursor ourselves AFTER super — arrow over text, pointing hand over links.
//  In edit mode we leave NSTextView's I-beam untouched.
//

import AppKit

extension NativeTextView {

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        applyReadOnlyCursor(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        applyReadOnlyCursor(for: event)
    }

    /// In read-only mode, override NSTextView's I-beam: pointing hand over a
    /// `.link` range, arrow everywhere else.
    private func applyReadOnlyCursor(for event: NSEvent) {
        guard isSelectable, !isEditable else { return }      // edit mode: keep I-beam
        let viewPoint = convert(event.locationInWindow, from: nil)
        if isOverLink(at: viewPoint) {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// True when a clickable `.link` attribute exists under the given point
    /// (view coordinates). `.link` is what drives `clickedOnLink`, so this
    /// matches exactly what is clickable.
    private func isOverLink(at viewPoint: CGPoint) -> Bool {
        guard let tlm = textLayoutManager,
              let textStorage = textStorage, textStorage.length > 0 else { return false }

        let containerPoint = CGPoint(x: viewPoint.x - textContainerOrigin.x,
                                     y: viewPoint.y - textContainerOrigin.y)
        guard let fragment = tlm.textLayoutFragment(for: containerPoint) else { return false }

        let fragFrame = fragment.layoutFragmentFrame
        let pInFrag = CGPoint(x: containerPoint.x - fragFrame.minX,
                              y: containerPoint.y - fragFrame.minY)
        // Only accept a line fragment that actually contains the point — guards
        // against clicks in trailing padding / past the end of a line.
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.contains(pInFrag) }) else { return false }

        let pInLine = CGPoint(x: pInFrag.x - line.typographicBounds.minX,
                              y: pInFrag.y - line.typographicBounds.minY)
        let idx = line.characterIndex(for: pInLine)
        let lineString = line.attributedString
        guard idx >= 0, idx < lineString.length else { return false }
        return lineString.attribute(.link, at: idx, effectiveRange: nil) != nil
    }
}
