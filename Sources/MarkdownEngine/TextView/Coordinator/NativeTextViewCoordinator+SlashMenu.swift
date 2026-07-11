#if os(macOS)
//
//  NativeTextViewCoordinator+SlashMenu.swift
//  MarkdownEngine
//
//  The macOS half of the `/` slash-command block-insert menu (plan item 3.2). The coordinator
//  DETECTS an active slash trigger at the caret (via the shared, unit-tested `MarkdownSlashMenu`
//  core) and publishes a `SlashMenuContext` to the bound `MarkdownEditorController`; the host
//  renders the menu and, on selection, asks the engine to insert a block via `insertSlashBlock`.
//  Mirrors the iOS `MarkdownUITextView` publish/insert path.
//

import AppKit

extension NativeTextViewCoordinator {

    /// Compute the slash-command context for the current caret and hand it to the host (deduped
    /// against the last publish so the hot text-/selection-change paths don't churn `@Published`).
    func publishSlashMenuContext(_ tv: NSTextView) {
        publishSlashMenuContext(tv, forcingDelivery: false)
    }

    private func publishSlashMenuContext(_ tv: NSTextView, forcingDelivery: Bool) {
        let context = slashMenuContext(for: tv)
        let changed = context != lastPublishedSlashContext
        guard changed || forcingDelivery else { return }
        lastPublishedSlashContext = context
        // The trigger opened or its query changed, so any prior highlight is stale — reset to the
        // top row (Notion/Slack behavior: filtering re-homes the selection). Done here, guarded by
        // the dedupe above, so it fires only on an actual context change, not every keystroke.
        if changed { setSlashMenuHighlight(0) }
        // Defer past the current AppKit edit/selection cycle (mirrors `onCaretRectChange`) so the
        // host's `@Published` mutation doesn't land inside a re-entrant text-storage callback.
        let callback = onSlashMenuContextChange
        DispatchQueue.main.async { callback?(context) }
    }

    /// Whether a slash menu is actually on screen — a consumer is wired AND a context is live. The
    /// arrow-/return-key interception (see `+TextDelegate`) gates on this so those keys keep their
    /// normal editing behavior whenever no menu is open.
    var slashMenuIsActive: Bool {
        onSlashMenuContextChange != nil && lastPublishedSlashContext != nil
    }

    /// Move the highlighted row by `delta` (±1 for ↑/↓), wrapping within the filtered items. No-op
    /// when no menu is open.
    func moveSlashMenuHighlight(by delta: Int) {
        guard let context = lastPublishedSlashContext else { return }
        let count = MarkdownSlashMenu.items(matching: context.query).count
        setSlashMenuHighlight(MarkdownSlashMenu.movedHighlight(slashMenuHighlightedIndex, by: delta, count: count))
    }

    /// Insert the currently-highlighted block (↵), replacing the active `/query`. No-op when no menu
    /// is open or the query now filters every row out.
    func confirmSlashMenuHighlight() {
        guard let context = lastPublishedSlashContext,
              let item = MarkdownSlashMenu.item(at: slashMenuHighlightedIndex, matching: context.query)
        else { return }
        insertSlashBlock(item.block, replacing: context.sourceRange)
    }

    /// Update the highlighted index and mirror it to the host (deduped). Deferred to the next
    /// main-actor tick for the same reason as the context publish — it may run inside a text-storage
    /// callback (via `publishSlashMenuContext`).
    private func setSlashMenuHighlight(_ index: Int) {
        guard slashMenuHighlightedIndex != index else { return }
        slashMenuHighlightedIndex = index
        let callback = onSlashMenuHighlightChange
        DispatchQueue.main.async { callback?(index) }
    }

