//
//  MacOSClearBlockTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for the macOS block-clearing / toggle-off formatting through the coordinator —
//  the path the ⌘-key equivalents (`NativeTextView.performKeyEquivalent`) and the context menu
//  drive. `clearBlockFormatting(to:)` backs ⌥⌘0; `applyFormatting(.heading/.bulletList/…)` now
//  toggles a block off when re-applied while active.
//
//  Headless AppKit — macOS only.
//
#if os(macOS)
import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("macOS clear-block & toggle-off formatting")
struct MacOSClearBlockTests {

    private func setupEditor(_ content: String, caret: Int) -> (coordinator: NativeTextViewCoordinator, view: NativeTextView) {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.isEditable = true
        view.string = content
        view.delegate = coordinator
        view.establishCaretForTesting()
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return (coordinator, view)
    }

    @Test("clearBlockFormatting strips a heading to a paragraph")
    func clearBlockStripsHeading() {
        let (coordinator, view) = setupEditor("## foo", caret: 3)
        coordinator.clearBlockFormatting(to: view)
        #expect(view.string == "foo")
    }

    @Test("clearBlockFormatting strips a list marker to a paragraph")
    func clearBlockStripsList() {
        let (coordinator, view) = setupEditor("- foo", caret: 2)
        coordinator.clearBlockFormatting(to: view)
        #expect(view.string == "foo")
    }

    @Test("clearBlockFormatting strips all blockquote levels")
    func clearBlockStripsQuoteLevels() {
        let (coordinator, view) = setupEditor("> > foo", caret: 4)
        coordinator.clearBlockFormatting(to: view)
        #expect(view.string == "foo")
    }

    @Test("clearBlockFormatting on a plain line is a no-op")
    func clearBlockPlainLineNoOp() {
        let (coordinator, view) = setupEditor("foo", caret: 0)
        coordinator.clearBlockFormatting(to: view)
        #expect(view.string == "foo")
    }

    @Test("applyFormatting(.heading) at the same level toggles the heading off")
    func headingTogglesOff() {
        let (coordinator, view) = setupEditor("## foo", caret: 3)
        coordinator.applyFormatting(.heading(2), to: view)
        #expect(view.string == "foo")
    }

    @Test("applyFormatting(.bulletList) on a bullet line toggles it off")
    func bulletTogglesOff() {
        let (coordinator, view) = setupEditor("- foo", caret: 2)
        coordinator.applyFormatting(.bulletList, to: view)
        #expect(view.string == "foo")
    }

    // The toggle-off is only USEFUL if the built-in menu stays enabled when the block is active
    // (it used to disable heading/list once applied, making toggle-off unreachable).

    @Test("An active heading menu item is ENABLED and checked (so it can toggle off)")
    func headingMenuItemToggleable() {
        let (coordinator, view) = setupEditor("## foo", caret: 3)
        coordinator.textView = view
        let item = NSMenuItem(title: "H2",
                              action: #selector(NativeTextViewCoordinator.didMarkdownHeading(_:)),
                              keyEquivalent: "")
        item.tag = 2
        #expect(coordinator.validateMenuItem(item) == true, "must stay enabled to reach toggle-off")
        #expect(item.state == .on)
    }

    @Test("An active bullet-list menu item is ENABLED and checked")
    func bulletMenuItemToggleable() {
        let (coordinator, view) = setupEditor("- foo", caret: 2)
        coordinator.textView = view
        let item = NSMenuItem(title: "Bullet",
                              action: #selector(NativeTextViewCoordinator.didMarkdownUnorderedList(_:)),
                              keyEquivalent: "")
        #expect(coordinator.validateMenuItem(item) == true)
        #expect(item.state == .on)
    }

    @Test("An inactive list menu item is enabled but unchecked")
    func inactiveListMenuItemEnabledOff() {
        let (coordinator, view) = setupEditor("foo", caret: 0)
        coordinator.textView = view
        let item = NSMenuItem(title: "Numbered",
                              action: #selector(NativeTextViewCoordinator.didMarkdownOrderedList(_:)),
                              keyEquivalent: "")
        #expect(coordinator.validateMenuItem(item) == true)
        #expect(item.state == .off)
    }

    // The menu ACTION handlers (not just validation) must run the shared toggle-off core — they
    // used to call legacy `applyHeading`/`applyList` that couldn't toggle off or convert.

    @Test("The Heading menu action toggles a heading off at the same level")
    func headingMenuActionTogglesOff() {
        let (coordinator, view) = setupEditor("## foo", caret: 3)
        coordinator.textView = view
        let item = NSMenuItem(title: "H2",
                              action: #selector(NativeTextViewCoordinator.didMarkdownHeading(_:)),
                              keyEquivalent: "")
        item.tag = 2
        coordinator.didMarkdownHeading(item)
        #expect(view.string == "foo")
    }

    @Test("The Bullet menu action toggles a bullet line off")
    func bulletMenuActionTogglesOff() {
        let (coordinator, view) = setupEditor("- foo", caret: 2)
        coordinator.textView = view
        coordinator.didMarkdownUnorderedList(nil)
        #expect(view.string == "foo")
    }

    @Test("The Numbered menu action converts a bullet line without stacking markers")
    func numberedMenuActionConverts() {
        let (coordinator, view) = setupEditor("- foo", caret: 2)
        coordinator.textView = view
        coordinator.didMarkdownOrderedList(nil)
        #expect(view.string == "1. foo")
    }
}

#endif
