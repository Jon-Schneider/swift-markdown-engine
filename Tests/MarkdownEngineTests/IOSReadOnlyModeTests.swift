//
//  IOSReadOnlyModeTests.swift
//  MarkdownEngineTests
//
//  Verify the iOS read-only mode matches macOS (`NativeTextViewWrapper.isEditable`):
//  when `isEditable == false`, raw Markdown markers never reveal on caret/selection
//  and document-mutating taps (checkbox toggle) are refused — while the text stays
//  selectable (copy/find) and the view is non-editable (no caret/keyboard).
//
//  These are `UITextView`-runtime behaviors (live restyle + TextKit-2 layout), so the
//  suite is `#if canImport(UIKit)` and only *executes* on the iOS simulator (run via
//  `xcodebuild test -scheme MarkdownEngine-Package -destination 'platform=iOS Simulator,…'`).
//  On the macOS host (`swift test`) it compiles out. See `iOS-Support-Plan.md`.
//
// Not `targetEnvironment(macCatalyst)`: `canImport(UIKit)` is also true on Catalyst,
// where these UIKit view tests are not meant to run. iOS simulator only.
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("iOS read-only mode (macOS parity)")
struct IOSReadOnlyModeTests {

    /// Build a laid-out view hosting `markdown` at the given editability.
    private func makeLaidOutView(_ markdown: String, isEditable: Bool) -> MarkdownUITextView {
        let view = MarkdownUITextView(configuration: .default, isEditable: isEditable)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        if #available(iOS 17.0, *) { view.traitOverrides.preferredContentSizeCategory = .large }
        view.render(markdown: markdown)
        view.layoutIfNeeded()
        return view
    }

    /// Point size of the `.font` at `index` — a revealed marker uses the base body font;
    /// a hidden one is shrunk to `hiddenMarkerFontSize` (0.1 by default). So "revealed"
    /// vs "hidden" is a clean pointSize comparison independent of exact styling.
    private func fontPointSize(at index: Int, in view: MarkdownUITextView) throws -> CGFloat {
        let font = try #require(
            view.textStorage.attribute(.font, at: index, effectiveRange: nil) as? UIFont,
            "a font attribute should be styled at index \(index)"
        )
        return font.pointSize
    }

    @Test("Read-only: the caret never reveals a token's raw markers")
    func readOnlySuppressesMarkerReveal() throws {
        // `**bold**` — the leading `**` marker occupies range 0..<2.
        let markdown = "**bold**"

        // Editable, caret parked INSIDE the bold run → the marker reveals (base font).
        let editable = makeLaidOutView(markdown, isEditable: true)
        editable.selectedRange = NSRange(location: 4, length: 0)
        editable.restyleNowForTesting()
        let revealedSize = try fontPointSize(at: 0, in: editable)
        #expect(revealedSize > 1, "with the caret inside the token, the `**` marker should be revealed at body size")

        // Read-only, caret at the same spot → suppression keeps the marker hidden (tiny font).
        let readOnly = makeLaidOutView(markdown, isEditable: false)
        readOnly.selectedRange = NSRange(location: 4, length: 0)
        readOnly.restyleNowForTesting()
        let hiddenSize = try fontPointSize(at: 0, in: readOnly)
        #expect(hiddenSize < 1, "read-only should suppress marker reveal regardless of caret position")
    }

    @Test("Toggling isEditable at runtime restyles (markers hide when read-only)")
    func runtimeToggleRestyles() throws {
        let view = makeLaidOutView("**bold**", isEditable: true)
        view.selectedRange = NSRange(location: 4, length: 0)
        view.restyleNowForTesting()
        #expect(try fontPointSize(at: 0, in: view) > 1, "revealed while editable")

        // The `isEditable` override should restyle in place — no explicit re-render.
        view.isEditable = false
        #expect(try fontPointSize(at: 0, in: view) < 1, "flipping to read-only hides the marker")

        view.isEditable = true
        #expect(try fontPointSize(at: 0, in: view) > 1, "flipping back reveals it again")
    }

    @Test("Read-only refuses a checkbox toggle (matches macOS shouldChangeText)")
    func readOnlyBlocksCheckboxToggle() throws {
        let view = makeLaidOutView("- [ ] task", isEditable: false)
        view.selectedRange = NSRange(location: 10, length: 0)
        let box = try #require(view.firstCheckboxBoundingRect())
        // The hit lands on the box, but read-only refuses the source edit.
        #expect(view.toggleCheckbox(at: CGPoint(x: box.midX, y: box.midY)) == false)
        #expect(view.text == "- [ ] task", "read-only must not mutate the document")
    }

    @Test("Read-only stays selectable (copy/find) but non-editable (no caret/keyboard)")
    func readOnlyStaysSelectable() {
        let view = makeLaidOutView("plain text", isEditable: false)
        #expect(view.isEditable == false)
        #expect(view.isSelectable == true)
    }

    @Test("Read-only refuses a controller formatting command (the shared mutation chokepoint)")
    func readOnlyBlocksControllerFormatting() {
        // The controller surface (formatting, slash blocks, link insert, image paste) all funnel
        // through `applyUndoableEdit`. macOS blocks these via `shouldChangeText`; read-only iOS
        // must too — otherwise a "read-only" document mutates from a toolbar button.
        let view = makeLaidOutView("hello world", isEditable: false)
        view.selectedRange = NSRange(location: 0, length: 5)   // select "hello"
        view.applyFormatting(.bold, in: NSRange(location: 0, length: 5))
        #expect(view.text == "hello world", "read-only must not mutate the document from a formatting command")

        // Sanity: the same command DOES mutate when editable (so the test isn't vacuous).
        let editable = makeLaidOutView("hello world", isEditable: true)
        editable.selectedRange = NSRange(location: 0, length: 5)
        editable.applyFormatting(.bold, in: NSRange(location: 0, length: 5))
        #expect(editable.text == "**hello** world")
    }

    @Test("Read-only keeps links tappable (opening a link mutates nothing)")
    func readOnlyKeepsLinksTappable() throws {
        let view = makeLaidOutView("[label](https://example.com)", isEditable: false)
        var tapped: URL?
        view.onLinkTap = { tapped = $0 }

        let bridge = try #require(view.layoutBridge)
        let full = NSRange(location: 0, length: view.textStorage.length)
        var linkRect: CGRect?
        view.textStorage.enumerateAttribute(.link, in: full, options: []) { value, range, stop in
            guard value != nil else { return }
            linkRect = bridge.boundingRect(forCharacterRange: range, in: view.textContainer)
                .offsetBy(dx: view.textContainerInset.left, dy: view.textContainerInset.top)
            stop.pointee = true
        }
        let rect = try #require(linkRect, "the markdown link should carry a `.link` attribute")

        #expect(view.handleLinkTap(at: CGPoint(x: rect.midX, y: rect.midY)))
        #expect(tapped == URL(string: "https://example.com"))
    }
}
#endif
