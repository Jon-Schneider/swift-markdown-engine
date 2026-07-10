//
//  MarkdownUITextView+PendingAttachments.swift
//  MarkdownEngine
//
//  iOS side of the async attachment disposition (`AttachmentDisposition.pending`). Mirrors the
//  macOS coordinator: owns the in-flight placeholder markers, resolves/cancels them at their
//  ORIGINAL drop point without disturbing the user's live selection, and enforces the backstop
//  timeout. See `PendingAttachment.swift` for the marker/resolver model.
//
#if canImport(UIKit)
import UIKit

extension MarkdownUITextView: PendingAttachmentHost {
    /// Arm `resolver` for a freshly inserted placeholder and start its backstop timeout. Called
    /// from the drop path once the marker string has been handed to UIKit for insertion.
    @MainActor
    func registerPendingAttachment(
        _ resolver: AttachmentResolver,
        for item: DroppedItem,
        id: UUID,
        timeout: TimeInterval = PendingAttachmentMarker.defaultTimeout
    ) {
        let work = DispatchWorkItem { [weak self] in self?.cancelPendingMarker(id) }
        pendingAttachmentResolvers[id] = PendingAttachmentEntry(resolver: resolver, item: item, timeout: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        // Defer arming to the next runloop. On iOS the placeholder marker is inserted by UIKit AFTER
        // this call returns (via `UITextPasteItem.setResult`), so arming synchronously would let a
        // resolve that arrives immediately — a host that resolves inside `onDropAttachment`, or a
        // very fast staging `Task` — re-tokenize a buffer that has no marker yet and orphan the chip.
        // By the next main-queue hop the marker is in place; a resolve arriving in the gap is buffered
        // by the resolver and flushed here. (macOS arms synchronously because it inserts the marker
        // itself before registering.)
        DispatchQueue.main.async { [weak self, weak resolver] in
            guard let self, let resolver else { return }
            resolver.arm(host: self, id: id)
        }
    }

    @discardableResult
    @MainActor
    func resolvePendingMarker(_ id: UUID, with reference: String) -> Bool {
        guard let entry = pendingAttachmentResolvers[id] else { return false }
        entry.timeout?.cancel()
        pendingAttachmentResolvers[id] = nil
        guard let range = pendingMarkerRange(for: id) else { return false }
        let replacement = PendingAttachmentMarker.blockPaddedReplacement(
            entry.item.markdown(forReference: reference),
            isImage: entry.item.isImage,
            in: textStorage.string as NSString, at: range
        )
        return applyPendingReplacement(range: range, with: replacement)
    }

    @MainActor
    func cancelPendingMarker(_ id: UUID) {
        guard let entry = pendingAttachmentResolvers[id] else { return }
        entry.timeout?.cancel()
        pendingAttachmentResolvers[id] = nil
        guard let range = pendingMarkerRange(for: id) else { return }
        applyPendingReplacement(range: range, with: "")
    }

    /// Drop all resolvers and timers WITHOUT touching the buffer — used when the buffer is about to
    /// be replaced wholesale (`render`) or torn down (deinit). Late resolver calls no-op via the
    /// resolver's weak host.
    func cancelAllPendingAttachments() {
        pendingAttachmentResolvers.values.forEach { $0.timeout?.cancel() }
        pendingAttachmentResolvers.removeAll()
    }

    /// Find the live range of the placeholder for `id` by re-tokenizing (robust to the marker
    /// having moved as the user edited, and to odd filenames). Matches the `.imageLink` token whose
    /// URL is the pending scheme + this UUID.
    func pendingMarkerRange(for id: UUID) -> NSRange? {
        let target = PendingAttachmentMarker.scheme + id.uuidString
        let ns = textStorage.string as NSString
        for token in MarkdownTokenizer.parseTokensViaAST(in: textStorage.string)
        where token.kind == .imageLink {
            guard token.markerRanges.count >= 4 else { continue }
            let urlStart = NSMaxRange(token.markerRanges[2])
            let urlLength = token.markerRanges[3].location - urlStart
            guard urlLength > 0 else { continue }
            if ns.substring(with: NSRange(location: urlStart, length: urlLength)) == target {
                return token.range
            }
        }
        return nil
    }

    /// Replace `range` with `replacement` through the undoable edit path, preserving the user's
    /// live selection (shifted only when the edit lies before it) rather than parking the caret at
    /// the insertion — the caret-theft this feature exists to prevent.
    /// Returns whether the replacement was actually applied (`false` on an out-of-range edit or a
    /// read-only view — `applyUndoableEdit` no-ops when `!isEditable` — so a caller reports the
    /// reference as unhandled rather than silently dropped).
    @MainActor
    @discardableResult
    private func applyPendingReplacement(range: NSRange, with replacement: String) -> Bool {
        let currentLength = (textStorage.string as NSString).length
        guard isEditable, range.location != NSNotFound, NSMaxRange(range) <= currentLength else { return false }
        let newLength = currentLength - range.length + (replacement as NSString).length
        let adjusted = PendingAttachmentMarker.adjustedSelection(
            selectedRange,
            editRange: range,
            replacementLength: (replacement as NSString).length,
            maxLength: newLength
        )
        applyUndoableEdit(replacing: range, with: replacement, finalSelection: adjusted)
        return true
    }
}
#endif
