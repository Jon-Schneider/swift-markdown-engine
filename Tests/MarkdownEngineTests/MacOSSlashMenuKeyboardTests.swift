#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct MacOSSlashMenuKeyboardTests {

    private func setupTestStack(
        text: String = "/",
        editable: Bool = true
    ) -> (coordinator: NativeTextViewCoordinator, view: NativeTextView, window: NSWindow) {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.string = text
        view.isEditable = editable
        view.delegate = coordinator
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(view)
        _ = window.makeFirstResponder(view)
        return (coordinator: coordinator, view: view, window: window)
    }

    @Test("Slash navigation falls through while an IME composition is active")
    func navigationFallsThroughDuringMarkedText() {
        let (coordinator, view, _) = setupTestStack()
        coordinator.onSlashMenuContextChange = { _ in }
        coordinator.lastPublishedSlashContext = SlashMenuContext(
            query: "", sourceRange: NSRange(location: 0, length: 1), anchorRect: .zero
        )
        view.setMarkedText(
            "あ", selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.hasMarkedText(), "precondition: a composition is active")

        let handled = coordinator.textView(view, doCommandBy: #selector(NSResponder.moveDown(_:)))

        #expect(!handled, "the input method must receive candidate-navigation commands")
        #expect(coordinator.slashMenuHighlightedIndex == 0)
    }

    @Test("A live edit-to-read-only transition withdraws the menu and stops consuming navigation")
    func readOnlyTransitionWithdrawsSlashMenu() async {
        let (coordinator, view, window) = setupTestStack(text: "/heading")
        _ = window
        var publishedContexts: [SlashMenuContext?] = []
        coordinator.onSlashMenuContextChange = { publishedContexts.append($0) }
        coordinator.publishSlashMenuContext(view)
        #expect(coordinator.lastPublishedSlashContext != nil, "precondition: the editable menu is active")

        // This is the production transition used by NativeTextViewWrapper.updateNSView. It emits no
        // text or selection event, so NativeTextView.isEditable must explicitly withdraw the menu.
        view.isEditable = false
        let handled = coordinator.textView(view, doCommandBy: #selector(NSResponder.moveDown(_:)))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(coordinator.lastPublishedSlashContext == nil)
        #expect(!publishedContexts.isEmpty)
        #expect(publishedContexts[publishedContexts.count - 1] == nil)
        #expect(!handled, "read-only arrow-key behavior must remain AppKit-owned")
    }

    @Test("Reattachment replaces stale context/highlight and ignores the old coordinator")
    func controllerReattachmentSynchronizesProducerState() async {
        let oldCoordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let oldView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        oldView.string = "/old"
        oldView.setSelectedRange(NSRange(location: 4, length: 0))
        oldView.delegate = oldCoordinator
        oldCoordinator.textView = oldView
        oldCoordinator.publishSlashMenuContext(oldView)
        oldCoordinator.slashMenuHighlightedIndex = 5
        let controller = MarkdownEditorController()
        controller.attach(oldCoordinator)
        await drainMainQueue()
        #expect(controller.slashMenuContext?.query == "old")
        #expect(controller.slashMenuHighlightedIndex == 5)

        let newCoordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let newView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        newView.string = "/new"
        newView.setSelectedRange(NSRange(location: 4, length: 0))
        newView.delegate = newCoordinator
        newCoordinator.textView = newView
        // Prime the producer cache before the new consumer is attached: force publication must still
        // deliver this equal context, and the producer's default index 0 must clear the stale 5.
        newCoordinator.publishSlashMenuContext(newView)
        controller.attach(newCoordinator)
        await drainMainQueue()

        #expect(controller.slashMenuContext?.query == "new")
        #expect(controller.slashMenuHighlightedIndex == 0)

        oldCoordinator.onSlashMenuContextChange?(
            SlashMenuContext(query: "late", sourceRange: NSRange(location: 0, length: 5), anchorRect: .zero)
        )
        oldCoordinator.onSlashMenuHighlightChange?(9)
        #expect(controller.slashMenuContext?.query == "new")
        #expect(controller.slashMenuHighlightedIndex == 0)
    }

    @Test("A queued publication is ignored if its coordinator is released before delivery")
    func releasedCoordinatorCannotDeliverQueuedState() async {
        let stack = await setupReleasedCoordinatorCallback()
        await drainMainQueue()
        #expect(stack.coordinatorReference.value == nil,
                "precondition: both weak producer references are nil")
        DispatchQueue.main.async {
            stack.callback(
                SlashMenuContext(query: "late", sourceRange: NSRange(location: 0, length: 5), anchorRect: .zero)
            )
        }
        await drainMainQueue()

        #expect(stack.controller.slashMenuContext?.query == "baseline",
                "a callback whose producer no longer exists must not mutate controller state")
    }

    private final class WeakCoordinatorReference {
        weak var value: NativeTextViewCoordinator?

        init(_ value: NativeTextViewCoordinator) {
            self.value = value
        }
    }

    private func setupReleasedCoordinatorCallback() async -> (
        controller: MarkdownEditorController,
        callback: (SlashMenuContext?) -> Void,
        coordinatorReference: WeakCoordinatorReference
    ) {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.string = "/baseline"
        view.setSelectedRange(NSRange(location: 9, length: 0))
        view.delegate = coordinator
        coordinator.textView = view
        let controller = MarkdownEditorController()
        controller.attach(coordinator)
        await drainMainQueue()
        #expect(controller.slashMenuContext?.query == "baseline")

        let callback = coordinator.onSlashMenuContextChange!
        let coordinatorReference = WeakCoordinatorReference(coordinator)
        coordinator.onSlashMenuContextChange = nil
        coordinator.textView = nil
        view.delegate = nil
        NotificationCenter.default.removeObserver(coordinator)
        return (controller: controller, callback: callback, coordinatorReference: coordinatorReference)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
#endif
