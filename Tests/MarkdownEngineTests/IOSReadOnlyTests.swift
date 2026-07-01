//
//  IOSReadOnlyTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for iOS read-only support — the `MarkdownUITextView(isEditable:)` /
//  `MarkdownUITextViewWrapper(isEditable:)` parameter that mirrors the macOS
//  `NativeTextViewWrapper.isEditable` flag. A read-only document must:
//    1. propagate `isEditable` from the wrapper through to the UITextView,
//    2. render as clean styled text — the caret/selection never reveals raw markers
//       (`computeActiveTokenIndices(suppressed:)` stays empty regardless of caret),
//    3. refuse every in-place mutation (formatting commands, checkbox toggle) through
//       the single `applyUndoableEdit` choke point — the iOS analog of macOS gating
//       each edit behind `shouldChangeText(in:)`,
//    4. still LOAD and DISPLAY its content (read-only ≠ empty) and keep the editable
//       path fully working (the read-only guards are strictly additive).
//
//  These are UIKit-runtime behaviors, so — like the other iOS suites — this file is
//  `#if canImport(UIKit)` and only executes on the iOS simulator; on the macOS host
//  (`swift test`) it compiles out. See `IOSCheckboxToggleTests` for the host/sim split.
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("iOS read-only mode (isEditable)")
struct IOSReadOnlyTests {

    /// Build a laid-out view hosting `markdown` in the requested edit mode.
    private func makeLaidOutView(_ markdown: String, isEditable: Bool) -> MarkdownUITextView {
        let view = MarkdownUITextView(configuration: .default, isEditable: isEditable)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        if #available(iOS 17.0, *) { view.traitOverrides.preferredContentSizeCategory = .large }
        view.render(markdown: markdown)
        view.layoutIfNeeded()
        return view
    }

    // MARK: - Propagation

    @Test("The view defaults to editable")
    func defaultsToEditable() {
        #expect(MarkdownUITextView(configuration: .default).isEditable)
    }

    @Test("isEditable: false makes the underlying UITextView non-editable")
    func initPropagatesReadOnly() {
        let view = MarkdownUITextView(configuration: .default, isEditable: false)
        #expect(!view.isEditable)
    }

    @Test("The SwiftUI wrapper carries isEditable (the value it forwards to the view)")
    func wrapperCarriesReadOnly() {
        // `makeUIView` needs a `UIViewRepresentable.Context`, which can't be synthesized in a
        // unit test; assert the stored property that `makeUIView` forwards to the view instead.
        #expect(MarkdownUITextViewWrapper(text: "hi", isEditable: true).isEditable)
        #expect(!MarkdownUITextViewWrapper(text: "hi", isEditable: false).isEditable)
    }

    @Test("The wrapper defaults to editable")
    func wrapperDefaultsToEditable() {
        #expect(MarkdownUITextViewWrapper(text: "hi").isEditable)
    }

    // MARK: - Marker suppression (asserted on the RENDERED glyph, not just the index set)

    /// Font point size of the styled glyph at `index`. Inline markers are hidden by shrinking
    /// them to `hiddenMarkerFontSize` (default 0.1pt) with a collapsing kern — NOT by a clear
    /// color — so a hidden `*` renders at ~0.1pt while a revealed one keeps full body size.
    /// This inspects the actual styled `textStorage`, catching a marker that renders visible
    /// even if the active-token bookkeeping happened to be empty (what the index set can't prove).
    private func markerFontSize(at index: Int, in view: MarkdownUITextView) -> CGFloat {
        guard index < view.textStorage.length,
              let font = view.textStorage.attribute(.font, at: index, effectiveRange: nil) as? UIFont
        else { return 0 }
        return font.pointSize
    }

    @Test("Editable: caret inside **bold** RENDERS its `**` markers at full size (control)")
    func editableRevealsMarkerGlyphs() {
        let view = makeLaidOutView("**bold** text", isEditable: true)
        view.selectedRange = NSRange(location: 3, length: 0)   // inside the bold span
        view.restyleNowForTesting(invalidatingCache: false)
        #expect(!view.activeTokenIndicesForTesting.isEmpty)
        #expect(markerFontSize(at: 0, in: view) > 5, "the leading `*` must render at readable size")
    }

