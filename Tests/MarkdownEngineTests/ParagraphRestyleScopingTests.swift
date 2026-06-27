//
//  ParagraphRestyleScopingTests.swift
//  MarkdownEngineTests
//
//  Cross-platform regression net for `ParagraphRestyleScoping` — the pure paragraph-scope
//  computation that lets the iOS editor restyle only the affected paragraphs per keystroke.
//  Getting the scope wrong leaves stale styling, so these pin the rules on the host.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Paragraph restyle scoping")
struct ParagraphRestyleScopingTests {

    // "foo\n" = (0,4), "bar\n" = (4,4), "baz" = (8,3); total length 11.
    private let threeParagraphs = "foo\nbar\nbaz" as NSString

    // MARK: - paragraphs(intersecting:)

    @Test("A single-paragraph edit scopes to just that paragraph")
    func singleParagraphEdit() {
        let result = ParagraphRestyleScoping.paragraphs(in: threeParagraphs, intersecting: NSRange(location: 5, length: 1))
        #expect(result == [NSRange(location: 4, length: 4)])
    }

    @Test("An edit spanning two paragraphs returns both")
    func multiParagraphEdit() {
        let result = ParagraphRestyleScoping.paragraphs(in: threeParagraphs, intersecting: NSRange(location: 4, length: 5))
        #expect(result == [NSRange(location: 4, length: 4), NSRange(location: 8, length: 3)])
    }

    @Test("A zero-length edit (insertion point) scopes to its paragraph")
    func insertionPoint() {
        let result = ParagraphRestyleScoping.paragraphs(in: threeParagraphs, intersecting: NSRange(location: 9, length: 0))
        #expect(result == [NSRange(location: 8, length: 3)])
    }

    @Test("Empty text yields no paragraphs")
    func emptyText() {
        #expect(ParagraphRestyleScoping.paragraphs(in: "", intersecting: NSRange(location: 0, length: 0)).isEmpty)
    }

    // MARK: - caretNeighborhood

    @Test("A middle paragraph contributes previous, current, and next")
    func neighborhoodMiddle() {
        let result = ParagraphRestyleScoping.caretNeighborhood(in: threeParagraphs, caretParagraph: NSRange(location: 4, length: 4))
        #expect(result == [
            NSRange(location: 0, length: 4),
            NSRange(location: 4, length: 4),
            NSRange(location: 8, length: 3),
        ])
    }

    @Test("The first paragraph has no previous (NSNotFound placeholder)")
    func neighborhoodFirst() {
        let result = ParagraphRestyleScoping.caretNeighborhood(in: threeParagraphs, caretParagraph: NSRange(location: 0, length: 4))
        #expect(result[0].location == NSNotFound)
        #expect(result[1] == NSRange(location: 0, length: 4))
        #expect(result[2] == NSRange(location: 4, length: 4))
    }

    @Test("The last paragraph has no next (NSNotFound placeholder)")
    func neighborhoodLast() {
        let result = ParagraphRestyleScoping.caretNeighborhood(in: threeParagraphs, caretParagraph: NSRange(location: 8, length: 3))
        #expect(result[0] == NSRange(location: 4, length: 4))
        #expect(result[1] == NSRange(location: 8, length: 3))
        #expect(result[2].location == NSNotFound)
    }

    // MARK: - normalize

    @Test("normalize drops NSNotFound + empty ranges and dedupes")
    func normalizeDropsAndDedupes() {
        let input = [
            NSRange(location: 0, length: 4),
            NSRange(location: 0, length: 4),                 // duplicate
            NSRange(location: NSNotFound, length: 2),        // placeholder
            NSRange(location: 4, length: 0),                 // empty
            NSRange(location: 4, length: 4),
        ]
        let result = ParagraphRestyleScoping.normalize(input, documentLength: 11)
        #expect(result == [NSRange(location: 0, length: 4), NSRange(location: 4, length: 4)])
    }

    @Test("normalize clips a candidate to the document bounds")
    func normalizeClips() {
        let result = ParagraphRestyleScoping.normalize([NSRange(location: 8, length: 10)], documentLength: 11)
        #expect(result == [NSRange(location: 8, length: 3)])
    }

    // MARK: - backtickFenceCount

    @Test("backtickFenceCount counts ``` fences")
    func fenceCount() {
        #expect(ParagraphRestyleScoping.backtickFenceCount(in: "no fences") == 0)
        #expect(ParagraphRestyleScoping.backtickFenceCount(in: "```\ncode\n```") == 2)
        #expect(ParagraphRestyleScoping.backtickFenceCount(in: "a ``` b ``` c ```") == 3)
    }

    // MARK: - tokenRestyleParagraphs (token-driven)

    @Test("A token entering the active set contributes its paragraph")
    func activeTokenParagraph() {
        let text = "see **bold** here" as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text as String)
        guard let boldIndex = tokens.firstIndex(where: { $0.kind == .bold }) else {
            Issue.record("expected a bold token"); return
        }
        let result = ParagraphRestyleScoping.tokenRestyleParagraphs(
            in: text, tokens: tokens, currentActive: [boldIndex], previousActive: []
        )
        // The whole single-line paragraph is the bold token's paragraph.
        #expect(result.contains(NSRange(location: 0, length: text.length)))
    }

    @Test("A code block also contributes its fence-marker paragraphs")
    func codeBlockMarkerParagraphs() {
        let text = "```\ncode\n```" as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text as String)
        guard let codeIndex = tokens.firstIndex(where: { $0.kind == .codeBlock }) else {
            Issue.record("expected a code-block token"); return
        }
        let result = ParagraphRestyleScoping.tokenRestyleParagraphs(
            in: text, tokens: tokens, currentActive: [codeIndex], previousActive: []
        )
        // Opening fence paragraph (0,4 = "```\n") should be present among the marker paragraphs.
        #expect(result.contains(NSRange(location: 0, length: 4)))
    }

    @Test("No active-state change yields no paragraphs")
    func noActiveChange() {
        let text = "plain text" as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text as String)
        let result = ParagraphRestyleScoping.tokenRestyleParagraphs(
            in: text, tokens: tokens, currentActive: [], previousActive: []
        )
        #expect(result.isEmpty)
    }
}
