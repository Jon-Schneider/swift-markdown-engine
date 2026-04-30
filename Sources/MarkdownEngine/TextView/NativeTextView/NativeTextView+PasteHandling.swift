//
//  NativeTextView+PasteHandling.swift
//  MarkdownEngine
//
//  Paste interception: route pasted images through `onPasteImage`, ensure the
//  embed lands on its own line, and validate the paste menu item against the
//  pasteboard's available types.
//

import AppKit

extension NativeTextView {
    override func paste(_ sender: Any?) {
        guard isEditable else {
            super.paste(sender)
            return
        }

        let pasteboard = NSPasteboard.general
        if let imageEmbed = onPasteImage?(pasteboard), !imageEmbed.isEmpty {
            let sel = selectedRange()
            let nsText = string as NSString

            // Ensure the image embed lands on its own line.
            var prefix = ""
            var suffix = ""
            if sel.location > 0 {
                let charBefore = nsText.character(at: sel.location - 1)
                if charBefore != 0x0A {
                    prefix = "\n"
                }
            }
            let afterLocation = sel.location + sel.length
            if afterLocation < nsText.length {
                let charAfter = nsText.character(at: afterLocation)
                if charAfter != 0x0A {
                    suffix = "\n"
                }
            }

            insertText(prefix + imageEmbed + suffix, replacementRange: sel)
            return
        }

        if let pasted = pasteboard.string(forType: .string) {
            let sanitized = sanitizePastedText(pasted)
            if !sanitized.isEmpty {
                insertText(sanitized, replacementRange: selectedRange())
                return
            }
        }
        pasteAsPlainText(sender)
    }

    private func sanitizePastedText(_ s: String) -> String {
        var out = s
        if let regex = try? NSRegularExpression(pattern: "\\n{3,}") {
            let nsRange = NSRange(location: 0, length: (out as NSString).length)
            out = regex.stringByReplacingMatches(in: out, range: nsRange, withTemplate: "\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            if PasteboardImageReader.canPasteImage(from: NSPasteboard.general) {
                return true
            }
        }
        return super.validateUserInterfaceItem(item)
    }
}
