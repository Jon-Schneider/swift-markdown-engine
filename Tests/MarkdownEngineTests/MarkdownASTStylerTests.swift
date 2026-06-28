//
//  MarkdownASTStylerTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5b — the AST styler composes nested/combined inline styles instead
//  of overwriting them (the flat 18-pass styler's flaw).
//

#if os(macOS)
// Guarded macOS-only because this test's imports use AppKit font/image types
// (NSFont/NSImage/NSApplication). The styler/parser logic it exercises is
// cross-platform; the guard just lets the shared MarkdownEngineTests target
// also compile for the iOS simulator (where the UIKit verify-suites run).
// TODO: re-express on PlatformFont/PlatformImage to also run on iOS.
import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2.5b — AST styler font composition")
struct MarkdownASTStylerTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    /// Effective font at `pos`: the last styled range covering it that sets `.font`.
    private func font(in attrs: [StyledRange], at pos: Int) -> NSFont? {
        var result: NSFont?
        for (range, a) in attrs where NSLocationInRange(pos, range) {
            if let f = a[.font] as? NSFont { result = f }
        }
        return result
    }

    /// Per-keystroke perf: scoping a restyle to the edited paragraph must produce
    /// the EXACT same attributes within that paragraph as a full-document style.
    /// This is the safety net for the `scopedRanges` fast path — it can't diverge
    /// from the full rebuild (no glitch).
    @MainActor
    @Test("scoped styling == full styling, clipped to the edited paragraph")
    func scopedMatchesFullForEditedParagraph() {
        _ = NSApplication.shared
        let text = "plain one\n\n**bold** in two `code`\n\n- item *x*\n\nhttps://example.com"
        let ns = text as NSString
        let para = ns.paragraphRange(for: NSRange(location: 13, length: 0))   // the `**bold**…` line
        func keys(_ scoped: [NSRange]?) -> String {
            let r = MarkdownASTStyler.styleAttributes(
                text: text, fontName: fontName, fontSize: base, scopedRanges: scoped
            ).filter { NSIntersectionRange($0.range, para).length > 0 }
            return styleKeySnapshot(r)
        }
        #expect(keys([para]) == keys(nil))
    }

    @Test("bold inside a heading stays heading-size and consistent (fixes # **n*o*des**)")
    func headingBoldComposesToHeadingSize() {
        let attrs = MarkdownASTStyler.styleAttributes(text: "# **n*o*des**", fontName: fontName, fontSize: base)
        // "# **n*o*des**": n=4, o=6, d=8
        let n = font(in: attrs, at: 4)
        let o = font(in: attrs, at: 6)
        let d = font(in: attrs, at: 8)

        // The fix: every emphasized char is the SAME (heading) size — not "o" big, "n/des" small.
        #expect(n?.pointSize == o?.pointSize)
        #expect(n?.pointSize == d?.pointSize)
        #expect((n?.pointSize ?? 0) > base)   // heading-size, not base

        // Correct composed traits.
        #expect(n?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(d?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(o?.fontDescriptor.symbolicTraits.contains([.bold, .italic]) == true)
    }

    @Test("nested emphasis in a paragraph composes bold+italic")
    func paragraphNestedEmphasis() {
        let attrs = MarkdownASTStyler.styleAttributes(text: "**a *b* c**", fontName: fontName, fontSize: base)
        // "**a *b* c**": a=2, b=5, c=8
        let a = font(in: attrs, at: 2)
        let b = font(in: attrs, at: 5)
        #expect(a?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(a?.fontDescriptor.symbolicTraits.contains(.italic) == false)
        #expect(b?.fontDescriptor.symbolicTraits.contains([.bold, .italic]) == true)
    }

    /// Code is not prose: fenced blocks and inline `code` spans must carry
    /// `.spellingState: 0` so the system spell-checker leaves them alone,
    /// matching the existing convention that links / wiki-links / LaTeX / tables
    /// already follow.
    @Test("code blocks and inline code receive .spellingState: 0; prose does not")
    func codeRegionsSuppressSpellCheck() {
        let text = "prose word\n\n```\nfencedcd notaword\n```\n\nplain `inlnecode` tail"
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base)
        let ns = text as NSString
        let fencedContent = ns.range(of: "fencedcd notaword")
        let inlineSpan = ns.range(of: "`inlnecode`")
        let prose = ns.range(of: "prose word")

        // Pull every `.spellingState` value from styled ranges that intersect `r`.
        func spellingStates(intersecting r: NSRange) -> [Int] {
            attrs.compactMap { entry -> Int? in
                guard NSIntersectionRange(entry.range, r).length > 0 else { return nil }
                return entry.attributes[.spellingState] as? Int
            }
        }

        #expect(spellingStates(intersecting: fencedContent).contains(0))
        #expect(spellingStates(intersecting: inlineSpan).contains(0))
        #expect(spellingStates(intersecting: prose).isEmpty)
    }
}

