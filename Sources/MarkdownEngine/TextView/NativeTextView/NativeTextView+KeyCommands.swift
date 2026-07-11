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

    /// Open the system Emoji & Symbols panel after a literal colon is committed following a space
    /// or at the beginning of a line. This belongs in `keyDown` rather than the text-view delegate
    /// so paste, dictation, and programmatic edits do not unexpectedly present UI.
    override func keyDown(with event: NSEvent) {
        let selectionRange = selectedRange()
        let triggerLocation = selectionRange.location
        let isEmojiPickerTrigger = isEditable
            && window?.firstResponder === self
            && event.characters == ":"
            && event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            && Self.isEmojiPickerTriggerPosition(
                in: string, selectionRange: selectionRange
            )

        // A local key event means the user continued editing instead of choosing an emoji. The
        // picker inserts without routing a key event through this view, so its pending range stays.
        pendingEmojiPickerTriggerRange = nil
        super.keyDown(with: event)

        guard isEmojiPickerTrigger,
              let colonRange = Self.emojiPickerReplacementRange(in: string, at: triggerLocation) else {
            return
        }
        // Keep the caret after the colon so cancelling Character Viewer leaves normal typing
        // uninterrupted. Its insertion is routed through `insertText`, which replaces this range.
        pendingEmojiPickerTriggerRange = colonRange
        // AppKit finishes text insertion synchronously, but deferring presentation keeps the
        // Character Viewer outside the active TextKit key-event cycle. That preserves this view
        // as the insertion target when the user chooses an emoji.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            NSApp.orderFrontCharacterPalette(nil)
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let triggerRange = pendingEmojiPickerTriggerRange else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        pendingEmojiPickerTriggerRange = nil

        guard Self.emojiPickerReplacementRange(in: string, at: triggerRange.location) != nil else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        super.insertText(insertString, replacementRange: triggerRange)
    }

    /// A colon is an emoji-picker trigger at the start of a document or line, or directly after a
    /// literal space. Using UTF-16 offsets matches `NSTextView`'s selection ranges, including text
    /// before emoji.
    static func isEmojiPickerTriggerPosition(in text: String, selectionRange: NSRange) -> Bool {
        let nsText = text as NSString
        guard selectionRange.location != NSNotFound, selectionRange.location <= nsText.length else {
            return false
        }
        guard selectionRange.location > 0 else { return true }

        let precedingCharacter = nsText.character(at: selectionRange.location - 1)
        guard precedingCharacter != 0x20 else { return true }
        return Unicode.Scalar(precedingCharacter).map { CharacterSet.newlines.contains($0) } ?? false
    }

    /// Returns the committed colon's range when it still occupies the expected insertion point.
    /// The check prevents an unrelated post-key-event edit from being replaced.
    static func emojiPickerReplacementRange(in text: String, at triggerLocation: Int) -> NSRange? {
        let nsText = text as NSString
        guard triggerLocation != NSNotFound,
              triggerLocation < nsText.length,
              nsText.character(at: triggerLocation) == 0x3A else {
            return nil
        }
        return NSRange(location: triggerLocation, length: 1)
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
