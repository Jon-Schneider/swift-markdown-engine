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

    /// Optional controller for selection-state observation + formatting commands, bound via
    /// the `.controller(_:)` modifier (see `MarkdownEditorController`).
    var boundController: MarkdownEditorController?

    public init(
        text: String,
        configuration: MarkdownEditorConfiguration = .default,
        isEditable: Bool = true,
        onTextChange: ((String) -> Void)? = nil,
        onLinkTap: ((URL) -> Void)? = nil,
        onPasteImage: ((Data) -> String?)? = nil
    ) {
        self.text = text
        self.configuration = configuration
        self.isEditable = isEditable
        self.onTextChange = onTextChange
        self.onLinkTap = onLinkTap
        self.onPasteImage = onPasteImage
    }

    public func makeUIView(context: Context) -> MarkdownUITextView {
        let view = MarkdownUITextView(configuration: configuration, isEditable: isEditable)
        view.onTextChange = onTextChange
        view.onLinkTap = onLinkTap
        view.onPasteImage = onPasteImage
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
            DispatchQueue.main.async { [weak view] in view?.publishHostStateNow() }
        }
    }
}
#endif
