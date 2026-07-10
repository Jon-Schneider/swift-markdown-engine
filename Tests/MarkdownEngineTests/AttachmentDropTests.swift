//
//  AttachmentDropTests.swift
//  MarkdownEngineTests
//
//  Cross-platform unit tests for the paste/drop value types: the disposition's
//  empty-reference normalization and the reference → Markdown wrapping. These have no
//  UIKit/AppKit dependency, so they run on every platform.
//

import Foundation
import UniformTypeIdentifiers
import Testing
@testable import MarkdownEngine

@Suite("Attachment disposition & DroppedItem wrapping")
struct AttachmentDropTests {

    @Test("An empty insert reference normalizes to .consumed so no empty ![]() is spliced")
    func emptyInsertBecomesConsumed() {
        if case .consumed = AttachmentDisposition.insert("").normalized {
            // expected
        } else {
            Issue.record("insert(\"\") should normalize to .consumed")
        }
    }

    @Test("A non-empty insert reference is preserved by normalization")
    func nonEmptyInsertUnchanged() {
        guard case .insert(let ref) = AttachmentDisposition.insert("ref://1").normalized else {
            Issue.record("insert(non-empty) should stay .insert"); return
        }
        #expect(ref == "ref://1")
    }

    @Test("consumed and declined pass through normalization untouched")
    func passthroughDispositions() {
        if case .consumed = AttachmentDisposition.consumed.normalized {} else {
            Issue.record(".consumed should stay .consumed")
        }
        if case .declined = AttachmentDisposition.declined.normalized {} else {
            Issue.record(".declined should stay .declined")
        }
    }

    @Test("An image item wraps its reference as an image embed")
    func imageWrapsAsEmbed() {
        let item = DroppedItem(data: nil, fileURL: nil, suggestedName: "photo.png",
                               isImage: true, type: .png)
        #expect(item.markdown(forReference: "store://abc") == "![](store://abc)")
    }

    @Test("A non-image item wraps its reference as a named link")
    func fileWrapsAsNamedLink() {
        let item = DroppedItem(data: nil, fileURL: nil, suggestedName: "report.pdf",
                               isImage: false, type: .pdf)
        #expect(item.markdown(forReference: "store://xyz") == "[report.pdf](store://xyz)")
    }

    @Test("A non-image item with an empty name falls back to the reference as the link text")
    func fileWithEmptyNameUsesReference() {
        let item = DroppedItem(data: nil, fileURL: nil, suggestedName: "",
                               isImage: false, type: nil)
        #expect(item.markdown(forReference: "store://xyz") == "[store://xyz](store://xyz)")
    }

    @Test("Markdown-significant chars are stripped from the filename label")
    func fileNameLabelSanitized() {
        let item = DroppedItem(data: nil, fileURL: nil, suggestedName: "budget]2026[q4]`x`\\$.pdf",
                               isImage: false, type: .pdf)
        #expect(item.markdown(forReference: "ref") == "[budget2026q4x.pdf](ref)")
    }

    @Test("A filename with link-breaking chars still PARSES as a single link (not just a string)")
    func fileNameLabelParsesAsLink() {
        // The real regression: escaping produced a string that the inline parser rejected
        // (a claimed escape span overlaps the link candidate). Assert the parser output.
        let item = DroppedItem(data: nil, fileURL: nil, suggestedName: "a]b[c`d\\e$f.pdf",
                               isImage: false, type: .pdf)
        let markdown = item.markdown(forReference: "store://ref")
        let nodes = InlineParser.parse(markdown)
        #expect(nodes.count == 1, "expected a single node, got \(nodes.count): \(markdown)")
        guard case .link(let range, _, _, _, _) = nodes.first else {
            Issue.record("expected a link node, got \(String(describing: nodes.first)) for \(markdown)")
            return
        }
        #expect(range == NSRange(location: 0, length: (markdown as NSString).length),
                "the link must span the whole generated markdown")
    }

    @Test("A newline in a filename is collapsed so the label still parses as a link")
    func fileNameNewlineCollapsed() {
        let item = DroppedItem(data: nil, fileURL: nil, suggestedName: "budget\n2026.pdf",
                               isImage: false, type: .pdf)
        let markdown = item.markdown(forReference: "ref")
        #expect(markdown == "[budget 2026.pdf](ref)")
        guard case .link = InlineParser.parse(markdown).first else {
            Issue.record("a newline filename must still parse as a link: \(markdown)"); return
        }
    }

    @Test("A well-formed filename is preserved as the link label")
    func ordinaryFileNamePreserved() {
        let item = DroppedItem(data: nil, fileURL: nil, suggestedName: "Q4 report (final).pdf",
                               isImage: false, type: .pdf)
        let markdown = item.markdown(forReference: "ref")
        #expect(markdown == "[Q4 report (final).pdf](ref)")
        // ...and it parses as one link.
        guard case .link = InlineParser.parse(markdown).first else {
            Issue.record("ordinary filename should parse as a link: \(markdown)"); return
        }
    }
}
