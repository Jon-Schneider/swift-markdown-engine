//
//  MacOSFormattingParityTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for Requirement D — macOS formatting-command parity with iOS. The macOS
//  `MarkdownEditorController` now exposes `applyFormatting` / `insertLink` and a published
//  `selectionState`, backed by `NativeTextViewCoordinator+Formatting`, so ONE cross-platform
//  host toolbar drives both platforms. These exercise the coordinator's explicit-view variants
//  directly (the bound `textView` isn't set in a headless test), mirroring
//  `MacOSInlineInsertionTests`.
//
//  The formatting MATH is the shared, separately-tested `MarkdownFormatting` core; these tests
//  assert the macOS WIRING: the edit reaches the `NSTextView`, the caret lands correctly, a
//  read-only view refuses the edit, and selection state is published to the host.
//
//  Headless AppKit — macOS only.
//

#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct MacOSFormattingParityTests {

    private func makeCoordinator() -> NativeTextViewCoordinator {
        NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
    }

    private func makeTextView(_ content: String, editable: Bool = true) -> NativeTextView {
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.isEditable = editable
        view.string = content
        return view
    }

    // MARK: - applyFormatting: inline emphasis

    @Test("applyFormatting(.bold) wraps a non-empty selection and selects the wrapped content")
    func boldWrapsSelection() {
        let coordinator = makeCoordinator()
        let view = makeTextView("hello")
        view.setSelectedRange(NSRange(location: 0, length: 5))

        coordinator.applyFormatting(.bold, to: view)

        #expect(view.string == "**hello**")
        #expect(view.selectedRange() == NSRange(location: 2, length: 5),
                "the wrapped content stays selected, inside the markers")
    }

    @Test("applyFormatting(.bold) on an empty selection inserts markers with the caret between them")
    func boldEmptySelectionInsertsMarkers() {
        let coordinator = makeCoordinator()
        let view = makeTextView("")
        view.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.applyFormatting(.bold, to: view)

        #expect(view.string == "****")
        #expect(view.selectedRange() == NSRange(location: 2, length: 0),
                "the caret sits between the two markers, ready to type")
    }

    @Test("applyFormatting(.italic) toggles OFF when the selection is already italic")
    func italicTogglesOff() {
        let coordinator = makeCoordinator()
        let view = makeTextView("*word*")
        view.setSelectedRange(NSRange(location: 1, length: 4))   // "word", inside the markers

        coordinator.applyFormatting(.italic, to: view)

        #expect(view.string == "word", "an enclosing italic token is unwrapped")
    }

    // MARK: - applyFormatting: block commands

    @Test("applyFormatting(.bulletList) prefixes the caret's paragraph")
    func bulletListPrefixesLine() {
        let coordinator = makeCoordinator()
        let view = makeTextView("item")
        view.setSelectedRange(NSRange(location: 2, length: 0))

        coordinator.applyFormatting(.bulletList, to: view)

        #expect(view.string == "- item")
    }

    @Test("applyFormatting(.heading(2)) applies a level-2 heading prefix")
    func headingAppliesPrefix() {
        let coordinator = makeCoordinator()
        let view = makeTextView("title")
        view.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.applyFormatting(.heading(2), to: view)

        #expect(view.string == "## title")
    }

    @Test("applyFormatting(.blockquote) toggles a quote marker on the line")
    func blockquoteTogglesMarker() {
        let coordinator = makeCoordinator()
        let view = makeTextView("quote me")
        view.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.applyFormatting(.blockquote, to: view)

        #expect(view.string == "> quote me")
    }

    // MARK: - insertLink

    @Test("insertLink wraps a non-empty selection as the link text")
    func insertLinkWrapsSelection() {
        let coordinator = makeCoordinator()
        let view = makeTextView("click here")
        view.setSelectedRange(NSRange(location: 0, length: 5))   // "click"

        coordinator.insertMarkdownLink(text: nil, url: "https://example.com", to: view)

        #expect(view.string == "[click](https://example.com) here")
    }

    @Test("insertLink with no selection uses the text argument as link text")
    func insertLinkUsesTextArgument() {
        let coordinator = makeCoordinator()
        let view = makeTextView("")
        view.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.insertMarkdownLink(text: "Docs", url: "https://example.com", to: view)

        #expect(view.string == "[Docs](https://example.com)")
    }

    @Test("insertLink advances the caret past the run using UTF-16 length, not String.count")
    func insertLinkCaretPastMultiUnitText() {
        let coordinator = makeCoordinator()
        let view = makeTextView("")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        // "a😀" is 2 Characters but 3 UTF-16 units. A `String.count` caret would land SHORT of
        // the closing `)`; the NSString-length math must place it at the true end of the run.
        let markdown = "[a😀](u)"

        coordinator.insertMarkdownLink(text: "a😀", url: "u", to: view)

        #expect(view.string == markdown)
        #expect(view.selectedRange() == NSRange(location: (markdown as NSString).length, length: 0),
                "caret must sit just past the closing paren, counting UTF-16 units")
    }

    // MARK: - Read-only refusal

    @Test("Read-only: applyFormatting makes no edit")
    func readOnlyRefusesFormatting() {
        let coordinator = makeCoordinator()
        let view = makeTextView("locked", editable: false)
        view.setSelectedRange(NSRange(location: 0, length: 6))

        coordinator.applyFormatting(.bold, to: view)

        #expect(view.string == "locked", "a read-only NSTextView rejects the edit via shouldChangeText")
    }

    @Test("Read-only: insertLink makes no edit")
    func readOnlyRefusesLink() {
        let coordinator = makeCoordinator()
        let view = makeTextView("locked", editable: false)
        view.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.insertMarkdownLink(text: "x", url: "y", to: view)

        #expect(view.string == "locked")
    }

    // MARK: - selectionState publishing

    @Test("publishSelectionState reports isBold when the caret sits inside a bold span")
    func selectionStateReflectsBoldCaret() async {
        let coordinator = makeCoordinator()
        let view = makeTextView("**bold** text")
        view.setSelectedRange(NSRange(location: 3, length: 0))   // inside "bold"

        let state: MarkdownSelectionState = await withCheckedContinuation { continuation in
            coordinator.onSelectionStateChange = { continuation.resume(returning: $0) }
            coordinator.publishSelectionState(view)   // deferred via DispatchQueue.main.async
        }

        #expect(state.isBold, "the caret is enclosed by the bold token")
    }

    @Test("publishSelectionState reports plain state when the caret sits outside emphasis")
    func selectionStateReflectsPlainCaret() async {
        let coordinator = makeCoordinator()
        let view = makeTextView("**bold** text")
        view.setSelectedRange(NSRange(location: 11, length: 0))   // inside " text"

        let state: MarkdownSelectionState = await withCheckedContinuation { continuation in
            coordinator.onSelectionStateChange = { continuation.resume(returning: $0) }
            coordinator.publishSelectionState(view)
        }

        #expect(!state.isBold, "the caret is in plain text, outside the bold token")
    }

    // MARK: - Binding write-back (guards the display-vs-storage-form regression)

    private final class TextBox {
        var value: String
        init(_ value: String) { self.value = value }
    }

    /// Drain one main-queue hop so a deferred (`DispatchQueue.main.async`) write-back runs.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("applyFormattingEdit does NOT push the view's display string to the host binding")
    func doesNotWriteDisplayFormToBinding() async {
        // `tv.string` is DISPLAY form (wiki-links render as `[[Name]]` but persist as `[[Name|id]]`).
        // The earlier implementation ended with `self.text = tv.string`, which corrupted the binding
        // to display form — dropping wiki-link ids. The fix removes that write and relies on
        // `textDidChange` (the delegate path) to write the correct STORAGE form back. With no delegate
        // wired here, `applyFormattingEdit` must therefore leave the binding UNTOUCHED. The old code
        // would have set it to "**hello**"; the fix keeps it at "initial".
        let box = TextBox("initial")
        let binding = Binding(get: { box.value }, set: { box.value = $0 })
        let coordinator = NativeTextViewCoordinator(
            text: binding, fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let view = makeTextView("hello")   // deliberately NO delegate wired
        view.setSelectedRange(NSRange(location: 0, length: 5))

        coordinator.applyFormatting(.bold, to: view)
        await drainMainQueue()

        #expect(view.string == "**hello**", "the view itself is edited")
        #expect(box.value == "initial",
                "the binding must NOT receive the display-form string directly; storage-form write-back is the delegate's textDidChange job")
    }

    @Test("selectionState tracks the document AFTER a programmatic formatting edit (toolbar refresh)")
    func selectionStateReflectsStateAfterProgrammaticEdit() async {
        // The requirement is that the toolbar's active state refreshes after a host-driven edit, with
        // no manual caret move. This asserts the building block: once `applyFormatting` has run, the
        // published selection state reflects the NEW document (caret now inside the bold span).
        let coordinator = makeCoordinator()
        let view = makeTextView("hello")
        view.setSelectedRange(NSRange(location: 0, length: 5))

        coordinator.applyFormatting(.bold, to: view)   // "hello" → "**hello**", caret inside the span

        let state: MarkdownSelectionState = await withCheckedContinuation { continuation in
            coordinator.onSelectionStateChange = { continuation.resume(returning: $0) }
            coordinator.publishSelectionState(view)
        }

        #expect(state.isBold, "after wrapping the selection in bold, the caret sits inside the bold token")
    }
}
#endif
