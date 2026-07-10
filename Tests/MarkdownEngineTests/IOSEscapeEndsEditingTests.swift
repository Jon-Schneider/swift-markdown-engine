//
//  IOSEscapeEndsEditingTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for the iOS half of the `endsEditingOnEscape` config flag (follow-up E1). On iOS
//  the flag binds a hardware-keyboard Escape key command that resigns first responder, ending the
//  edit session — which fires `textViewDidEndEditing` → the focus reporter writes `false` back to
//  any host binding, mirroring the macOS path. There is no on-screen-keyboard equivalent, so this
//  only affects iPad-with-hardware-keyboard.
//
//  Two layers here:
//    1. keyCommands COMPOSITION (deterministic, no window): the Escape command is present only when
//       the flag is on AND the view is editable, and it asserts priority over system Escape.
//    2. The ACTION end-to-end (needs a key window / booted simulator): invoking the command's
//       selector on a focused view resigns first responder, reports focus lost, and clears any live
//       slash-menu context.
//
//  UIKit-runtime behaviors — `#if canImport(UIKit)`, executes only on the iOS simulator.
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("iOS Escape ends editing")
struct IOSEscapeEndsEditingTests {

    private func makeView(endsEditingOnEscape: Bool, isEditable: Bool = true) -> MarkdownUITextView {
        let config = MarkdownEditorConfiguration(endsEditingOnEscape: endsEditingOnEscape)
        let view = MarkdownUITextView(configuration: config, isEditable: isEditable)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        view.render(markdown: "hello")
        view.layoutIfNeeded()
        return view
    }

    private func escapeCommand(in view: MarkdownUITextView) -> UIKeyCommand? {
        view.keyCommands?.first { $0.input == UIKeyCommand.inputEscape }
    }

    // MARK: - keyCommands composition

