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

@MainActor
public final class MarkdownEditorController: ObservableObject {

    /// Formatting active at the current selection — drive a toolbar's button highlights
    /// from this (Bold lit when `isBold`, the active heading level, etc.). Updated live as
    /// the caret moves and the document changes.
    @Published public private(set) var selectionState = MarkdownSelectionState()

    /// The editor view, bound by the wrapper. Weak: the SwiftUI view tree owns it.
    private weak var view: MarkdownUITextView?

    public init() {}

    // MARK: Binding (called by the wrapper)

    /// Bind the controller to its editor view. Internal: invoked by the wrapper, not the host.
    func attach(_ view: MarkdownUITextView) {
        self.view = view
        view.onSelectionStateChange = { [weak self] state in
            self?.updateSelectionState(state)
        }
        // Publish an initial state so a freshly-shown toolbar isn't stale.
        view.publishSelectionStateNow()
    }

    private func updateSelectionState(_ state: MarkdownSelectionState) {
        if selectionState != state { selectionState = state }
    }

    // MARK: Commands (called by the host's toolbar)

    /// Apply (toggle) a formatting command to the current selection — wire to a toolbar
    /// button. Bold/Italic toggle; Heading/List apply.
    public func applyFormatting(_ command: MarkdownFormattingCommand) {
        guard let view else { return }
        view.applyFormatting(command, in: view.selectedRange)
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
