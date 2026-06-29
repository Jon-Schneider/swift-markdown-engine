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
        let context = slashMenuContext(for: tv)
        guard context != lastPublishedSlashContext else { return }
        lastPublishedSlashContext = context
        // Defer past the current AppKit edit/selection cycle (mirrors `onCaretRectChange`) so the
        // host's `@Published` mutation doesn't land inside a re-entrant text-storage callback.
        let callback = onSlashMenuContextChange
        DispatchQueue.main.async { callback?(context) }
    }

    /// Force a publish now — the controller calls this on attach so freshly-shown host UI isn't
    /// stale relative to a caret that's already sitting in a `/command`.
    func publishSlashMenuContextNow() {
        guard let tv = textView else { return }
        publishSlashMenuContext(tv)
    }

    /// The `/` slash context for a zero-length caret in `tv`, or nil. The anchor rect is in the
    /// text view's view/scroll-local space (top-left origin), which maps straight into a SwiftUI
    /// overlay placed directly over the wrapper — unlike iOS, no window-space conversion is needed
    /// (AppKit window coords are y-flipped relative to SwiftUI's, so view-local is the clean anchor).
    private func slashMenuContext(for tv: NSTextView) -> SlashMenuContext? {
        let selection = tv.selectedRange()
        guard selection.length == 0,
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
