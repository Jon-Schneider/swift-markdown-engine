//
//  MacOSLinkAttributesTests.swift
//  MarkdownEngineTests
//
//  Pins the macOS link-display contract after the `underlinesResolvedLinks`
//  work. `NSTextView` paints every `.link` range with `linkTextAttributes`, and
//  auto-detected URLs / resolved wiki-links carry ONLY `.link` (no storage color
//  or underline of their own) — so this dictionary IS their entire appearance.
//  These assert the stock look is preserved by default and that the toggle
//  removes the underline while keeping the link color, for ALL link kinds.
//
//  Headless AppKit — macOS only.
//

#if os(macOS)
import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
struct MacOSLinkAttributesTests {

    private func makeTextView(
        _ configure: (inout MarkdownEditorConfiguration) -> Void
    ) -> NativeTextView {
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        var config = MarkdownEditorConfiguration.default
        configure(&config)
        view.configuration = config   // triggers applyLinkTextAttributes()
        return view
    }

    @Test("default links carry the theme link color and a single underline")
    func defaultLinksAreColoredAndUnderlined() {
        // A distinct color proves the theme value flows through (the default
        // `.linkColor` matches NSTextView's stock link color, so the default
        // look is unchanged; auto-links and wiki-links depend on this).
        let view = makeTextView { $0.theme.link = .systemPink }
        let attrs = view.linkTextAttributes ?? [:]
        #expect((attrs[.foregroundColor] as? NSColor) == .systemPink)
        #expect((attrs[.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue)
    }

    @Test("underlinesResolvedLinks = false drops the underline but keeps the color")
    func toggleOffRemovesUnderlineKeepsColor() {
        let view = makeTextView {
            $0.theme.link = .systemPink
            $0.link.underlinesResolvedLinks = false
        }
        let attrs = view.linkTextAttributes ?? [:]
        #expect((attrs[.foregroundColor] as? NSColor) == .systemPink)
        #expect(attrs[.underlineStyle] == nil)
    }
}
#endif
