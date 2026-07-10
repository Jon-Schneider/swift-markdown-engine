#if os(macOS)
//
//  ContextMenu.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 20.06.25.
//
//  Right-click menu with toggleable Markdown formatting actions.
//

import Cocoa
import SwiftUI

extension NativeTextViewWrapper.Coordinator {
    public func textView(_ textView: NSTextView,
                  menu: NSMenu,
                  for event: NSEvent,
                  at charIndex: Int) -> NSMenu? {
        let customMenu = menu.copy() as? NSMenu ?? NSMenu()

        if let fontIndex = customMenu.items.firstIndex(where: { $0.title == "Font" }) {
            customMenu.removeItem(at: fontIndex)
            let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
            let formatSubmenu = NSMenu(title: "Format")
            let boldItem = NSMenuItem(title: "Bold", action: #selector(didMarkdownBold(_:)), keyEquivalent: "")
            boldItem.target = self
            formatSubmenu.addItem(boldItem)
            let italicItem = NSMenuItem(title: "Italic", action: #selector(didMarkdownItalic(_:)), keyEquivalent: "")
            italicItem.target = self
            formatSubmenu.addItem(italicItem)
            let strikethroughItem = NSMenuItem(title: "Strikethrough", action: #selector(didMarkdownStrikethrough(_:)), keyEquivalent: "")
            strikethroughItem.target = self
            formatSubmenu.addItem(strikethroughItem)
            let inlineCodeItem = NSMenuItem(title: "Inline Code", action: #selector(didMarkdownInlineCode(_:)), keyEquivalent: "")
            inlineCodeItem.target = self
            formatSubmenu.addItem(inlineCodeItem)
            formatSubmenu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Clear Formatting", action: #selector(didMarkdownClearFormatting(_:)), keyEquivalent: "")
            clearItem.target = self
            formatSubmenu.addItem(clearItem)
            formatItem.submenu = formatSubmenu
            customMenu.insertItem(formatItem, at: fontIndex)

            let headingItem = NSMenuItem(title: "Heading", action: nil, keyEquivalent: "")
            let headingSubmenu = NSMenu(title: "Heading")
            for level in 1...3 {
                let item = NSMenuItem(title: "H\(level)", action: #selector(didMarkdownHeading(_:)), keyEquivalent: "")
                item.target = self
                item.tag = level
                headingSubmenu.addItem(item)
            }
            headingItem.submenu = headingSubmenu
            customMenu.insertItem(headingItem, at: fontIndex + 1)

            let listItem = NSMenuItem(title: "Lists", action: nil, keyEquivalent: "")
            let listSubmenu = NSMenu(title: "Lists")
            let unorderedItem = NSMenuItem(title: "Bullet", action: #selector(didMarkdownUnorderedList(_:)), keyEquivalent: "")
            unorderedItem.target = self
            listSubmenu.addItem(unorderedItem)
            let orderedItem = NSMenuItem(title: "Numbered", action: #selector(didMarkdownOrderedList(_:)), keyEquivalent: "")
            orderedItem.target = self
            listSubmenu.addItem(orderedItem)
            let checkboxItem = NSMenuItem(title: "Checkbox", action: #selector(didMarkdownToggleCheckbox(_:)), keyEquivalent: "")
            checkboxItem.target = self
            listSubmenu.addItem(checkboxItem)
            let indentItem = NSMenuItem(title: "Indent", action: #selector(didMarkdownIndent(_:)), keyEquivalent: "")
            indentItem.target = self
            listSubmenu.addItem(indentItem)
            let outdentItem = NSMenuItem(title: "Outdent", action: #selector(didMarkdownOutdent(_:)), keyEquivalent: "")
            outdentItem.target = self
            listSubmenu.addItem(outdentItem)
            listItem.submenu = listSubmenu
            customMenu.insertItem(listItem, at: fontIndex + 2)

            let blockItem = NSMenuItem(title: "Block", action: nil, keyEquivalent: "")
            let blockSubmenu = NSMenu(title: "Block")
            let quoteItem = NSMenuItem(title: "Quote", action: #selector(didMarkdownBlockquote(_:)), keyEquivalent: "")
            quoteItem.target = self
            blockSubmenu.addItem(quoteItem)
            let codeBlockItem = NSMenuItem(title: "Code Block", action: #selector(didMarkdownCodeBlock(_:)), keyEquivalent: "")
            codeBlockItem.target = self
            blockSubmenu.addItem(codeBlockItem)
            blockItem.submenu = blockSubmenu
            customMenu.insertItem(blockItem, at: fontIndex + 3)

            customMenu.insertItem(NSMenuItem.separator(), at: fontIndex + 4)
        }

        return customMenu
    }

    /// Returns the smallest bold or boldItalic token that fully contains the selection, or nil when the selection isn't enclosed by emphasis with a bold trait.
    func enclosingBoldToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { token in
            (token.kind == .bold || token.kind == .boldItalic) && tokenEncloses(token, selection: selection)
        }
    }

    /// Returns the smallest italic or boldItalic token that fully contains the selection, or nil when the selection isn't enclosed by emphasis with an italic trait.
    func enclosingItalicToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        let tokens = parsedDocument(for: text).tokens
        return tokens.first { token in
            (token.kind == .italic || token.kind == .boldItalic) && tokenEncloses(token, selection: selection)
        }
    }

    func isSelectionBold(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingBoldToken(for: range, in: nsText as String) != nil
    }

    func isSelectionItalic(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingItalicToken(for: range, in: nsText as String) != nil
    }

    private func tokenEncloses(_ token: MarkdownToken, selection: NSRange) -> Bool {
        return selection.location >= token.range.location
            && NSMaxRange(selection) <= NSMaxRange(token.range)
    }

    /// Replaces the marker characters of an emphasis token with `replacement` on each side, preserving the inner content.
    private func unwrapToken(_ token: MarkdownToken, leftReplacement: String, rightReplacement: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let content = nsText.substring(with: token.contentRange)
        let newText = leftReplacement + content + rightReplacement
        if tv.shouldChangeText(in: token.range, replacementString: newText) {
            tv.replaceCharacters(in: token.range, with: newText)
            tv.didChangeText()
            let newSelectionLocation = token.range.location + leftReplacement.count
            tv.setSelectedRange(NSRange(location: newSelectionLocation, length: content.count))
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    func isSelectionHeading(level: Int, in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLine.hasPrefix(String(repeating: "#", count: level) + " ")
    }

    @objc func didMarkdownHeading(_ sender: NSMenuItem) {
        // Route through the shared core so the menu gets the same toggle-off (re-selecting the
        // active level clears the heading) the toolbar / key equivalents already have.
        applyMarkdownCommand(.heading(sender.tag))
    }

    /// Apply a `MarkdownFormattingCommand` through the shared cross-platform core
    /// (`MarkdownFormatting.edit`). Routes through the coordinator's single `applyFormatting`
    /// apply-flow (see `NativeTextViewCoordinator+Formatting`), which the host toolbar also uses,
    /// so context-menu and toolbar formatting stay identical. The older bold/italic/heading/list
    /// handlers keep their bespoke logic.
    private func applyMarkdownCommand(_ command: MarkdownFormattingCommand) {
        applyFormatting(command)
    }

    @objc func didMarkdownStrikethrough(_ sender: Any?) {
        applyMarkdownCommand(.strikethrough)
    }

    @objc func didMarkdownInlineCode(_ sender: Any?) {
        applyMarkdownCommand(.inlineCode)
    }

    @objc func didMarkdownClearFormatting(_ sender: Any?) {
        applyMarkdownCommand(.clearFormatting)
    }

    @objc func didMarkdownBlockquote(_ sender: Any?) {
        applyMarkdownCommand(.blockquote)
    }

    @objc func didMarkdownCodeBlock(_ sender: Any?) {
        applyMarkdownCommand(.codeBlock)
    }

    @objc func didMarkdownToggleCheckbox(_ sender: Any?) {
        applyMarkdownCommand(.toggleCheckbox)
    }

    @objc func didMarkdownIndent(_ sender: Any?) {
        applyMarkdownCommand(.indent)
    }

    @objc func didMarkdownOutdent(_ sender: Any?) {
        applyMarkdownCommand(.outdent)
    }

    @objc func didMarkdownUnorderedList(_ sender: Any?) {
        applyMarkdownCommand(.bulletList)
    }

    @objc func didMarkdownOrderedList(_ sender: Any?) {
        applyMarkdownCommand(.numberedList)
    }

    @objc func didMarkdownBold(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingBoldToken(for: range, in: tv.string) {
            // Toggle off: bold → plain, boldItalic → italic.
            let (left, right) = token.kind == .boldItalic ? ("*", "*") : ("", "")
            unwrapToken(token, leftReplacement: left, rightReplacement: right)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("**")
            return
        }

        wrapSelection(with: "**")
    }

    @objc func didMarkdownItalic(_ sender: Any?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()

        if let token = enclosingItalicToken(for: range, in: tv.string) {
            // Toggle off: italic → plain, boldItalic → bold.
            let (left, right) = token.kind == .boldItalic ? ("**", "**") : ("", "")
            unwrapToken(token, leftReplacement: left, rightReplacement: right)
            return
        }

        if range.length == 0 {
            insertEmptyMarkers("*")
            return
        }

        wrapSelection(with: "*")
    }

    private func insertEmptyMarkers(_ marker: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let insertion = marker + marker
        if tv.shouldChangeText(in: range, replacementString: insertion) {
            tv.replaceCharacters(in: range, with: insertion)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + marker.count, length: 0))
            DispatchQueue.main.async { self.text = tv.string }
        }
    }

    private func wrapSelection(with marker: String) {
        guard let tv = textView else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let original = nsText.substring(with: range)
        let leadingWS = original.prefix { $0.isWhitespace }.count
        let trailingWS = original.reversed().prefix { $0.isWhitespace }.count
        let coreStart = original.index(original.startIndex, offsetBy: leadingWS)
        let coreEnd = original.index(original.endIndex, offsetBy: -trailingWS)
        let core = coreStart <= coreEnd ? String(original[coreStart..<coreEnd]) : ""
        let leading = String(original[..<coreStart])
        let trailing = String(original[coreEnd...])
        let newText = leading + marker + core + marker + trailing
        if tv.shouldChangeText(in: range, replacementString: newText) {
            tv.replaceCharacters(in: range, with: newText)
            tv.didChangeText()
            let newRange = NSRange(location: range.location + leadingWS + marker.count, length: core.count)
            tv.setSelectedRange(newRange)
            DispatchQueue.main.async { self.text = tv.string }
        }
    }
}

// MARK: - Menu Item Validation
extension NativeTextViewWrapper.Coordinator: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let tv = textView else { return true }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        switch menuItem.action {
        case #selector(didMarkdownBold(_:)):
            menuItem.state = enclosingBoldToken(for: range, in: tv.string) != nil ? .on : .off
            return true
        case #selector(didMarkdownItalic(_:)):
            menuItem.state = enclosingItalicToken(for: range, in: tv.string) != nil ? .on : .off
            return true
        case #selector(didMarkdownStrikethrough(_:)):
            menuItem.state = MarkdownFormatting.isActive(.strikethrough, text: tv.string, selection: range) ? .on : .off
            return true
        case #selector(didMarkdownInlineCode(_:)):
            menuItem.state = MarkdownFormatting.isActive(.inlineCode, text: tv.string, selection: range) ? .on : .off
            return true
        case #selector(didMarkdownClearFormatting(_:)):
            // Enabled only when the Clear Formatting edit would actually change something.
            let edit = MarkdownFormatting.edit(for: .clearFormatting, text: tv.string, selection: range)
            return nsText.substring(with: edit.range) != edit.text
        case #selector(didMarkdownBlockquote(_:)):
            menuItem.state = MarkdownFormatting.isActive(.blockquote, text: tv.string, selection: range) ? .on : .off
            return true
        case #selector(didMarkdownCodeBlock(_:)):
            menuItem.state = MarkdownFormatting.isActive(.codeBlock, text: tv.string, selection: range) ? .on : .off
            return true
        case #selector(didMarkdownToggleCheckbox(_:)):
            menuItem.state = MarkdownFormatting.isActive(.toggleCheckbox, text: tv.string, selection: range) ? .on : .off
            return true
        case #selector(didMarkdownIndent(_:)), #selector(didMarkdownOutdent(_:)):
            // Enabled only on a list line (where the edit would actually change the text).
            let command: MarkdownFormattingCommand = menuItem.action == #selector(didMarkdownIndent(_:)) ? .indent : .outdent
            let edit = MarkdownFormatting.edit(for: command, text: tv.string, selection: range)
            return nsText.substring(with: edit.range) != edit.text
        case #selector(didMarkdownHeading(_:)):
            // Toggleable (like blockquote/codeBlock): checked when the line is this heading level,
            // and RE-selecting it clears the heading back to a paragraph. Always enabled.
            menuItem.state = isSelectionHeading(level: menuItem.tag, in: nsText, range: range) ? .on : .off
            return true
        case #selector(didMarkdownUnorderedList(_:)):
            menuItem.state = MarkdownFormatting.isActive(.bulletList, text: tv.string, selection: range) ? .on : .off
            return true
        case #selector(didMarkdownOrderedList(_:)):
            menuItem.state = MarkdownFormatting.isActive(.numberedList, text: tv.string, selection: range) ? .on : .off
            return true
        default:
            return true
        }
    }
}

#endif
