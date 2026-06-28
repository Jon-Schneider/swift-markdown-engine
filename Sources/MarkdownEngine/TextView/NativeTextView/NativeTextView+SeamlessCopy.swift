//
//  NativeTextView+SeamlessCopy.swift
//  MarkdownEngine
//
//  Copy/Cut in seamless mode place the *visible* text on the pasteboard — the
//  hidden Markdown markers are stripped — matching what the user sees on screen
//  (the locked "copy visible text" semantic). Outside seamless mode the system
//  copy/cut is used unchanged, so the macOS editor's historical behavior (which
//  copies the raw Markdown source) is preserved.
//
//  KNOWN RAW-SOURCE LEAK PATHS (intentionally NOT intercepted). Only `copy(_:)`
//  and `cut(_:)` are overridden, so the visible-text contract applies to ⌘C/⌘X
//  and the Copy/Cut menu items. Other AppKit text-export paths still emit the raw
//  buffer (markers and all) because they bypass these methods:
//    - drag-and-drop of the selection (NSDraggingSource / `writeSelection`),
//    - the Services menu (`validRequestorForSendType` / `writeSelection`),
//    - any host-driven `attributedString` read.
//  This is an accepted scope boundary for the "copy visible text" item, not an
//  oversight: drag/Services are not "copy". If a future requirement needs them
//  covered, override the drag-source / services write path to route through
//  `MarkdownSeamlessInput.visibleText` the same way `copy`/`cut` do.
//
#if os(macOS)
import AppKit

extension NativeTextView {

    override func copy(_ sender: Any?) {
        guard configuration.markers.visibility == .seamless,
              selectedRange().length > 0 else {
            super.copy(sender)
            return
        }
        writeVisibleSelectionToPasteboard()
    }

    override func cut(_ sender: Any?) {
        let range = selectedRange()
        guard configuration.markers.visibility == .seamless, range.length > 0 else {
            super.cut(sender)
            return
        }
        writeVisibleSelectionToPasteboard()
        // Delete the selection through the normal text path so undo + restyle fire.
        guard shouldChangeText(in: range, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: range, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: 0))
    }

    private func writeVisibleSelectionToPasteboard() {
        let visible = MarkdownSeamlessInput.visibleText(
            of: selectedRange(), in: string, configuration: configuration
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(visible, forType: .string)
    }
}
#endif
