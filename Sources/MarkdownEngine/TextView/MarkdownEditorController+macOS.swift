#if os(macOS)
//
//  MarkdownEditorController+macOS.swift
//  MarkdownEngine
//
//  The macOS counterpart to the iOS `MarkdownEditorController` (TextView/iOS) — the
//  "engine publishes state, host builds the UI" bridge. Deliberately the SAME public type
//  name + API across platforms, so cross-platform host code reads identically: create one as
//  a `@StateObject`, hand it to the wrapper via `.controller(_:)`, observe its `@Published`
//  state, and call its command methods from the UI.
//
//  Today it carries the `/` slash-command menu (publish `slashMenuContext`, apply via
//  `insertBlock`); macOS formatting still flows through the right-click context menu, so the
//  surface is intentionally narrower than iOS's controller (which also drives a toolbar).
//

import SwiftUI

@MainActor
public final class MarkdownEditorController: ObservableObject {

    /// The active `/` slash command at the caret, or `nil`. Observe this to show/hide the
    /// block-insert menu anchored at `anchorRect`; filter rows with
    /// `MarkdownSlashMenu.items(matching: context.query)` and apply a choice via `insertBlock`.
    @Published public private(set) var slashMenuContext: SlashMenuContext?

    /// The coordinator, bound by the wrapper. Weak: the SwiftUI view tree owns it.
    private weak var coordinator: NativeTextViewCoordinator?

    public init() {}

    // MARK: Binding (called by the wrapper)

    /// Bind the controller to its coordinator. Internal: invoked by the wrapper, not the host.
    /// Bind-once per coordinator — `updateNSView` calls this every SwiftUI pass; the closure is
    /// stable, so re-binding would just churn.
    func attach(_ coordinator: NativeTextViewCoordinator) {
        guard self.coordinator !== coordinator else { return }
        self.coordinator = coordinator
        coordinator.onSlashMenuContextChange = { [weak self] context in
            self?.updateSlashMenuContext(context)
        }
        // Publish initial state so freshly-shown host UI isn't stale.
        coordinator.publishSlashMenuContextNow()
    }

    private func updateSlashMenuContext(_ context: SlashMenuContext?) {
        if slashMenuContext != context { slashMenuContext = context }
    }

    // MARK: Commands (called by the host's UI)

    /// Insert `block` from the slash menu, replacing the active `/command`. Pass the source range
    /// from the current `slashMenuContext` (defaults to it); a no-op if there's no active trigger.
    /// Single-undo, and clears the menu.
    public func insertBlock(_ block: MarkdownBlockInsert, replacing sourceRange: NSRange? = nil) {
        guard let range = sourceRange ?? slashMenuContext?.sourceRange else { return }
        coordinator?.insertSlashBlock(block, replacing: range)
    }
}

// MARK: - Wrapper binding hook

public extension NativeTextViewWrapper {
    /// Attach a controller so the host can observe slash-menu context and issue block inserts.
    func controller(_ controller: MarkdownEditorController) -> NativeTextViewWrapper {
        var copy = self
        copy.boundController = controller
        return copy
    }
}
#endif
