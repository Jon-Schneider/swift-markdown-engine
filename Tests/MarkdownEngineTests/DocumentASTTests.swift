//
//  DocumentASTTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5a — the semantic document AST: blocks carrying parsed inline
//  children in absolute coordinates.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2.5a — document AST")
struct DocumentASTTests {

    private func r(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    @Test("paragraph carries its inline children")
    func paragraph() {
        #expect(DocumentAST.parse("a *b*") == [
            .paragraph(range: r(0, 5), inlines: [
                .text(r(0, 2)),
                .emphasis(.italic, range: r(2, 3), markers: [r(2, 1), r(4, 1)], children: [.text(r(3, 1))]),
            ]),
        ])
    }
}
