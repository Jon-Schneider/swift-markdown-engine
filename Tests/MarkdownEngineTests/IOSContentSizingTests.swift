//
//  IOSContentSizingTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for the iOS `heightBehavior == .fitsContent` support (parity with macOS): the
//  editor disables internal scrolling and reports a content-fitting intrinsic height, so a field
//  embedded in a page's own ScrollView lays out at its natural height instead of as a fixed,
//  internally-scrolling box. Also covers the hardware-keyboard shortcut wiring.
//
//  UIKit-runtime behaviors → iOS simulator only; compiles out on the macOS host.
//
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("iOS content sizing (.fitsContent) & key commands")
struct IOSContentSizingTests {

    private func makeView(_ markdown: String, heightBehavior: MarkdownEditorConfiguration.HeightBehavior) -> MarkdownUITextView {
        let config = MarkdownEditorConfiguration(heightBehavior: heightBehavior)
        let view = MarkdownUITextView(configuration: config, isEditable: true)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        if #available(iOS 17.0, *) { view.traitOverrides.preferredContentSizeCategory = .large }
        view.render(markdown: markdown)
        view.layoutIfNeeded()
        return view
    }

    // MARK: - Scroll mode ↔ heightBehavior

    @Test(".fitsContent disables internal scrolling; .scrolls keeps it")
    func scrollEnabledTracksHeightBehavior() {
        #expect(makeView("hi", heightBehavior: .fitsContent).isScrollEnabled == false)
        #expect(makeView("hi", heightBehavior: .scrolls).isScrollEnabled == true)
    }

    @Test("A runtime switch to .fitsContent reconfigures scrolling")
    func runtimeSwitchReconfigures() {
        let view = makeView("hi", heightBehavior: .scrolls)
        #expect(view.isScrollEnabled == true)
        view.configuration = MarkdownEditorConfiguration(heightBehavior: .fitsContent)
        view.reapplyConfiguration()
        #expect(view.isScrollEnabled == false)
    }

    // MARK: - Reported height

    @Test(".fitsContent reports a positive intrinsic content height")
    func fitsContentReportsIntrinsicHeight() {
        let view = makeView("one line", heightBehavior: .fitsContent)
        #expect(view.intrinsicContentSize.height > 0)
        #expect(view.intrinsicContentSize.width == UIView.noIntrinsicMetric)
    }

    @Test(".scrolls reports no intrinsic height (SwiftUI sizes it)")
    func scrollsReportsNoIntrinsicHeight() {
        let view = makeView("one line", heightBehavior: .scrolls)
        // UITextView's default intrinsic height is the no-intrinsic sentinel when it scrolls.
        #expect(view.intrinsicContentSize.height == UIView.noIntrinsicMetric)
    }

    @Test("Taller content reports a taller intrinsic height")
    func moreContentIsTaller() {
        let short = makeView("one line", heightBehavior: .fitsContent).intrinsicContentSize.height
        let tall = makeView("l1\nl2\nl3\nl4\nl5\nl6", heightBehavior: .fitsContent).intrinsicContentSize.height
        #expect(tall > short, "a 6-line document must be taller than a 1-line document")
    }

    @Test("An empty .fitsContent document is at least one body line tall")
    func emptyDocumentHasMinimumHeight() {
        let view = makeView("", heightBehavior: .fitsContent)
        #expect(view.intrinsicContentSize.height >= view.baseFont.lineHeight)
    }

    @Test("Typing grows the reported intrinsic height (per-keystroke re-report, not just full restyle)")
    func typingGrowsHeight() {
        let view = makeView("one", heightBehavior: .fitsContent)
        let before = view.intrinsicContentSize.height
        // An ordinary edit goes through textViewDidChange → the SCOPED restyle path; the height
        // must still re-report (the bug Fable flagged: invalidation was only in restyleInPlace).
        view.insertText("\ntwo\nthree\nfour\nfive")
        view.layoutIfNeeded()
        #expect(view.intrinsicContentSize.height > before, "adding lines must grow the reported height")
    }

    @Test("The fitting width comes from the proposal, not a (macOS-only) reading column")
    func fittingWidthUsesProposedWidth() {
        let view = makeView("hi", heightBehavior: .fitsContent)
        #expect(view.fitsContentWidth(proposing: 250) == 250)
    }

    // MARK: - Key commands

    @Test("Editable view binds the formatting key commands")
    func keyCommandsBound() {
        let view = makeView("x", heightBehavior: .scrolls)
        let commands = view.keyCommands ?? []
        func has(_ input: String, _ flags: UIKeyModifierFlags) -> Bool {
            commands.contains { $0.input == input && $0.modifierFlags == flags }
        }
        #expect(has("b", .command))
        #expect(has("i", .command))
        #expect(has("x", [.command, .shift]))
        #expect(has("e", .command))
        #expect(has("0", [.command, .alternate]))
    }

    @Test("A read-only view binds no formatting key commands")
    func readOnlyBindsNoKeyCommands() {
        let config = MarkdownEditorConfiguration(heightBehavior: .scrolls)
        let view = MarkdownUITextView(configuration: config, isEditable: false)
        view.render(markdown: "x")
        let commands = view.keyCommands ?? []
        #expect(!commands.contains { $0.input == "b" && $0.modifierFlags == .command })
    }

    @Test("clearBlockFormatting strips the caret line's block prefix to a paragraph")
    func clearBlockFormattingClearsHeading() {
        let view = makeView("## foo", heightBehavior: .scrolls)
        view.establishCaretForTesting()
        view.selectedRange = NSRange(location: 3, length: 0)
        view.clearBlockFormatting(in: view.selectedRange)
        #expect(view.text == "foo")
    }

    @Test("applyFormatting(.heading) toggles a heading off at the same level")
    func headingToggleOffViaApply() {
        let view = makeView("## foo", heightBehavior: .scrolls)
        view.establishCaretForTesting()
        view.selectedRange = NSRange(location: 3, length: 0)
        view.applyFormatting(.heading(2), in: view.selectedRange)
        #expect(view.text == "foo")
    }
}
#endif
