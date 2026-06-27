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
    /// Called when the user edits the document, with the new text in **storage form**.
    /// Persist this back into your model; without it, in-place edits are not propagated
    /// (and would be discarded the next time `text` changes from outside).
    public var onTextChange: ((String) -> Void)?
    /// Called when the user taps a link (markdown link / auto-detected URL / wiki-link).
    public var onLinkTap: ((URL) -> Void)?

    /// Optional controller for selection-state observation + formatting commands, bound via
    /// the `.controller(_:)` modifier (see `MarkdownEditorController`).
    var boundController: MarkdownEditorController?

    public init(
        text: String,
        configuration: MarkdownEditorConfiguration = .default,
        onTextChange: ((String) -> Void)? = nil,
        onLinkTap: ((URL) -> Void)? = nil
    ) {
        self.text = text
        self.configuration = configuration
        self.onTextChange = onTextChange
        self.onLinkTap = onLinkTap
    }

    public func makeUIView(context: Context) -> MarkdownUITextView {
        let view = MarkdownUITextView(configuration: configuration)
        view.onTextChange = onTextChange
        view.onLinkTap = onLinkTap
        view.render(markdown: text)
        boundController?.attach(view)
        return view
    }

    public func updateUIView(_ view: MarkdownUITextView, context: Context) {
        view.configuration = configuration
        view.onTextChange = onTextChange   // capture the latest closure each SwiftUI pass
        view.onLinkTap = onLinkTap
        boundController?.attach(view)
        if view.lastRenderedSource != text {
            // Source changed from outside → full reload.
            view.render(markdown: text)
        } else {
            // Text unchanged but `configuration` may have (theme/highlighter/insets):
            // re-apply config-derived state without wiping in-place edits.
            view.reapplyConfiguration()
        }
    }
}
#endif
