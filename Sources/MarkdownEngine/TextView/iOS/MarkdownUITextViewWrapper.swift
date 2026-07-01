//
//  MarkdownUITextViewWrapper.swift
//  MarkdownEngine
//
//  SwiftUI bridge for the iOS Markdown editor view. The `UIViewRepresentable`
//  sibling of the macOS `NativeTextViewWrapper`, exposing a text string, a
//  configuration, and an `onTextChange` write-back so the host can persist edits.
//

#if canImport(UIKit)
import SwiftUI

public struct MarkdownUITextViewWrapper: UIViewRepresentable {

    /// Markdown source in storage form (`[[Name|id]]` wiki-links are normalized for display).
    public let text: String
    public var configuration: MarkdownEditorConfiguration
    /// When `false`, the editor is read-only: typing is blocked, the block-insert `/` menu and
    /// the Format edit-menu are suppressed, and the styler renders clean styled text (markdown
    /// markers stay hidden regardless of caret position). Links and text selection still work.
    /// Mirrors the macOS `NativeTextViewWrapper(isEditable:)` parameter. Defaults to editable.
    public var isEditable: Bool
    /// Called when the user edits the document, with the new text in **storage form**.
    /// Persist this back into your model; without it, in-place edits are not propagated
    /// (and would be discarded the next time `text` changes from outside).
    public var onTextChange: ((String) -> Void)?
    /// Called when the user taps a link (markdown link / auto-detected URL / wiki-link).
    public var onLinkTap: ((URL) -> Void)?
    /// Called when an image is pasted, with the PNG bytes. Persist it and return a path/URL
    /// to reference (or nil to decline); the editor inserts `![](returnedPath)`.
    public var onPasteImage: ((Data) -> String?)?
    /// Insert arbitrary literal markdown at the caret by setting this to a non-nil value;
    /// the engine splices it in verbatim, advances the caret past it, and then clears the
    /// binding. Mirrors the macOS `NativeTextViewWrapper(pendingInlineInsertion:)`.
    /// See ``InlineInsertionRequest``.
    @Binding public var pendingInlineInsertion: InlineInsertionRequest?
    /// Optional host-driven focus. Reconciled against the text view's live first-responder
    /// state on **every** update (not just on the binding's edge), so a focus request that
    /// lands before the field is in a window — or is dropped mid-scroll — is retried on a
    /// later pass rather than lost. `true` makes the field first responder (raising the
    /// keyboard); `false` resigns it. The wrapper also writes the live editing state back into
    /// the binding from `textViewDidBeginEditing`/`textViewDidEndEditing`, so tapping the field
    /// (or the keyboard dismissing) is reported to the host. Mirrors the macOS
    /// `NativeTextViewWrapper(focus:)`. A plain `Binding<Bool>` (not `@FocusState`) because a
    /// host `@FocusState` doesn't reach into the wrapped `UITextView` unless bridged here.
    /// `public` to match the macOS `NativeTextViewWrapper.focus` surface.
    public var focus: Binding<Bool>?

    /// Optional controller for selection-state observation + formatting commands, bound via
    /// the `.controller(_:)` modifier (see `MarkdownEditorController`).
    var boundController: MarkdownEditorController?

    public init(
        text: String,
        configuration: MarkdownEditorConfiguration = .default,
        isEditable: Bool = true,
        pendingInlineInsertion: Binding<InlineInsertionRequest?> = .constant(nil),
        focus: Binding<Bool>? = nil,
        onTextChange: ((String) -> Void)? = nil,
        onLinkTap: ((URL) -> Void)? = nil,
        onPasteImage: ((Data) -> String?)? = nil
    ) {
        self.text = text
        self.configuration = configuration
        self.isEditable = isEditable
        self._pendingInlineInsertion = pendingInlineInsertion
        self.focus = focus
        self.onTextChange = onTextChange
        self.onLinkTap = onLinkTap
        self.onPasteImage = onPasteImage
    }

    public func makeUIView(context: Context) -> MarkdownUITextView {
        let view = MarkdownUITextView(configuration: configuration, isEditable: isEditable)
        view.onTextChange = onTextChange
        view.onLinkTap = onLinkTap
        view.onPasteImage = onPasteImage
        view.onFocusChange = makeFocusReporter()
        view.render(markdown: text)
        boundController?.attach(view)
        return view
    }

