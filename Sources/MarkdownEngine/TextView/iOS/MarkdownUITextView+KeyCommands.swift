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
        var commands = formatting
        // Parity with the macOS `endsEditingOnEscape` config flag: a hardware-keyboard Escape
        // ends the edit session. Only bound when the host opted in. `wantsPriorityOverSystemBehavior`
        // is deliberately `true` — the flag's contract is "Escape ends editing", so it must win over
        // a system Escape-dismisses-the-sheet even inside the sheet/popover this feature targets;
        // otherwise the flag would be a silent no-op there. Once this resigns and the keyboard drops,
        // the text view is no longer first responder, so a *second* Escape falls through to the
        // system (dismiss the sheet) — the usual progressive behavior. iPad-with-keyboard only;
        // there's no on-screen-keyboard equivalent.
        //
        // Gate on `markedTextRange == nil` so the command *disappears* during an IME composition:
        // UIKit re-queries `keyCommands` per press (the `isEditable` gate above relies on the same
        // fact), and because this command asserts priority it would otherwise be resolved BEFORE
        // the text-input system and consume Escape with no way to decline — swallowing the key so
        // it neither ends editing nor reaches the IME to cancel the conversion. Absent the command,
        // Escape flows to the input system mid-composition. `mdKeyEscape` keeps a belt-and-suspenders
        // guard for any press that races a composition that began after the getter ran.
        if configuration.endsEditingOnEscape, markedTextRange == nil {
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(mdKeyEscape))
            escape.wantsPriorityOverSystemBehavior = true
            commands.append(escape)
        }
        // Slash menu keyboard navigation: bind ↑/↓/↵ ONLY while the menu is open, so they keep their
        // normal editing behavior otherwise (UIKit re-queries `keyCommands` per press, so these
        // appear and disappear with the menu). Priority over the system so ↵ picks the highlighted
        // block instead of inserting a newline. Dropped mid-IME-composition for the same reason as
        // Escape above (a priority command would otherwise swallow the key before the input system).
        if slashMenuIsActive, markedTextRange == nil {
            let navigation = [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(mdKeySlashHighlightUp)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(mdKeySlashHighlightDown)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(mdKeySlashConfirm)),
            ]
            for command in navigation { command.wantsPriorityOverSystemBehavior = true }
            commands.append(contentsOf: navigation)
        }
        return inherited + commands
    }

    @objc private func mdKeyBold() { applyFormatting(.bold, in: selectedRange) }
    @objc private func mdKeyItalic() { applyFormatting(.italic, in: selectedRange) }
    @objc private func mdKeyStrikethrough() { applyFormatting(.strikethrough, in: selectedRange) }
    @objc private func mdKeyInlineCode() { applyFormatting(.inlineCode, in: selectedRange) }
    @objc private func mdKeyParagraph() { clearBlockFormatting(in: selectedRange) }

    @objc private func mdKeySlashHighlightUp() { moveSlashMenuHighlight(by: -1) }
    @objc private func mdKeySlashHighlightDown() { moveSlashMenuHighlight(by: 1) }
    @objc private func mdKeySlashConfirm() { confirmSlashMenuHighlight() }

    @objc private func mdKeyEscape() {
        // Belt-and-suspenders: the `keyCommands` getter already drops this command mid-composition,
        // but guard here too in case a composition began after the getter ran. Escape then means
        // "cancel the IME conversion", which we leave to the input system.
        guard markedTextRange == nil else { return }
        // Progressive Escape, mirroring macOS: first Escape closes an open slash menu; only a bare
        // Escape (no menu) ends the edit session. resignFirstResponder() fires textViewDidEndEditing
        // → the focus reporter writes `false` back to any host binding.
        if dismissSlashMenuContextIfPresent() { return }
        resignFirstResponder()
    }
}
#endif
