//
//  MarkdownStyler+BulletMarkers.swift
//  MarkdownEngine
//
//  Renders `-`/`*`/`+` markers as `•` via hide-and-draw; storage stays raw.
//

import AppKit
import Foundation

extension MarkdownStyler {

    /// Optionally-indented bullet marker at line start, NOT a task checkbox.
    /// Trailing `[ \t]+` excludes thematic breaks (`---`) and emphasis (`*bold*`).
    static let bulletListRegex: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*+])([ \t]+)(?!\[[ xX]\])"#,
        options: [.anchorsMatchLines]
    )

    // MARK: Bullet Syntax Membership

    /// `<marker><spaces>` range on `location`'s line, or `nil` if the caret isn't strictly inside.
    static func bulletSyntaxRange(at location: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        let safeLoc = max(0, min(location, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        let line = nsText.substring(with: lineRange)
        guard let match = bulletListRegex.firstMatch(
            in: line,
            options: [],
            range: NSRange(location: 0, length: line.utf16.count)
        ) else { return nil }
        let markerLineRange = match.range(at: 2)
        let spacerLineRange = match.range(at: 3)
        guard markerLineRange.location != NSNotFound,
              spacerLineRange.location != NSNotFound else { return nil }
        let syntaxStart = lineRange.location + markerLineRange.location
        let syntaxEnd = lineRange.location + spacerLineRange.location + spacerLineRange.length
        let syntaxRange = NSRange(location: syntaxStart, length: syntaxEnd - syntaxStart)
        if NSLocationInRange(location, syntaxRange) {
            return syntaxRange
        }
        return nil
    }

    // MARK: Bullet Markers

    static func styleBulletMarkers(_ ctx: StylingContext) -> [StyledRange] {
        guard ctx.configuration.lists.helpersEnabled else { return [] }
        var attrs: [StyledRange] = []
        let matches = bulletListRegex.matches(in: ctx.text, options: [], range: ctx.fullRange)
        for match in matches {
            let markerRange = match.range(at: 2)
            let spacerRange = match.range(at: 3)
            if markerRange.location == NSNotFound { continue }
            if MarkdownDetection.isInsideCodeBlock(range: markerRange, codeTokens: ctx.codeTokens) { continue }

            // Reveal raw marker only while caret is strictly inside the syntax.
            let syntaxStart = markerRange.location
            let syntaxEnd = spacerRange.location + spacerRange.length
            let isActiveSyntax = NSLocationInRange(ctx.caretLocation, NSRange(location: syntaxStart, length: syntaxEnd - syntaxStart))
            if isActiveSyntax { continue }

            // Hide marker char + tag for `•` overlay; trailing space stays visible.
            attrs.append((markerRange, [
                .bulletMarker: true,
                .foregroundColor: NSColor.clear
            ]))
        }
        return attrs
    }
}