    public func updateUIView(_ view: MarkdownUITextView, context: Context) {
        view.configuration = configuration
        // Sync read-only state BEFORE the restyle below so its marker/caret suppression
        // reflects the current mode (a host toggle re-styles via `reapplyConfiguration`).
        let editabilityChanged = view.isEditable != isEditable
        view.isEditable = isEditable
        view.onTextChange = onTextChange   // capture the latest closure each SwiftUI pass
        view.onLinkTap = onLinkTap
        view.onPasteImage = onPasteImage
        view.onFocusChange = makeFocusReporter()   // refresh the write-back with this pass's binding
        boundController?.attach(view)
        if view.lastRenderedSource != text {
            // Source changed from outside → full reload.
            view.render(markdown: text)
        } else {
            // Text unchanged but `configuration` may have (theme/highlighter/insets):
            // re-apply config-derived state without wiping in-place edits.
            view.reapplyConfiguration()
        }
        // A runtime read-only toggle (a host binding `isEditable` to state) publishes no
        // selection/text event, so any `@Published` slash-menu / inline-link context a bound
        // controller is showing would linger over a now-inert document. Republish host state
        // (both contexts return nil when read-only) to withdraw the dead affordance. Deferred
        // off the SwiftUI view-update pass — mutating @Published inside it is a runtime warning.
        if editabilityChanged {
            DispatchQueue.main.async { [weak view] in
                // Setting `isEditable = false` blocks the caret but does NOT dismiss an
                // already-raised keyboard, so a live edit→read toggle would strand it. Resign
                // first responder on disable so the keyboard drops. Deferred with the republish
                // to keep first-responder mutation out of the SwiftUI update pass.
                if let view, !view.isEditable, view.isFirstResponder {
                    view.resignFirstResponder()
                }
                view?.publishHostStateNow()
            }
        }
        // Host-driven focus: reconcile the requested first-responder state against the view's
        // LIVE state every update (not just on the binding's edge). A request that lands before
        // the field is in a window (the "m reveals the composer" case) or is dropped mid-scroll
        // is retried on the next pass rather than lost. First-responder mutation is deferred off
        // the SwiftUI update pass (mutating it inline is a runtime warning / can re-enter update),
        // which also lets a just-mounted view finish entering its window before we focus it.
        if let focus {
            let wantsFocus = focus.wrappedValue
            if wantsFocus, !view.isFirstResponder, isEditable {
                DispatchQueue.main.async { [weak view] in
                    guard let view, !view.isFirstResponder, view.isEditable else { return }
                    view.becomeFirstResponder()
                }
            } else if !wantsFocus, view.isFirstResponder {
                DispatchQueue.main.async { [weak view] in
                    guard let view, view.isFirstResponder else { return }
                    view.resignFirstResponder()
                }
            }
        }
        // Host-driven inline insertion: splice the requested markdown at the caret, then
        // clear the binding so it isn't re-applied. `applyInsertionIfNew` dedups by request
        // id, so a duplicate update pass before the async reset doesn't double-insert, while
        // a genuinely new request with identical markdown still applies.
        if let request = pendingInlineInsertion {
            view.applyInsertionIfNew(request)
            DispatchQueue.main.async {
                if self.pendingInlineInsertion?.id == request.id {
                    self.pendingInlineInsertion = nil
                }
            }
        } else {
            view.resetInsertionDedup()
        }
    }

    /// Build the write-back closure the text view calls when it begins/ends editing, so the
    /// host binding tracks the live first-responder state (tap-to-focus, keyboard dismissal).
    /// Captures the current pass's `focus` binding by value; guards against a redundant write
    /// (and the resulting reconcile echo) by comparing before assigning. Returns nil when no
    /// focus binding is supplied, so an un-bound wrapper does no work.
    private func makeFocusReporter() -> ((Bool) -> Void)? {
        guard let focus else { return nil }
        return { isFocused in
            if focus.wrappedValue != isFocused { focus.wrappedValue = isFocused }
        }
    }
}
#endif
