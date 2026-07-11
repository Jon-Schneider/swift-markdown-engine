#if os(macOS)
//
//  NativeTextView+KeyCommands.swift
//  MarkdownEngine
//
//  Hardware-keyboard commands for the macOS editor. NSTextView binds no
//  bold/italic key equivalents of its own, so a host could only route ⌘B through an
//  app-level menu (disabled inside sheets). These handle the common shortcuts on the text
//  view, routed through the same coordinator `applyFormatting` core as the context menu:
//    ⌘B bold · ⌘I italic · ⌘⇧X strikethrough · ⌘E inline code · ⌥⌘0 clear block (paragraph)
//
//  `⌘E` is normally "Use Selection for Find"; inside this editor it applies inline code.
//

import AppKit

extension NativeTextView {
    /// Modifiers we key off of. Deliberately EXCLUDES `.capsLock`, `.function`, and
    /// `.numericPad` (which `.deviceIndependentFlagsMask` retains) so an engaged Caps Lock —
    /// or a fn/numpad bit — doesn't defeat the exact-equality match and kill every shortcut.
    private static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Open the system Emoji & Symbols panel after a literal colon is committed. This belongs in
    /// `keyDown` rather than the text-view delegate so paste, dictation, and programmatic edits do
    /// not unexpectedly present UI. The colon intentionally remains in the document: the system
    /// panel owns its insertion and has no API for replacing an application-defined trigger range.
    override func keyDown(with event: NSEvent) {
        let isEmojiPickerTrigger = isEditable
            && window?.firstResponder === self
            && event.characters == ":"
            && event.modifierFlags.intersection([.command, .option, .control]).isEmpty

        super.keyDown(with: event)

        guard isEmojiPickerTrigger else { return }
        // AppKit finishes text insertion synchronously, but deferring presentation keeps the
        // Character Viewer outside the active TextKit key-event cycle. That preserves this view
        // as the insertion target when the user chooses an emoji.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            NSApp.orderFrontCharacterPalette(nil)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit dispatches `performKeyEquivalent` to EVERY view in the window, not just the
        // focused one. Without the first-responder check, ⌘B typed in a sibling text field would
        // silently mutate THIS document and ⌘E would be stolen window-wide. Only act when we hold
        // first responder.
        guard isEditable, window?.firstResponder === self,
              let coordinator = delegate as? NativeTextViewCoordinator else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(Self.relevantModifiers)
        let key = event.charactersIgnoringModifiers?.lowercased()

        switch (key, flags) {
        case ("b", [.command]):
            coordinator.applyFormatting(.bold, to: self); return true
        case ("i", [.command]):
            coordinator.applyFormatting(.italic, to: self); return true
        case ("x", [.command, .shift]):
            coordinator.applyFormatting(.strikethrough, to: self); return true
        case ("e", [.command]):
            coordinator.applyFormatting(.inlineCode, to: self); return true
        case ("0", [.command, .option]):
            coordinator.clearBlockFormatting(to: self); return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

#endif