/// Seamless mode collapses the ``` fence *lines* of a code block to ~1px so the
/// block renders as just its styled body — no visible fences, no empty bands.
/// These tests assert the paragraph-style contract the renderer relies on; the
/// actual pixel collapse is a render concern verified in the simulator.
@Suite("Seamless code-block fence collapse")
struct SeamlessCodeBlockFenceTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }
    private let seamless = MarkdownEditorConfiguration(markers: .seamless)

    /// Effective `maximumLineHeight` at `pos`: the last styled range covering it
    /// that sets `.paragraphStyle` wins (mirrors how TextKit applies attributes).
    private func maxLineHeight(in attrs: [StyledRange], at pos: Int) -> CGFloat? {
        var result: CGFloat?
        for (range, a) in attrs where NSLocationInRange(pos, range) {
            if let p = a[.paragraphStyle] as? NSParagraphStyle { result = p.maximumLineHeight }
        }
        return result
    }

    private func style(_ text: String, _ config: MarkdownEditorConfiguration) -> [StyledRange] {
        MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base, configuration: config)
    }

    @Test("seamless collapses both fence lines while the body keeps full height")
    func seamlessCollapsesFences() {
        // "```\ncode\n```": open fence chars 0–3, body "code" 4–8, close fence 9–11.
        let attrs = style("```\ncode\n```", seamless)
        #expect(maxLineHeight(in: attrs, at: 1) == 1)    // open fence
        #expect(maxLineHeight(in: attrs, at: 10) == 1)   // close fence
        let body = maxLineHeight(in: attrs, at: 5)       // "code"
        #expect((body ?? 0) > 1)                          // full code line height, not collapsed
    }

    @Test("revealOnEdit (default) does NOT collapse fences — pixel-identical to today")
    func defaultDoesNotCollapse() {
        let attrs = style("```\ncode\n```", .default)
        #expect(maxLineHeight(in: attrs, at: 1) != 1)    // open fence keeps codeLineHeight
        #expect(maxLineHeight(in: attrs, at: 10) != 1)   // close fence keeps codeLineHeight
    }

    @Test("empty code block collapses both fences without crashing")
    func emptyBlockCollapses() {
        // "```\n```": open fence 0–3, close fence 4–6, no body.
        let attrs = style("```\n```", seamless)
        #expect(maxLineHeight(in: attrs, at: 1) == 1)
        #expect(maxLineHeight(in: attrs, at: 5) == 1)
    }

    @Test("unterminated fence collapses the open fence but never the body line")
    func unterminatedFenceGuard() {
        // "```\ncode" — no closing fence; the body must keep its height (the
        // `closeFence.length > 0` guard prevents collapsing a non-fence line).
        let attrs = style("```\ncode", seamless)
        #expect(maxLineHeight(in: attrs, at: 1) == 1)    // open fence collapses
        #expect(maxLineHeight(in: attrs, at: 5) != 1)    // body "code" is not a fence
    }

    @Test("code block at document start and end collapses without out-of-range")
    func blockAtDocumentEdges() {
        // Block at the very start, then prose; and a block at the very end.
        let start = style("```\nx\n```\n\nafter", seamless)
        #expect(maxLineHeight(in: start, at: 1) == 1)
        let end = style("intro\n\n```\nx\n```", seamless)
        // Close fence is the final paragraph with no trailing newline.
        let ns = "intro\n\n```\nx\n```" as NSString
        let closeFencePos = ns.range(of: "```", options: .backwards).location + 1
        #expect(maxLineHeight(in: end, at: closeFencePos) == 1)
    }
}

/// Canonical, order-independent string of styled ranges so two style runs can be
/// compared for equality.
private func styleKeySnapshot(_ ranges: [StyledRange]) -> String {
    let lines = ranges
        .map { entry -> (NSRange, [String]) in
            (entry.range, entry.attributes.keys.map(\.rawValue).sorted())
        }
        .sorted { a, b in
            if a.0.location != b.0.location { return a.0.location < b.0.location }
            if a.0.length != b.0.length { return a.0.length < b.0.length }
            return a.1.joined(separator: ",") < b.1.joined(separator: ",")
        }
        .map { "@\(fmt($0.0)) keys=[\($0.1.joined(separator: ","))]" }
    return lines.isEmpty ? "(no styled ranges)" : lines.joined(separator: "\n")
}

private func fmt(_ r: NSRange) -> String {
    r.location == NSNotFound ? "∅" : "\(r.location)+\(r.length)"
}
#endif
