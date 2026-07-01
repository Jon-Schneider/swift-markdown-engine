#if os(macOS)
//
//  NativeTextViewCoordinator+Formatting.swift
//  MarkdownEngine
//
//  The macOS half of the host-facing formatting toolbar bridge (Requirement D — macOS
//  formatting-command parity with iOS). The coordinator APPLIES a formatting command / link
//  insertion at the selection and PUBLISHES the formatting state at the caret to the bound
//  `MarkdownEditorController`, so a single cross-platform host toolbar drives both platforms.
//
//  The formatting *logic* is the shared, unit-tested cross-platform core (`MarkdownFormatting`);
//  this file only wires it to the `NSTextView` — mirroring how the iOS `MarkdownUITextView`
//  wires the same core to its `UITextView` (`applyFormatting` / `insertMarkdownLink` /
//  `publishHostState`). The right-click context menu (`ContextMenu.swift`) routes through the
//  same `applyFormattingEdit` helper, so there's a single apply-flow on macOS.
//

import AppKit

extension NativeTextViewCoordinator {

    // MARK: Commands (called by the bound controller from the host's toolbar)

    /// Apply (toggle) a formatting command to the current selection, through the shared
    /// cross-platform core. The macOS analog of iOS's `MarkdownUITextView.applyFormatting`.
    func applyFormatting(_ command: MarkdownFormattingCommand) {
        guard let tv = textView else { return }
        applyFormatting(command, to: tv)
    }

    /// Explicit-view variant (the bound `textView` isn't set in headless tests). Mirrors the
    /// `applyInlineInsertion(_:to:)` convention.
    func applyFormatting(_ command: MarkdownFormattingCommand, to tv: NSTextView) {
        let edit = MarkdownFormatting.edit(for: command, text: tv.string, selection: tv.selectedRange())
        applyFormattingEdit(edit, to: tv)
    }

    /// Insert `[text](url)` at the selection. A non-empty selection becomes the link text (and the
    /// `text` argument is ignored); otherwise `text`, then the URL, then a literal "link" is used —
    /// byte-for-byte the same rule as iOS's `MarkdownUITextView.insertMarkdownLink`.
    func insertMarkdownLink(text: String?, url: String) {
        guard let tv = textView else { return }
        insertMarkdownLink(text: text, url: url, to: tv)
    }

    /// Explicit-view variant (see `applyFormatting(_:to:)`).
    func insertMarkdownLink(text: String?, url: String, to tv: NSTextView) {
        let ns = tv.string as NSString
        let selection = tv.selectedRange()
        let linkText: String
        if selection.length > 0 {
            linkText = ns.substring(with: selection)
        } else if let text, !text.isEmpty {
            linkText = text
        } else {
            linkText = url.isEmpty ? "link" : url
        }
        let markdown = "[\(linkText)](\(url))"
        // Advance the caret past the full markup. UTF-16 length (NSString), NOT `String.count`,
        // so multi-unit link text (emoji, etc.) doesn't leave the caret short of the closing `)`.
        let caret = selection.location + (markdown as NSString).length
        applyFormattingEdit(FormattingEdit(
            range: selection, text: markdown,
            selection: NSRange(location: caret, length: 0)
        ), to: tv)
    }

    /// Apply a computed `FormattingEdit` to `tv` as ONE undoable edit — the macOS analog of iOS's
    /// `applyUndoableEdit`, and the single apply-flow shared by `applyFormatting`,
    /// `insertMarkdownLink`, and the right-click context menu. Registers undo via
    /// `shouldChangeText`/`didChangeText`, moves the caret to `edit.selection`, and writes the
    /// storage form back to the host binding. An identity edit (e.g. Clear Formatting with nothing
    /// to clear) is skipped so it doesn't litter the undo stack. A read-only view refuses the edit
    /// — `shouldChangeText(in:)` returns false when `!isEditable` — matching iOS's `isEditable` gate.
    func applyFormattingEdit(_ edit: FormattingEdit, to tv: NSTextView) {
        let current = (tv.string as NSString).substring(with: edit.range)
        guard current != edit.text else { return }
        // The SINGLE read-only gate on macOS: `shouldChangeText(in:)` returns false on a
        // non-editable NSTextView (independent of first-responder / delegate), refusing the edit —
        // the analog of iOS's `applyUndoableEdit` `guard isEditable`. INVARIANT: every macOS edit
        // must route through here; a future path that mutates `textStorage` directly would bypass it.
        guard tv.shouldChangeText(in: edit.range, replacementString: edit.text) else { return }
        tv.replaceCharacters(in: edit.range, with: edit.text)
        // `didChangeText()` BEFORE `setSelectedRange`: it drives `textDidChange`, which rebuilds
        // `wikiLinkMetadata` and restyles. Setting the selection afterward means the resulting
        // `textViewDidChangeSelection` callback (inline-link + selection-state publishing) reads the
        // freshly-rebuilt metadata. Reversing this order publishes an inline-selection state against
        // a stale/nil storage range when formatting text INSIDE a wiki link. (Any one-frame toolbar
        // flicker from the intermediate end-of-replacement caret is dedup'd away by the controller's
        // `selectionState != state` guard, and is the lesser concern than wiki-metadata correctness.)
        tv.didChangeText()
        tv.setSelectedRange(edit.selection)
        // NOTE: deliberately NO `self.text = tv.string` here. `tv.string` is the DISPLAY form
        // (wiki-links render as `[[Name]]` on screen but persist as `[[Name|id]]`); `didChangeText()`
        // drives `textDidChange`, which writes the correct STORAGE form back to the host binding.
        // Writing `tv.string` would clobber that with display form and silently drop wiki-link ids.
    }

    // MARK: Selection-state publishing (drives the toolbar's active-button state)

    /// Compute the host-facing formatting state at the caret and hand it to the bound controller.
    /// Deduped against the last publish so the hot text-/selection-change paths don't churn
    /// `@Published`, and deferred past the current AppKit edit/selection cycle so the host's
    /// `@Published` mutation doesn't land inside a re-entrant text-storage callback — mirrors
    /// `publishSlashMenuContext`. Reuses the coordinator's cached token parse.
    func publishSelectionState(_ tv: NSTextView) {
        guard onSelectionStateChange != nil else { return }
        let tokens = parsedDocument(for: tv.string).tokens
        let state = MarkdownFormatting.selectionState(
            text: tv.string, selection: tv.selectedRange(), tokens: tokens
        )
        guard state != lastPublishedSelectionState else { return }
        lastPublishedSelectionState = state
        let callback = onSelectionStateChange
        DispatchQueue.main.async { callback?(state) }
    }

    /// Force a publish now — the controller calls this on attach so a freshly-shown toolbar isn't
    /// stale relative to a caret that's already sitting inside formatted text.
    func publishSelectionStateNow() {
        guard let tv = textView else { return }
        publishSelectionState(tv)
    }
}
#endif
