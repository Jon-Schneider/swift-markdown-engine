//
//  MacOSEscapeEndsEditingTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for the `endsEditingOnEscape` config flag (follow-up E1). When enabled, a press
//  of Escape (`cancelOperation:`) inside an editable NSTextView resigns first responder, ending
//  the edit session. Because `NativeTextView.resignFirstResponder()` reports focus=false through
//  the coordinator's `onFocusChange`, the host `focus` binding flips false with no extra plumbing.
//
//  These tests drive the delegate's `doCommandBy` directly (that's the AppKit entry point Escape
//  maps to) against a real first-responder round trip in an off-screen window, mirroring the
//  harness in `MacOSFocusBindingTests`.
//
//  Headless AppKit — macOS only.
//
#if os(macOS)
import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
struct MacOSEscapeEndsEditingTests {

    private func makeCoordinator() -> NativeTextViewCoordinator {
        NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
    }

    /// A `NativeTextView` hosted in an off-screen window, delegated to `coordinator`, carrying the
    /// given configuration (which is what `doCommandBy` consults for the Escape flag).
    private func makeHostedTextView(
        delegatingTo coordinator: NativeTextViewCoordinator,
        configuration: MarkdownEditorConfiguration,
        editable: Bool = true
    ) -> (view: NativeTextView, window: NSWindow) {
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.isEditable = editable
        view.configuration = configuration
        view.delegate = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(view)
        return (view, window)
    }

    private let escape = #selector(NSResponder.cancelOperation(_:))

    @Test("Escape ends editing when endsEditingOnEscape is true — consumes the key and reports focus false")
    func escapeResignsWhenEnabled() {
        let coordinator = makeCoordinator()
        let (view, window) = makeHostedTextView(
            delegatingTo: coordinator,
            configuration: MarkdownEditorConfiguration(endsEditingOnEscape: true)
        )
        _ = window.makeFirstResponder(view)
        var reported: [Bool] = []
        coordinator.onFocusChange = { reported.append($0) }

        let handled = coordinator.textView(view, doCommandBy: escape)

        #expect(handled, "Escape must be consumed so AppKit doesn't beep")
        #expect(reported.last == false, "resigning first responder must report focus false to the host")
        #expect(window.firstResponder === window, "dropping first responder parks it on the window itself")
    }

    @Test("Escape is a no-op when endsEditingOnEscape is false (the default)")
    func escapeIsNoOpWhenDisabled() {
        let coordinator = makeCoordinator()
        let (view, window) = makeHostedTextView(
            delegatingTo: coordinator,
            configuration: MarkdownEditorConfiguration() // default: flag off
        )
        _ = window.makeFirstResponder(view)
        var reported: [Bool] = []
        coordinator.onFocusChange = { reported.append($0) }

        let handled = coordinator.textView(view, doCommandBy: escape)

        #expect(!handled, "with the flag off, Escape falls through to AppKit's default")
        #expect(reported.isEmpty, "no focus change should be reported")
        #expect(window.firstResponder === view, "the text view stays first responder")
    }

    @Test("Escape is a no-op in a read-only view even when the flag is on")
    func escapeIsNoOpWhenNotEditable() {
        let coordinator = makeCoordinator()
        let (view, window) = makeHostedTextView(
            delegatingTo: coordinator,
            configuration: MarkdownEditorConfiguration(endsEditingOnEscape: true),
            editable: false
        )
        _ = window.makeFirstResponder(view)

        let handled = coordinator.textView(view, doCommandBy: escape)

        #expect(!handled, "a non-editable view has no edit session to end, so Escape is not consumed")
    }