    /// Clear a currently-published slash context (publishing `nil`) if one is live. Used when
    /// the edit session ends without a text/selection change — e.g. Escape-to-end-editing —
    /// which otherwise wouldn't republish and would strand the menu on a now-unfocused editor.
    /// Returns whether anything was dismissed.
    @discardableResult
    func dismissSlashMenuContextIfPresent() -> Bool {
        // Only a wired consumer can actually be showing a menu. Without one there's nothing to
        // close, so progressive Escape must NOT short-circuit here (else a caret parked after a
        // `/word` would silently eat the first Escape instead of ending editing).
        guard onSlashMenuContextChange != nil, lastPublishedSlashContext != nil else { return false }
        lastPublishedSlashContext = nil
        let callback = onSlashMenuContextChange
        DispatchQueue.main.async { callback?(nil) }
        return true
    }

    /// Force a publish now — the controller calls this on attach so freshly-shown host UI isn't
    /// stale relative to a caret that's already sitting in a `/command`.
    func publishSlashMenuContextNow() {
        guard let tv = textView else { return }
        // Attachment is a new consumer boundary, so deduplication against what a previous consumer
        // saw is invalid. Force the current value through even when the producer's cache is equal.
        publishSlashMenuContext(tv, forcingDelivery: true)
    }

    /// The `/` slash context for a zero-length caret in `tv`, or nil. The anchor rect is in the
    /// text view's view/scroll-local space (top-left origin), which maps straight into a SwiftUI
    /// overlay placed directly over the wrapper — unlike iOS, no window-space conversion is needed
    /// (AppKit window coords are y-flipped relative to SwiftUI's, so view-local is the clean anchor).
    private func slashMenuContext(for tv: NSTextView) -> SlashMenuContext? {
        let selection = tv.selectedRange()
        guard tv.isEditable,
              selection.length == 0,
              let trigger = MarkdownSlashMenu.trigger(in: tv.string, caret: selection.location)
        else { return nil }
        // `viewRect` returns the rect in the SCROLL-VIEW BOUNDS space — i.e. the wrapper's frame,
        // which is exactly the SwiftUI overlay's local space — so it maps in directly with NO
        // inset adjustment. (It subtracts `contentView.bounds.origin`, and the rest scroll position
        // is `-contentInsets.top` per `makeNSView`, so the safe-area inset is already embedded;
        // adding it again would double-count.)
        //
        // Anchor on the (non-empty) `/query` range, not the zero-length caret: TextKit 2's
        // `enumerateTextSegments` yields no segment for an empty range, so a caret-range rect can
        // come back `.zero` and slam the menu into the top-left corner. The `/query` always spans
        // ≥1 char, so its rect reliably lands on the caret's line. Fall back to the caret range.
        let caretRange = NSRange(location: selection.location, length: 0)
        let rect = tv.viewRect(forCharacterRange: trigger.sourceRange, using: layoutBridge)
            ?? tv.viewRect(forCharacterRange: caretRange, using: layoutBridge)
            ?? .zero
        return SlashMenuContext(query: trigger.query, sourceRange: trigger.sourceRange, anchorRect: rect)
    }

    /// Insert a slash-menu `block`, replacing the `/query` at `sourceRange`, as ONE undoable edit.
    /// Mirrors `applyMarkdownCommand`'s `shouldChangeText`/`replaceCharacters`/`didChangeText`
    /// flow (single undo step + write-back to the host binding). The resulting `textDidChange`
    /// republishes the now-nil context, which dismisses the menu. A stale/out-of-range
    /// `sourceRange` collapses to an identity no-op inside `insertEdit`, caught by the guard below.
    func insertSlashBlock(_ block: MarkdownBlockInsert, replacing sourceRange: NSRange) {
        guard let tv = textView else { return }
        let edit = MarkdownSlashMenu.insertEdit(block, replacing: sourceRange, in: tv.string)
        let current = (tv.string as NSString).substring(with: edit.range)
        guard current != edit.text else { return }
        if tv.shouldChangeText(in: edit.range, replacementString: edit.text) {
            tv.replaceCharacters(in: edit.range, with: edit.text)
            tv.didChangeText()
            tv.setSelectedRange(edit.selection)
            DispatchQueue.main.async { self.text = tv.string }
        }
    }
}
#endif
