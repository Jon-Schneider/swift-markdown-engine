//
//  MarkdownEditorController.swift
//  MarkdownEngine
//
//  Host-facing controller for the iOS Markdown editor — the "engine publishes state,
//  host builds the UI" bridge (the iOS analog of the macOS coordinator's selection-state
//  notifications + command methods). The host creates one as a `@StateObject`, hands it to
//  `MarkdownUITextViewWrapper`, observes its `@Published` state to drive a formatting
//  toolbar, and calls its command methods from toolbar buttons.
//

#if canImport(UIKit)
import SwiftUI

/// Published when the caret is inside an inline link, so the host can offer an edit
/// affordance (e.g. a popover anchored at `anchorRect`). `nil` when the caret isn't in a link.
public struct InlineLinkContext: Equatable {
    public enum Kind: Equatable { case markdownLink }
    public let kind: Kind
    /// The link's visible text (`[text](url)` → `text`).
    public let text: String
    /// The link's destination (`[text](url)` → `url`).
    public let target: String
    /// The link's full source range, for an edit command to replace.
    public let sourceRange: NSRange
    /// Caret rect in the editor's coordinate space, to anchor an edit popover.
    public let anchorRect: CGRect
}

@MainActor
public final class MarkdownEditorController: ObservableObject {

    /// Formatting active at the current selection — drive a toolbar's button highlights
    /// from this (Bold lit when `isBold`, the active heading level, etc.). Updated live as
    /// the caret moves and the document changes.
    @Published public private(set) var selectionState = MarkdownSelectionState()

    /// The inline link the caret currently sits in, or `nil`. Observe this to show/hide a
    /// link-edit popover anchored at `anchorRect`.
    @Published public private(set) var inlineLinkContext: InlineLinkContext?

    /// The editor view, bound by the wrapper. Weak: the SwiftUI view tree owns it.
    private weak var view: MarkdownUITextView?

    public init() {}

    // MARK: Binding (called by the wrapper)

    /// Bind the controller to its editor view. Internal: invoked by the wrapper, not the host.
    func attach(_ view: MarkdownUITextView) {
        // Bind once per view — `updateUIView` calls this every SwiftUI pass; re-binding the
        // closures and re-publishing each time risks "publishing changes from within view
        // updates". The closures are stable, so a single bind is enough.
        guard self.view !== view else { return }
        self.view = view
        view.onSelectionStateChange = { [weak self] state in
            self?.updateSelectionState(state)
        }
        view.onInlineLinkContextChange = { [weak self] context in
            self?.updateInlineLinkContext(context)
        }
        // Publish initial state so freshly-shown host UI isn't stale — deferred to the next
        // main-actor tick so it doesn't mutate @Published from inside the view-update cycle.
        DispatchQueue.main.async { [weak view] in view?.publishHostStateNow() }
    }

    private func updateSelectionState(_ state: MarkdownSelectionState) {
        if selectionState != state { selectionState = state }
    }

    private func updateInlineLinkContext(_ context: InlineLinkContext?) {
        if inlineLinkContext != context { inlineLinkContext = context }
    }

    // MARK: Commands (called by the host's UI)

    /// Apply (toggle) a formatting command to the current selection — wire to a toolbar
    /// button. Bold/Italic toggle; Heading/List apply.
    public func applyFormatting(_ command: MarkdownFormattingCommand) {
        guard let view else { return }
        view.applyFormatting(command, in: view.selectedRange)
    }

    /// Insert a markdown link `[text](url)` at the selection. If text is selected it becomes
    /// the link text (and `text` is ignored); otherwise `text` (or the URL) is used.
    public func insertLink(text: String? = nil, url: String) {
        view?.insertMarkdownLink(text: text, url: url)
    }

    /// Replace the markdown link the caret is currently in with `[text](url)`. No-op if the
    /// caret isn't in a link (see `inlineLinkContext`).
    public func updateLinkAtCaret(text: String, url: String) {
        view?.updateMarkdownLinkAtCaret(text: text, url: url)
    }

    /// Present the system find / find-and-replace UI (iOS 16+) over the editor —
    /// wire to a toolbar "Find" button. On iPad with a hardware keyboard ⌘F also
    /// opens it natively; iPhone needs this entry point. Replace is suppressed on a
    /// read-only document.
    ///
    /// Platform note: iOS find is the SYSTEM `UIFindInteraction`, which the host
    /// cannot drive and which posts nothing back. This differs from macOS, where
    /// find is the host-driven bus contract (`findQuery`/`findResults`/…); those
    /// `MarkdownEditorServices.bus` find notifications are macOS-only and are NOT
    /// honored on iOS.
    public func presentFind(showingReplace: Bool = true) {
        view?.presentFind(showingReplace: showingReplace)
    }
}

// MARK: - Wrapper binding hook

public extension MarkdownUITextViewWrapper {
    /// Attach a controller so the host can observe selection state and issue commands.
    func controller(_ controller: MarkdownEditorController) -> MarkdownUITextViewWrapper {
        var copy = self
        copy.boundController = controller
        return copy
    }
}
#endif
