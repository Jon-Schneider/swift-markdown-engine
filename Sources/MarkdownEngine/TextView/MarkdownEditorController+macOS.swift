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
//  It carries the `/` slash-command menu (publish `slashMenuContext`, apply via `insertBlock`)
//  AND — at iOS parity — a formatting toolbar surface: `applyFormatting` / `insertLink` and a
//  published `selectionState`, so a single cross-platform host toolbar drives both platforms.
//  The right-click context menu stays; this is additive.
//

import SwiftUI

@MainActor
public final class MarkdownEditorController: ObservableObject {

    /// Formatting active at the current selection — drive a toolbar's button highlights from this
    /// (Bold lit when `isBold`, the active heading level, etc.). Updated live as the caret moves and
    /// the document changes. Same shape as the iOS controller, so one host toolbar reads both.
    @Published public private(set) var selectionState = MarkdownSelectionState()

    /// The active `/` slash command at the caret, or `nil`. Observe this to show/hide the
    /// block-insert menu anchored at `anchorRect`; filter rows with
    /// `MarkdownSlashMenu.items(matching: context.query)` and apply a choice via `insertBlock`.
    @Published public private(set) var slashMenuContext: SlashMenuContext?

    /// The slash menu's highlighted row, as an index into `MarkdownSlashMenu.items(matching:
    /// slashMenuContext.query)`. Engine-owned: ↑/↓ move it and ↵ inserts it; observe this to render
    /// the highlight. Resets to 0 when the menu opens or its query changes; ignore it when
    /// `slashMenuContext` is nil.
    @Published public private(set) var slashMenuHighlightedIndex = 0

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
        coordinator.onSlashMenuContextChange = { [weak self, weak coordinator] context in
            guard let self, let coordinator, self.coordinator === coordinator else { return }
            self.updateSlashMenuContext(context)
        }
        coordinator.onSlashMenuHighlightChange = { [weak self, weak coordinator] index in
            guard let self, let coordinator, self.coordinator === coordinator else { return }
            self.updateSlashMenuHighlight(index)
        }
        coordinator.onSelectionStateChange = { [weak self, weak coordinator] state in
            guard let self, let coordinator, self.coordinator === coordinator else { return }
            self.updateSelectionState(state)
        }
        // Publish initial state so freshly-shown host UI isn't stale.
        coordinator.publishSlashMenuContextNow()
        coordinator.publishSelectionStateNow()
        // A persistent controller may be attaching to a newly-created coordinator whose index is
        // already 0. The producer's deduped change callback would emit nothing in that case, leaving
        // an old controller index visible while Return inserts row 0. Synchronize unconditionally,
        // deferred out of the SwiftUI update pass like the coordinator's other publications.
        DispatchQueue.main.async { [weak self, weak coordinator] in
            guard let self, let coordinator, self.coordinator === coordinator else { return }
            self.updateSlashMenuHighlight(coordinator.slashMenuHighlightedIndex)
        }
    }

    private func updateSlashMenuContext(_ context: SlashMenuContext?) {
        if slashMenuContext != context { slashMenuContext = context }
    }

    private func updateSlashMenuHighlight(_ index: Int) {
        if slashMenuHighlightedIndex != index { slashMenuHighlightedIndex = index }
    }

    private func updateSelectionState(_ state: MarkdownSelectionState) {
        if selectionState != state { selectionState = state }
    }

    // MARK: Commands (called by the host's UI)

    /// Apply (toggle) a formatting command to the current selection — wire to a toolbar button.
    /// Bold/Italic toggle; Heading/List apply. Same signature as iOS, so one cross-platform toolbar
    /// drives both.
    public func applyFormatting(_ command: MarkdownFormattingCommand) {
        coordinator?.applyFormatting(command)
    }

    /// Insert a markdown link `[text](url)` at the selection. If text is selected it becomes the
    /// link text (and `text` is ignored); otherwise `text` (or the URL) is used.
    public func insertLink(text: String? = nil, url: String) {
        coordinator?.insertMarkdownLink(text: text, url: url)
    }

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
