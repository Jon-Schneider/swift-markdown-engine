#if os(macOS)
//
//  NativeTextView+KeyCommands.swift
//  MarkdownEngine
//
//  Hardware-keyboard formatting shortcuts for the macOS editor. NSTextView binds no
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