    @Test("Read-only: the `**` markers RENDER shrunk (hidden), wherever the caret lands")
    func readOnlyHidesMarkerGlyphs() {
        let view = makeLaidOutView("**bold** text", isEditable: false)
        view.selectedRange = NSRange(location: 3, length: 0)   // same caret as the control
        view.restyleNowForTesting(invalidatingCache: false)
        #expect(view.activeTokenIndicesForTesting.isEmpty)
        #expect(markerFontSize(at: 0, in: view) < 1, "the leading `*` must be shrunk to ~0.1pt")
    }

    // MARK: - Runtime toggle (flip isEditable on a LIVE view — the updateUIView path)

    @Test("Toggling a live view to read-only re-styles its markers to hidden")
    func runtimeToggleHidesMarkers() {
        let view = makeLaidOutView("**bold** text", isEditable: true)
        view.selectedRange = NSRange(location: 3, length: 0)
        view.restyleNowForTesting(invalidatingCache: false)
        #expect(markerFontSize(at: 0, in: view) > 5, "revealed while editable")

        // The exact sequence the wrapper's `updateUIView` runs on a runtime toggle.
        view.isEditable = false
        view.reapplyConfiguration()
        #expect(view.activeTokenIndicesForTesting.isEmpty)
        #expect(markerFontSize(at: 0, in: view) < 1, "hidden live, without reconstructing the view")
    }

    @Test("Toggling a live view to read-only withdraws a stale slash-menu context")
    func runtimeToggleWithdrawsSlashContext() {
        let view = makeLaidOutView("/", isEditable: true)
        view.selectedRange = NSRange(location: 1, length: 0)   // caret right after the `/`
        var slashHistory: [SlashMenuContext?] = []
        view.onSelectionStateChange = { _ in }   // satisfy publishHostState's observer guard
        view.onSlashMenuContextChange = { slashHistory.append($0) }

        view.publishHostStateNow()
        #expect(slashHistory.last.flatMap { $0 } != nil,
                "editable: a `/` at line start opens the block-insert menu")

        // Toggle to read-only exactly as `updateUIView` does, then republish (its deferred step).
        view.isEditable = false
        view.reapplyConfiguration()
        view.publishHostStateNow()
        #expect(slashHistory.last.flatMap { $0 } == nil,
                "read-only: the slash-menu context is withdrawn, not left dangling over an inert doc")
    }

    @Test("Read-only: no inline-link edit affordance is published")
    func readOnlyWithdrawsInlineLinkContext() {
        let view = makeLaidOutView("[label](https://example.com)", isEditable: false)
        view.selectedRange = NSRange(location: 2, length: 0)   // inside the link text
        var linkHistory: [InlineLinkContext?] = []
        view.onInlineLinkContextChange = { linkHistory.append($0) }
        view.publishHostStateNow()
        #expect(linkHistory.last.flatMap { $0 } == nil,
                "read-only refuses link edits, so it must not advertise the edit affordance")
    }

    // MARK: - Mutation refusal

    @Test("Read-only: a formatting command makes no edit")
    func readOnlyRefusesFormatting() {
        let view = makeLaidOutView("hello", isEditable: false)
        view.selectedRange = NSRange(location: 0, length: 5)   // select "hello"
        view.applyFormatting(.bold, in: view.selectedRange)
        #expect(view.text == "hello", "read-only must not wrap the selection in **…**")
    }

    @Test("Editable: the same formatting command DOES edit (control)")
    func editableAppliesFormatting() {
        let view = makeLaidOutView("hello", isEditable: true)
        view.selectedRange = NSRange(location: 0, length: 5)
        view.applyFormatting(.bold, in: view.selectedRange)
        #expect(view.text == "**hello**", "editable must wrap the selection in **…**")
    }

    @Test("Read-only: tapping a checkbox does not toggle it")
    func readOnlyRefusesCheckboxToggle() throws {
        let view = makeLaidOutView("- [ ] task", isEditable: false)
        view.selectedRange = NSRange(location: 10, length: 0)
        let box = try #require(view.firstCheckboxBoundingRect())
        _ = view.toggleCheckbox(at: CGPoint(x: box.midX, y: box.midY))
        #expect(view.text == "- [ ] task", "read-only must leave the checkbox source unchanged")
    }

    // MARK: - Read-only still displays content

    @Test("Read-only: content still loads and displays")
    func readOnlyStillDisplaysContent() {
        let view = makeLaidOutView("# Title\n\nBody text", isEditable: false)
        #expect(view.text.contains("Title"))
        #expect(view.text.contains("Body text"))
    }
}
#endif
