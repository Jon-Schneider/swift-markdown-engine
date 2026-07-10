//
//  MarkdownUITextView+KeyCommands.swift
//  MarkdownEngine
//
//  Hardware-keyboard shortcuts for the iOS editor. UITextView binds no bold/italic key
//  equivalents of its own, so a host could only route ⌘B through an app-level menu command
//  (disabled inside sheets). These bind the common formatting shortcuts on the text view
//  itself, routed through the same `applyFormatting` core as the toolbar / context menu:
//    ⌘B bold · ⌘I italic · ⌘⇧X strikethrough · ⌘E inline code · ⌥⌘0 clear block (paragraph)
//
#if canImport(UIKit)
import UIKit

extension MarkdownUITextView {
    public override var keyCommands: [UIKeyCommand]? {
        let inherited = super.keyCommands ?? []
        guard isEditable else { return inherited.isEmpty ? nil : inherited }
        let formatting = [
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(mdKeyBold)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(mdKeyItalic)),
            UIKeyCommand(input: "x", modifierFlags: [.command, .shift], action: #selector(mdKeyStrikethrough)),
            UIKeyCommand(input: "e", modifierFlags: .command, action: #selector(mdKeyInlineCode)),
            UIKeyCommand(input: "0", modifierFlags: [.command, .alternate], action: #selector(mdKeyParagraph)),
        ]
        // Take priority so the shortcuts fire even where the system might otherwise consume them.
        for command in formatting { command.wantsPriorityOverSystemBehavior = true }
        return inherited + formatting
    }

    @objc private func mdKeyBold() { applyFormatting(.bold, in: selectedRange) }
    @objc private func mdKeyItalic() { applyFormatting(.italic, in: selectedRange) }
    @objc private func mdKeyStrikethrough() { applyFormatting(.strikethrough, in: selectedRange) }
    @objc private func mdKeyInlineCode() { applyFormatting(.inlineCode, in: selectedRange) }
    @objc private func mdKeyParagraph() { clearBlockFormatting(in: selectedRange) }
}
#endif