    @Test("Escape does NOT end editing during an IME composition (marked text present)")
    func escapeDeferredToIMEWhileComposing() {
        let coordinator = makeCoordinator()
        let (view, window) = makeHostedTextView(
            delegatingTo: coordinator,
            configuration: MarkdownEditorConfiguration(endsEditingOnEscape: true)
        )
        _ = window.makeFirstResponder(view)
        // Simulate an in-flight conversion: provisional (marked) text at the caret.
        view.setMarkedText("あ", selectedRange: NSRange(location: 0, length: 1),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText(), "precondition: a composition is active")
        var reported: [Bool] = []
        coordinator.onFocusChange = { reported.append($0) }

        let handled = coordinator.textView(view, doCommandBy: escape)

        #expect(!handled, "Escape must fall through to the IME to cancel the conversion")
        #expect(reported.isEmpty, "the edit session must not end mid-composition")
        #expect(window.firstResponder === view, "the text view stays first responder")
    }

    @Test("Progressive Escape: the FIRST Escape closes an open slash menu WITHOUT ending editing")
    func firstEscapeClosesSlashMenuAndKeepsEditing() {
        let coordinator = makeCoordinator()
        let (view, window) = makeHostedTextView(
            delegatingTo: coordinator,
            configuration: MarkdownEditorConfiguration(endsEditingOnEscape: true)
        )
        _ = window.makeFirstResponder(view)
        var reported: [Bool] = []
        coordinator.onFocusChange = { reported.append($0) }
        // A menu is currently open: a consumer is wired AND a context is published.
        coordinator.onSlashMenuContextChange = { _ in }
        coordinator.lastPublishedSlashContext = SlashMenuContext(
            query: "head", sourceRange: NSRange(location: 0, length: 5), anchorRect: .zero
        )

        let handled = coordinator.textView(view, doCommandBy: escape)

        #expect(handled, "Escape must be consumed (it closed the menu)")
        #expect(coordinator.lastPublishedSlashContext == nil, "the menu must be closed")
        #expect(reported.isEmpty, "closing the menu must NOT end the edit session")
        #expect(window.firstResponder === view, "the editor stays focused after closing the menu")
    }

    @Test("Progressive Escape: the SECOND Escape (menu already closed) ends editing")
    func secondEscapeEndsEditing() {
        let coordinator = makeCoordinator()
        let (view, window) = makeHostedTextView(
            delegatingTo: coordinator,
            configuration: MarkdownEditorConfiguration(endsEditingOnEscape: true)
        )
        _ = window.makeFirstResponder(view)
        coordinator.onSlashMenuContextChange = { _ in }
        coordinator.lastPublishedSlashContext = SlashMenuContext(
            query: "head", sourceRange: NSRange(location: 0, length: 5), anchorRect: .zero
        )
        var reported: [Bool] = []
        coordinator.onFocusChange = { reported.append($0) }

        // First Escape closes the menu…
        _ = coordinator.textView(view, doCommandBy: escape)
        // …second Escape, with no menu open, ends editing.
        let handled = coordinator.textView(view, doCommandBy: escape)

        #expect(handled)
        #expect(reported.last == false, "the second Escape must end the edit session")
        #expect(window.firstResponder === window, "first responder dropped to the window")
    }

    @Test("With no slash-menu consumer wired, Escape ends editing directly — a stale context isn't 'closed'")
    func escapeEndsEditingWhenNoSlashConsumer() {
        let coordinator = makeCoordinator()
        let (view, window) = makeHostedTextView(
            delegatingTo: coordinator,
            configuration: MarkdownEditorConfiguration(endsEditingOnEscape: true)
        )
        _ = window.makeFirstResponder(view)
        // No `onSlashMenuContextChange` wired (controller-less host), yet the dedupe field carries a
        // value (the caret sits after a `/word`). Escape must NOT treat that as an open menu.
        coordinator.lastPublishedSlashContext = SlashMenuContext(
            query: "tmp", sourceRange: NSRange(location: 0, length: 4), anchorRect: .zero
        )
        var reported: [Bool] = []
        coordinator.onFocusChange = { reported.append($0) }

        let handled = coordinator.textView(view, doCommandBy: escape)

        #expect(handled)
        #expect(reported.last == false, "with no menu UI, the first Escape ends editing rather than being eaten")
        #expect(window.firstResponder === window)
    }
}
#endif
