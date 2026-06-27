//
//  MarkdownUITextViewWrapper.swift
//  MarkdownEngine
//
//  SwiftUI bridge for the iOS read-only Markdown view (Phase 2a). The
//  `UIViewRepresentable` sibling of the macOS `NativeTextViewWrapper`, exposing a
//  minimal read-only surface: a text string + a configuration.
//

#if canImport(UIKit)
import SwiftUI

public struct MarkdownUITextViewWrapper: UIViewRepresentable {

    /// Markdown source in storage form (`[[Name|id]]` wiki-links are normalized).
    public let text: String
    public var configuration: MarkdownEditorConfiguration

    public init(text: String, configuration: MarkdownEditorConfiguration = .default) {
        self.text = text
        self.configuration = configuration
    }

    public func makeUIView(context: Context) -> MarkdownUITextView {
        let view = MarkdownUITextView(configuration: configuration)
        view.render(markdown: text)
        return view
    }

    public func updateUIView(_ view: MarkdownUITextView, context: Context) {
        view.configuration = configuration
        // Re-render only when the source text actually changed from outside, so a
        // routine SwiftUI update doesn't wipe the user's in-place edits.
        if view.lastRenderedSource != text {
            view.render(markdown: text)
        }
    }
}
#endif
