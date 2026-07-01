//
//  MacOSInlineInsertionTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for the macOS host-driven inline insertion —
//  `NativeTextViewCoordinator.applyInlineInsertion(_:to:)`, the backing for
//  `NativeTextViewWrapper(pendingInlineInsertion:)`. It is a thin caret-relative façade
//  over the existing `applyInlineReplacement` verbatim path (`isImageEmbedMode: true`),
//  mirroring the iOS `insertMarkdown(_:)` primitive. Insertion must:
//    1. splice the string VERBATIM (a plain `![alt](url)` is not transformed as a
//       wiki-link would be),
//    2. target the current selection when a caret has been established, advancing the
//       caret past the inserted run,
//    3. replace a non-empty selection,
//    4. fall back to the END of the document when no caret was ever established.
//
//  Headless AppKit — macOS only.
//

#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct MacOSInlineInsertionTests {

    private func makeCoordinator() -> NativeTextViewCoordinator {
        NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
    }

    /// A TextKit-2 `NativeTextView` seeded with `content`, editable, with a caret established
    /// unless `establishCaret` is false (to exercise the not-first-responder fallback).
    private func makeTextView(_ content: String, establishCaret: Bool = true) -> NativeTextView {
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.isEditable = true
        view.string = content
        if establishCaret { view.establishCaretForTesting() }
        return view
    }

    private let attachmentImage = "![Diagram.png](shipyard-attachment://3F2A)"

    @Test("Inserts verbatim at the caret and advances the caret past it")
    func insertsAtCaretAndAdvances() {
        let coordinator = makeCoordinator()
        let view = makeTextView("hello world")
        view.setSelectedRange(NSRange(location: 5, length: 0))   // between "hello" and " world"

        coordinator.applyInlineInsertion(attachmentImage, to: view)

        #expect(view.string == "hello\(attachmentImage) world")
        #expect(view.selectedRange() == NSRange(location: 5 + (attachmentImage as NSString).length, length: 0),
                "the caret must sit just past the inserted run")
    }

    @Test("The inserted markdown is spliced verbatim — a plain image link is not wiki-transformed")
    func insertionIsVerbatim() {
        let coordinator = makeCoordinator()
        let view = makeTextView("")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let fileLink = "[report.pdf](shipyard-attachment://9C11)"

        coordinator.applyInlineInsertion(fileLink, to: view)

        #expect(view.string == fileLink, "the literal markdown must survive unchanged")
    }

    @Test("A non-empty selection is replaced by the inserted markdown")
    func replacesSelection() {
        let coordinator = makeCoordinator()
        let view = makeTextView("keep DROP keep")
        view.setSelectedRange(NSRange(location: 5, length: 4))   // "DROP"

        coordinator.applyInlineInsertion(attachmentImage, to: view)

        #expect(view.string == "keep \(attachmentImage) keep")
    }

    @Test("With no caret ever established, insertion appends at the end of the document")
    func appendsAtEndWhenNoCaretEstablished() {
        let coordinator = makeCoordinator()
        let view = makeTextView("existing body", establishCaret: false)
        // selectedRange defaults to {0,0}, but the final fallback must be end-of-document.
        coordinator.applyInlineInsertion(attachmentImage, to: view)

        #expect(view.string == "existing body\(attachmentImage)")
    }

    // MARK: - Request dedup

    @Test("A repeated request id inserts once; a new request with identical markdown re-inserts")
    func dedupsByRequestId() {
        let coordinator = makeCoordinator()
        let view = makeTextView("")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let first = InlineInsertionRequest(markdown: "A")

        #expect(coordinator.applyInsertionIfNew(first, to: view))
        #expect(!coordinator.applyInsertionIfNew(first, to: view))   // duplicate update pass → no double insert
        #expect(view.string == "A")

        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        #expect(coordinator.applyInsertionIfNew(InlineInsertionRequest(markdown: "A"), to: view))
        #expect(view.string == "AA", "a new request with identical markdown must not be silently dropped")
    }

    // MARK: - Read-only refusal

    @Test("Read-only: insertion makes no edit and does not move the caret")
    func readOnlyRefusesInsertion() {
        let coordinator = makeCoordinator()
        let view = makeTextView("locked")
        view.isEditable = false
        view.setSelectedRange(NSRange(location: 3, length: 0))

        coordinator.applyInlineInsertion(attachmentImage, to: view)

        #expect(view.string == "locked", "a read-only NSTextView rejects the splice via shouldChangeText")
        #expect(view.selectedRange() == NSRange(location: 3, length: 0),
                "a refused insert must not jump the selection to end-of-document")
    }

    @Test("Caret lands past a verbatim insert whose wiki-display length differs (guards the #1 fix)")
    func caretPastRunForWikiSyntaxInsert() {
        let coordinator = makeCoordinator()
        let view = makeTextView("")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        // `[[Foo|abc]]` is a wiki-link whose display form drops `|abc`, so the engine's
        // display-length caret math would land the caret SHORT of the inserted run. The
        // override must place it at the true end of the run regardless of storage/display form.
        coordinator.applyInlineInsertion("[[Foo|abc]]", to: view)

        let endOfDoc = (view.string as NSString).length
        #expect(view.selectedRange() == NSRange(location: endOfDoc, length: 0),
                "caret must sit at the end of the inserted run, not short of it")
    }

    @Test("Same-length selection replacement (equal UTF-16 length) still corrects the caret")
    func caretCorrectForEqualLengthReplacement() {
        let coordinator = makeCoordinator()
        let view = makeTextView("abcdefghijk")   // 11 chars
        view.setSelectedRange(NSRange(location: 0, length: 11))   // select all 11
        let fragment = "[[Foo|abc]]"             // also 11 chars, but wiki-display length is 7

        coordinator.applyInlineInsertion(fragment, to: view)

        // The document length is unchanged (11 → 11), so a length-only guard would treat this
        // as a no-op and leave the caret at the wiki-display length (7). Content changed, so
        // the caret must be corrected to the true verbatim end (11).
        #expect(view.string == fragment)
        #expect(view.selectedRange() == NSRange(location: 11, length: 0),
                "an equal-length replacement is a real edit; the caret must land past the run")
    }

    // MARK: - Real first responder establishes the caret (exercises the production override)

    @Test("becomeFirstResponder sets didEstablishCaret for real — no test seam")
    func realFirstResponderEstablishesCaret() {
        let view = makeTextView("body", establishCaret: false)
        #expect(!view.didEstablishCaret)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(view))
        #expect(view.didEstablishCaret, "the production becomeFirstResponder override must set the flag")
    }
}
#endif
