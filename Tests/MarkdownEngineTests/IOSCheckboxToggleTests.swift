//
//  IOSCheckboxToggleTests.swift
//  MarkdownEngineTests
//
//  Verify-test for plan item 2.1 — iOS checkbox tap-to-toggle. The toggle is
//  functionally implemented (`MarkdownUITextView.handleTap` → `toggleCheckbox` →
//  `applyUndoableEdit`); 2.1's remaining work is to *prove* the three runtime
//  guarantees that can only be observed on a live `UITextView`:
//    1. buffer persistence — the source flips `[ ]`↔`[x]`,
//    2. caret preservation — the selection is unchanged across the toggle,
//    3. single-undo coalescing — one `undoManager.undo()` fully reverts it.
//
//  These are UIKit-runtime behaviors (the `UITextInput.replace` undo recording,
//  TextKit-2 glyph hit-testing), so this suite is `#if canImport(UIKit)` and only
//  *executes* on the iOS simulator (run via
//  `xcodebuild test -scheme MarkdownEngine-Package -destination 'platform=iOS Simulator,…'`).
//  On the macOS host (`swift test`) it compiles out — `MarkdownUITextView` and
//  UIKit do not exist there. See `iOS-Support-Plan.md` on the host/sim split.
//
//  Scope honesty: these drive the production hit-test entry `toggleCheckbox(at:)`
//  at the box's *rendered* location and independently sanity-check that location,
//  but they do NOT exercise the `UITapGestureRecognizer` callback (`handleTap` →
//  `location(in:)`) itself — that wiring is one line and not the behavior at risk.
//
// Not `targetEnvironment(macCatalyst)`: `canImport(UIKit)` is also true on Catalyst,
// where these UIKit view tests are not meant to run. iOS simulator only.
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("iOS checkbox tap-to-toggle (2.1)")
struct IOSCheckboxToggleTests {

    /// Build a laid-out view hosting `markdown`, returning it ready to hit-test.
    private func makeLaidOutView(_ markdown: String) -> MarkdownUITextView {
        let view = MarkdownUITextView(configuration: .default)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        // Pin Dynamic Type so the box-location bounds (line-height dependent) are
        // stable across simulators. `.large` is the system default.
        if #available(iOS 17.0, *) { view.traitOverrides.preferredContentSizeCategory = .large }
        view.render(markdown: markdown)
        view.layoutIfNeeded()
        return view
    }

    /// The first checkbox glyph's view-coordinate rect, with an *independent*
    /// sanity check on its location so the toggle test isn't purely self-referential
    /// (production `toggleCheckbox` and the test both derive the box from the same
    /// `boundingRect`; this pins the box to where it must actually be drawn).
    private func requireFirstCheckboxRect(in view: MarkdownUITextView) throws -> CGRect {
        let box = try #require(view.firstCheckboxBoundingRect(), "a checkbox glyph should be laid out")
        // `- [ ] …` renders its box near the leading edge of the first line: an
        // offset/sign bug in `boundingRect` would push it out of the left half or
        // far down the document, which these bounds catch.
        #expect(box.width > 0 && box.height > 0)
        #expect(box.minX >= 0 && box.minX < view.bounds.width / 2)
        #expect(box.minY >= 0 && box.minY < 120)   // within the first line(s) from the top inset
        return box
    }

    @Test("Tapping an unchecked box checks it; one undo reverts; caret + buffer preserved")
    func tapTogglesThenSingleUndoReverts() throws {
        let view = makeLaidOutView("- [ ] task")
        // Park the caret away from the box (end of "task") so we can prove it is
        // preserved — and so the box keeps rendering as a glyph (caret-in-box
        // suppresses the decoration).
        let caret = NSRange(location: 10, length: 0)
        view.selectedRange = caret

        let box = try requireFirstCheckboxRect(in: view)
        // Drive the production hit-test → toggle path at the box's rendered center.
        let hit = view.toggleCheckbox(at: CGPoint(x: box.midX, y: box.midY))
        #expect(hit)

        // 1. Buffer persistence: the source flipped, length-preserving.
        #expect(view.text == "- [x] task")
        // 2. Caret preservation: selection unchanged across the toggle.
        #expect(view.selectedRange == caret)
        // 3. Single-undo coalescing: render() did not register an undo, so the
        //    toggle is the only undoable edit — one undo reverts it, and nothing
        //    remains to undo afterward.
        let undo = try #require(view.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(view.text == "- [ ] task")
        #expect(!undo.canUndo, "a single undo step should fully revert the toggle")
    }

    @Test("Tapping a checked box unchecks it (length-preserving)")
    func tapUnchecksCheckedBox() throws {
        let view = makeLaidOutView("- [x] done")
        view.selectedRange = NSRange(location: 10, length: 0)
        let box = try requireFirstCheckboxRect(in: view)
        #expect(view.toggleCheckbox(at: CGPoint(x: box.midX, y: box.midY)))
        #expect(view.text == "- [ ] done")
    }

    @Test("A tap that misses every checkbox toggles nothing")
    func tapMissIsNoOp() throws {
        let view = makeLaidOutView("- [ ] task")
        // Far below the single line of content — no box there.
        #expect(view.toggleCheckbox(at: CGPoint(x: 200, y: 700)) == false)
        #expect(view.text == "- [ ] task")
    }
}
#endif
