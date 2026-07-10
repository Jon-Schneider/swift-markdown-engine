#if os(macOS)
//
//  NativeTextViewCoordinator+PendingAttachments.swift
//  MarkdownEngine
//
//  macOS side of the async attachment disposition (`AttachmentDisposition.pending`). Owns the
//  in-flight placeholder markers, resolves/cancels them at their ORIGINAL drop point without
//  disturbing the user's live selection, and enforces the backstop timeout. See
//  `PendingAttachment.swift` for the marker/resolver model.
//

import AppKit

extension NativeTextViewCoordinator: PendingAttachmentHost {
    /// Arm `resolver` for a freshly inserted placeholder and start its backstop timeout. Called
    /// synchronously from the drop path right after the marker is spliced in.
    @MainActor
    func registerPendingAttachment(
        _ resolver: AttachmentResolver,
        for item: DroppedItem,
        id: UUID,
        timeout: TimeInterval = PendingAttachmentMarker.defaultTimeout
    ) {
        let work = DispatchWorkItem { [weak self] in self?.cancelPendingMarker(id) }
        pendingAttachmentResolvers[id] = PendingAttachmentEntry(resolver: resolver, item: item, timeout: work)
        // Schedule BEFORE arming so a resolver that flushes a buffered insert/cancel during `arm`
        // can cancel this exact work item rather than leaking a stray timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        resolver.arm(host: self, id: id)
    }

    @discardableResult
    @MainActor
    func resolvePendingMarker(_ id: UUID, with reference: String) -> Bool {
        guard let entry = pendingAttachmentResolvers[id] else { return false }
        guard let textView, let range = pendingMarkerRange(for: id, in: textView) else {
            // Marker already gone (undone / never inserted): nothing to place. Drop the entry.
            dropPendingEntry(id)
            return false
        }
        let replacement = PendingAttachmentMarker.blockPaddedReplacement(
            entry.item.markdown(forReference: reference),
            isImage: entry.item.isImage,
            in: textView.string as NSString, at: range
        )
        // Only consume the entry (and cancel its backstop timeout) once the edit actually applied.
        // On a read-only view `applyPendingReplacement` no-ops; keeping the entry + timeout lets a
        // later editable moment (or the timeout) clean the chip up instead of stranding it forever.
        guard applyPendingReplacement(range: range, with: replacement, actionName: "Insert Attachment", to: textView) else {
            return false
        }
        dropPendingEntry(id)
        return true
    }

    @MainActor
    func cancelPendingMarker(_ id: UUID) {
        guard pendingAttachmentResolvers[id] != nil else { return }
        guard let textView, let range = pendingMarkerRange(for: id, in: textView) else {
            dropPendingEntry(id)
            return
        }
        // Same retain-until-applied rule as resolve, so a read-only view doesn't leave a stuck chip.
        guard applyPendingReplacement(range: range, with: "", actionName: "Remove Attachment", to: textView) else { return }
        dropPendingEntry(id)
    }

    private func dropPendingEntry(_ id: UUID) {
        pendingAttachmentResolvers[id]?.timeout?.cancel()
        pendingAttachmentResolvers[id] = nil
    }

    /// Drop all resolvers and their timers WITHOUT touching the buffer — used when the buffer is
    /// about to be replaced wholesale (document reset) or torn down (deinit), so the markers vanish
    /// on their own and any late resolver call no-ops via its weak host.
    func cancelAllPendingAttachments() {
        pendingAttachmentResolvers.values.forEach { $0.timeout?.cancel() }
        pendingAttachmentResolvers.removeAll()
    }

    /// Find the live range of the placeholder for `id` by re-tokenizing (robust to the marker
    /// having moved as the user edited, and to odd filenames). Matches the `.imageLink` token whose
    /// URL is the pending scheme + this UUID.
    func pendingMarkerRange(for id: UUID, in textView: NSTextView) -> NSRange? {
        let target = PendingAttachmentMarker.scheme + id.uuidString
        let ns = textView.string as NSString
        for token in parsedDocument(for: textView.string).tokens where token.kind == .imageLink {
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
    /// live selection (shifted only when the edit lies before it). Deliberately does NOT call
    /// `makeFirstResponder` / park the caret at the insertion — that caret-theft is the very bug
    /// this feature fixes, so resolution stays out of the user's way.
    /// Returns whether the replacement was actually applied (`false` on an out-of-range edit or a
    /// read-only view, so a caller reports the reference as unhandled rather than silently dropped).
    @MainActor
    @discardableResult
    func applyPendingReplacement(range: NSRange, with replacement: String, actionName: String, to textView: NSTextView) -> Bool {
        let currentText = textView.string as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= currentText.length else { return false }

        let selection = textView.selectedRange()
        textView.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        textView.breakUndoCoalescing()

        let newLength = (textView.string as NSString).length
        let adjusted = PendingAttachmentMarker.adjustedSelection(
            selection,
            editRange: range,
            replacementLength: (replacement as NSString).length,
            maxLength: newLength
        )
        textView.setSelectedRange(adjusted)
        return true
    }
}

#endif
