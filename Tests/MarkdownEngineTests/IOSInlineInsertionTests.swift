//
//  IOSInlineInsertionTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for iOS host-driven inline insertion — the `MarkdownUITextView.insertMarkdown(_:)`
//  primitive backing the `MarkdownUITextViewWrapper(pendingInlineInsertion:)` binding. A host
//  (e.g. a toolbar "insert image" flow) splices an arbitrary literal markdown string at the
//  caret. Insertion must:
//    1. splice the string VERBATIM (the engine does not interpret it),
//    2. target the current selection when a caret has been established, advancing the caret
//       past the inserted run,
//    3. replace a non-empty selection,
//    4. fall back to the END of the document when no caret was ever established (the
//       not-first-responder final fallback),
//    5. emit `onTextChange` so the host can persist,
//    6. be refused on a read-only document (the `applyUndoableEdit` `isEditable` choke point).
//
//  UIKit-runtime behaviors, so — like the other iOS suites — this file is `#if canImport(UIKit)`
//  and only executes on the iOS simulator; on the macOS host (`swift test`) it compiles out.
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("iOS inline insertion (insertMarkdown)")
struct IOSInlineInsertionTests {

    private func makeLaidOutView(_ markdown: String, isEditable: Bool = true) -> MarkdownUITextView {
        let view = MarkdownUITextView(configuration: .default, isEditable: isEditable)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        if #available(iOS 17.0, *) { view.traitOverrides.preferredContentSizeCategory = .large }
        view.render(markdown: markdown)
        view.layoutIfNeeded()
        return view
    }

    private let attachmentImage = "![Diagram.png](shipyard-attachment://3F2A)"

    // MARK: - Insert at the established caret

    @Test("Inserts verbatim at the caret and advances the caret past it")
    func insertsAtCaretAndAdvances() {
        let view = makeLaidOutView("hello world")
        view.establishCaretForTesting()
        view.selectedRange = NSRange(location: 5, length: 0)   // between "hello" and " world"

        view.insertMarkdown(attachmentImage)

        #expect(view.text == "hello\(attachmentImage) world")
        #expect(view.selectedRange == NSRange(location: 5 + (attachmentImage as NSString).length, length: 0),
                "the caret must sit just past the inserted run")
    }

    @Test("The inserted markdown is spliced verbatim — no escaping or transformation")
    func insertionIsVerbatim() {
        let view = makeLaidOutView("")
        view.establishCaretForTesting()
        let fileLink = "[report.pdf](shipyard-attachment://9C11)"

        view.insertMarkdown(fileLink)

        #expect(view.text == fileLink, "the literal markdown must survive unchanged")
    }

    @Test("A non-empty selection is replaced by the inserted markdown")
    func replacesSelection() {
        let view = makeLaidOutView("keep DROP keep")
        view.establishCaretForTesting()
        view.selectedRange = NSRange(location: 5, length: 4)   // "DROP"

        view.insertMarkdown(attachmentImage)

        #expect(view.text == "keep \(attachmentImage) keep")
    }

    // MARK: - Not-first-responder fallback

    @Test("With no caret ever established, insertion appends at the end of the document")
    func appendsAtEndWhenNoCaretEstablished() {
        let view = makeLaidOutView("existing body")
        // Never focused → didEstablishCaret is false; selectedRange would be {0,0}, but the
        // final fallback must be end-of-document, not the start.
        view.insertMarkdown(attachmentImage)

        #expect(view.text == "existing body\(attachmentImage)")
    }

    // MARK: - Host write-back

    @Test("Insertion emits onTextChange with the new storage text")
    func emitsOnTextChange() {
        let view = makeLaidOutView("hi")
        view.establishCaretForTesting()
        view.selectedRange = NSRange(location: 2, length: 0)
        var emitted: [String] = []
        view.onTextChange = { emitted.append($0) }

        view.insertMarkdown(attachmentImage)

        #expect(emitted.last == "hi\(attachmentImage)",
                "the host must receive the post-insertion storage text to persist")
    }

    // MARK: - Read-only refusal

    @Test("Read-only: insertion makes no edit")
    func readOnlyRefusesInsertion() {
        let view = makeLaidOutView("locked", isEditable: false)
        view.establishCaretForTesting()
        view.selectedRange = NSRange(location: 3, length: 0)

        view.insertMarkdown(attachmentImage)

        #expect(view.text == "locked", "a read-only document must refuse programmatic insertion")
    }

    // MARK: - Request dedup (the wrapper's binding machinery)

    @Test("A repeated request id inserts once; a new request with identical markdown re-inserts")
    func dedupsByRequestId() {
        let view = makeLaidOutView("")
        view.establishCaretForTesting()
        let first = InlineInsertionRequest(markdown: "A")

        #expect(view.applyInsertionIfNew(first))                 // applies
        #expect(!view.applyInsertionIfNew(first))                // same id (duplicate update pass) → no double insert
        #expect(view.text == "A")

        // A genuinely NEW request carrying the SAME markdown must still insert — the exact
        // silent-drop a string-keyed dedup would cause.
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        #expect(view.applyInsertionIfNew(InlineInsertionRequest(markdown: "A")))
        #expect(view.text == "AA")
    }

    @Test("resetInsertionDedup re-enables a previously applied id")
    func resetDedupReenablesId() {
        let view = makeLaidOutView("")
        view.establishCaretForTesting()
        let req = InlineInsertionRequest(markdown: "Z")
        #expect(view.applyInsertionIfNew(req))
        #expect(!view.applyInsertionIfNew(req))
        view.resetInsertionDedup()
        #expect(view.applyInsertionIfNew(req), "after the binding clears, a re-delivered id applies again")
    }

    // MARK: - Real first responder establishes the caret (exercises the production override)

    @Test("becomeFirstResponder sets didEstablishCaret for real — no test seam")
    func realFirstResponderEstablishesCaret() {
        let view = makeLaidOutView("body")
        #expect(!view.didEstablishCaret)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        window.makeKeyAndVisible()
        #expect(view.becomeFirstResponder())
        #expect(view.didEstablishCaret, "the production becomeFirstResponder override must set the flag")
    }
}
#endif