    @Test("The Escape command is bound when the flag is on and the view is editable")
    func escapeBoundWhenEnabled() {
        let command = escapeCommand(in: makeView(endsEditingOnEscape: true))
        #expect(command != nil, "an editable, opted-in view must expose an Escape key command")
        #expect(command?.modifierFlags == [], "it's a bare Escape — no modifiers")
        #expect(command?.wantsPriorityOverSystemBehavior == true,
                "the flag's contract is 'Escape ends editing', so it must win over the system's Escape")
    }

    @Test("The Escape command is absent when the flag is off (the default)")
    func escapeAbsentWhenDisabled() {
        #expect(escapeCommand(in: makeView(endsEditingOnEscape: false)) == nil)
    }

    @Test("The Escape command is absent in a read-only view even with the flag on")
    func escapeAbsentWhenReadOnly() {
        #expect(escapeCommand(in: makeView(endsEditingOnEscape: true, isEditable: false)) == nil)
    }

    @Test("The Escape command vanishes during an IME composition so the key reaches the input system")
    func escapeAbsentDuringComposition() {
        let view = makeView(endsEditingOnEscape: true)
        // A priority key command is resolved before the text-input system and can't decline, so
        // it must not exist mid-composition — otherwise it would swallow the IME's cancel key.
        view.setMarkedText("あ", selectedRange: NSRange(location: 0, length: 1))
        #expect(view.markedTextRange != nil, "precondition: a composition is active")
        #expect(escapeCommand(in: view) == nil,
                "with marked text present, Escape must flow to the IME, not the key command")
    }

    // MARK: - Action end-to-end (key window)

    @Test("Invoking the Escape command with no menu open resigns first responder and reports focus lost")
    func escapeActionEndsEditingWhenNoMenuOpen() {
        let view = makeView(endsEditingOnEscape: true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var focus: [Bool] = []
        var slash: [SlashMenuContext?] = []
        view.onFocusChange = { focus.append($0) }
        view.onSlashMenuContextChange = { slash.append($0) }

        #expect(view.becomeFirstResponder(), "an editable UITextView in the key window must accept first responder")
        guard let action = escapeCommand(in: view)?.action else {
            Issue.record("the Escape command must exist while editing")
            return
        }
        // Fire the command's selector exactly as UIKit would when Escape is pressed. `perform`
        // reaches the @objc handler even though it's private.
        view.perform(action)

        #expect(focus.last == false, "ending the edit session must report focus lost")
        #expect(slash.isEmpty, "no menu was open, so no slash context should be published")
        #expect(!view.isFirstResponder, "the view must no longer be first responder")
    }

    @Test("Progressive Escape: with a menu open, the first Escape closes it (stays focused), the second ends editing")
    func escapeProgressiveClosesMenuThenEndsEditing() {
        let view = makeView(endsEditingOnEscape: true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        #expect(view.becomeFirstResponder())
        // A menu is currently open (as if the caret sat in a `/command`).
        view.lastPublishedSlashContext = SlashMenuContext(
            query: "head", sourceRange: NSRange(location: 0, length: 5), anchorRect: .zero
        )
        // Wire the reporters only now, so the arrays capture just what the Escape presses produce
        // (not the focus-gained from becomeFirstResponder above).
        var focus: [Bool] = []
        var slash: [SlashMenuContext?] = []
        view.onFocusChange = { focus.append($0) }
        view.onSlashMenuContextChange = { slash.append($0) }
        guard let action = escapeCommand(in: view)?.action else {
            Issue.record("the Escape command must exist while editing")
            return
        }

        // First Escape: closes the menu, keeps editing.
        view.perform(action)
        #expect(slash.last == .some(nil), "the first Escape must close the open menu")
        #expect(focus.isEmpty, "closing the menu must NOT end the edit session")
        #expect(view.isFirstResponder, "the editor stays focused after closing the menu")

        // Second Escape: no menu open now, ends editing.
        view.perform(action)
        #expect(focus.last == false, "the second Escape must end the edit session")
        #expect(!view.isFirstResponder)
    }

    @Test("Publishing host state populates the stored slash context (so Escape can consult it)")
    func publishPopulatesStoredSlashContext() {
        let view = makeView(endsEditingOnEscape: true)
        view.render(markdown: "/head")
        view.layoutIfNeeded()
        view.selectedRange = NSRange(location: 5, length: 0) // caret at end of "/head"
        // The two-arg publish (which sets the stored field) only runs when a selection/link consumer
        // is wired; wire both so we exercise the real populate path, not a hand-seeded value.
        view.onSelectionStateChange = { _ in }
        view.onSlashMenuContextChange = { _ in }

        view.publishHostStateNow()

        #expect(view.lastPublishedSlashContext?.query == "head",
                "publishing must store the live slash context so progressive Escape can read it")
    }

    @Test("With no slash-menu consumer wired, the Escape action ends editing directly")
    func escapeEndsEditingWhenNoSlashConsumer() {
        let view = makeView(endsEditingOnEscape: true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        #expect(view.becomeFirstResponder())
        // Dedupe field carries a value but NO `onSlashMenuContextChange` consumer exists.
        view.lastPublishedSlashContext = SlashMenuContext(
            query: "tmp", sourceRange: NSRange(location: 0, length: 4), anchorRect: .zero
        )
        var focus: [Bool] = []
        view.onFocusChange = { focus.append($0) }
        guard let action = escapeCommand(in: view)?.action else {
            Issue.record("the Escape command must exist while editing")
            return
        }

        view.perform(action)

        #expect(focus.last == false, "with no menu UI, the first Escape ends editing rather than being eaten")
        #expect(!view.isFirstResponder)
    }

    @Test("The Escape action is a safe no-op when the view isn't focused (resign fails, nothing reported)")
    func escapeActionInertWhenNotFocused() {
        let view = makeView(endsEditingOnEscape: true)
        var focus: [Bool] = []
        var slash: [SlashMenuContext?] = []
        view.onFocusChange = { focus.append($0) }
        view.onSlashMenuContextChange = { slash.append($0) }

        // Not first responder and not in a window: resignFirstResponder() returns false.
        if let action = escapeCommand(in: view)?.action { view.perform(action) }

        #expect(focus.isEmpty, "no edit session to end → no focus report")
        #expect(slash.isEmpty, "no successful resign → no slash-menu clear")
    }
}
#endif
