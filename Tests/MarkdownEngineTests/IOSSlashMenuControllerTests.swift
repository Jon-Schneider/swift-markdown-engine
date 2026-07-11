#if canImport(UIKit)
import Testing
import UIKit
@testable import MarkdownEngine

@MainActor
struct IOSSlashMenuControllerTests {

    @Test("Reattachment replaces a stale highlight and ignores callbacks from the old view")
    func controllerReattachmentSynchronizesProducerState() async {
        let oldView = MarkdownUITextView()
        oldView.slashMenuHighlightedIndex = 5
        let controller = MarkdownEditorController()
        controller.attach(oldView)
        await drainMainQueue()
        #expect(controller.slashMenuHighlightedIndex == 5)

        let oldContext = SlashMenuContext(
            query: "old", sourceRange: NSRange(location: 0, length: 4), anchorRect: .zero
        )
        oldView.onSlashMenuContextChange?(oldContext)
        #expect(controller.slashMenuContext == oldContext)

        let newView = MarkdownUITextView()
        controller.attach(newView)
        await drainMainQueue()
        #expect(controller.slashMenuContext == nil)
        #expect(controller.slashMenuHighlightedIndex == 0)

        oldView.onSlashMenuContextChange?(oldContext)
        oldView.onSlashMenuHighlightChange?(9)
        #expect(controller.slashMenuContext == nil)
        #expect(controller.slashMenuHighlightedIndex == 0)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
#endif
