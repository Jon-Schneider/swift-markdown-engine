//
//  ParagraphRestyleScoping.swift
//  MarkdownEngine
//
//  Pure paragraph-scope computation for incremental restyle: given an edit or a
//  caret/active-token change, which paragraphs actually need re-styling. This lets the
//  iOS editor (`MarkdownUITextView`) restyle only the affected paragraphs per keystroke
//  instead of the whole document — the macOS coordinator already scopes this way
//  (`NativeTextViewCoordinator+Restyling` / `+TextDelegate`); these helpers mirror that
//  logic in one cross-platform, unit-testable place.
//
//  All inputs are an `NSString` + parsed tokens, so the rules are testable on the host
//  with no view. The caller assembles the candidate set, normalizes it, and applies a
//  scoped restyle (see `MarkdownUITextView.restyleScoped`).
//

import Foundation

enum ParagraphRestyleScoping {

    /// Paragraph ranges intersecting `editedRange` (the post-edit range of changed text).
    /// Mirrors the macOS `paragraphRanges(in:intersecting:)`.
    static func paragraphs(in text: NSString, intersecting editedRange: NSRange) -> [NSRange] {
        guard text.length > 0 else { return [] }
        guard editedRange.location != NSNotFound else { return [] }

        var start = editedRange.location
        let end = min(NSMaxRange(editedRange), text.length)
        if start >= text.length {
            start = max(0, text.length - 1)
        }
        if end <= start {
            return [text.paragraphRange(for: NSRange(location: start, length: 0))]
        }

        var ranges: [NSRange] = []
        var cursor = start
        while cursor < end {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            ranges.append(paragraph)
            let next = NSMaxRange(paragraph)
            if next <= cursor { break }
            cursor = next
        }
        return ranges
    }

    /// The caret paragraph's neighborhood — previous, current, next. An edit can affect
    /// adjacent paragraphs (a blank line splitting/merging, a setext underline restyling
    /// the line above). Out-of-document neighbors come back as `NSNotFound` ranges, which
    /// the caller's normalize step drops.
    static func caretNeighborhood(in text: NSString, caretParagraph: NSRange) -> [NSRange] {
        let documentLength = text.length
        let previous = caretParagraph.location > 0
            ? text.paragraphRange(for: NSRange(location: max(0, caretParagraph.location - 1), length: 0))
            : NSRange(location: NSNotFound, length: 0)
        let nextLocation = min(documentLength, NSMaxRange(caretParagraph))
        let next = nextLocation < documentLength
            ? text.paragraphRange(for: NSRange(location: nextLocation, length: 0))
            : NSRange(location: NSNotFound, length: 0)
        return [previous, caretParagraph, next]
    }

    /// Paragraphs of tokens whose active state changed (the caret entered/left them, so
    /// their raw markers reveal/hide), plus the marker-line paragraphs of code / block-LaTeX
    /// fences (whose open/close fence lines style independently of the body). Mirrors the
    /// macOS `tokenRestyleParagraphs(...)`.
    static func tokenRestyleParagraphs(
        in text: NSString,
        tokens: [MarkdownToken],
        currentActive: Set<Int>,
        previousActive: Set<Int>
    ) -> [NSRange] {
        var paragraphs: [NSRange] = []
        let indices = currentActive.union(previousActive)
        for idx in indices where idx >= 0 && idx < tokens.count {
            let token = tokens[idx]
            paragraphs.append(text.paragraphRange(for: token.range))
            if token.kind == .codeBlock || token.kind == .blockLatex {
                for markerRange in token.markerRanges {
                    paragraphs.append(text.paragraphRange(for: markerRange))
                }
            }
        }
        return paragraphs
    }

    /// Paragraphs of rendered-as-image inline/block tokens (inline + block LaTeX, image
    /// embeds). The macOS path restyles these on every edit/selection so a rendered block
    /// never strands stale raw source. Tables are covered via `tokenRestyleParagraphs`
    /// (their active-state transition) and don't need to be in this always-on set.
    static func renderedBlockParagraphs(in text: NSString, tokens: [MarkdownToken]) -> [NSRange] {
        tokens.compactMap { token in
            switch token.kind {
            case .inlineLatex, .blockLatex, .imageEmbed:
                return text.paragraphRange(for: token.range)
            default:
                return nil
            }
        }
    }

    /// Count of ```` ``` ```` fences. A change between two document states means a code-block
    /// boundary opened or closed, which can re-tokenize large regions below the edit — the
    /// caller should fall back to a full-document restyle in that case.
    static func backtickFenceCount(in text: String) -> Int {
        text.components(separatedBy: "```").count - 1
    }

    /// Drop `NSNotFound` / empty candidates, clip to the document, and dedupe exact repeats.
    /// Overlapping (but non-identical) paragraphs are kept — re-styling an overlap twice is
    /// idempotent, matching the macOS `normalize`.
    static func normalize(_ candidates: [NSRange], documentLength: Int) -> [NSRange] {
        let bounds = NSRange(location: 0, length: documentLength)
        var result: [NSRange] = []
        for candidate in candidates where candidate.location != NSNotFound && candidate.length > 0 {
            let clipped = NSIntersectionRange(candidate, bounds)
            guard clipped.length > 0 else { continue }
            if result.contains(where: { $0.location == clipped.location && $0.length == clipped.length }) {
                continue
            }
            result.append(clipped)
        }
        return result
    }
}
