//
//  InlineInsertionRequest.swift
//  MarkdownEngine
//
//  Host-driven request to splice arbitrary literal markdown at the caret.
//  Shared by the iOS `MarkdownUITextViewWrapper` and the macOS
//  `NativeTextViewWrapper` — a thin, caret-relative façade over the same
//  underlying insertion primitive on each platform.
//

import Foundation

/// A request to insert an arbitrary literal markdown string at the editor's current
/// caret (replacing any selected range).
///
/// Drive it through the wrapper's `pendingInlineInsertion` binding: set the value to a
/// non-nil request to trigger the insertion. The wrapper inserts `markdown` verbatim —
/// the engine does **not** interpret it — advances the caret to just past the inserted
/// run, restyles, fires the text write-back (`onTextChange` / `text` binding), then
/// resets the binding to `nil` so the same request is not re-applied on the next update.
///
/// The insertion applies whether or not the field is currently first responder: the
/// target is the current selection when focused, the last-known caret when focus was
/// lost (e.g. a picker sheet stole it), and the end of the document as the final
/// fallback when no caret has ever been established.
///
/// Each request carries a unique `id` (generated for you — callers still just write
/// `InlineInsertionRequest(markdown:)`). The wrapper dedups on that `id`, so a genuine
/// second insertion of the *same* markdown string still applies, while a duplicate
/// `updateUIView`/`updateNSView` pass over the *same* request does not re-insert. This
/// mirrors the sibling `InlineReplacementRequest`'s UUID.
public struct InlineInsertionRequest: Equatable, Sendable {
    /// Identity of this request, so the engine can tell a re-delivered request apart from a
    /// fresh one that happens to carry identical markdown. Generated per instance.
    public let id: UUID
    /// The literal markdown to insert verbatim, e.g. `![alt](shipyard-attachment://<id>)`
    /// or `[report.pdf](shipyard-attachment://<id>)`.
    public let markdown: String

    public init(markdown: String) {
        self.id = UUID()
        self.markdown = markdown
    }
}
