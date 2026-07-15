#if os(macOS)
import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Scheme-selective link pill styling")
struct LinkPillStylingTests {
    private let fontName = NSFont.systemFont(ofSize: 14).fontName

    private func attributes(
        in text: String,
        at position: Int,
        configuration: MarkdownEditorConfiguration
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [:]
        for (range, attributes) in MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: 14,
            configuration: configuration
        ) where NSLocationInRange(position, range) {
            result.merge(attributes) { _, new in new }
        }
        return result
    }

    @Test("default link styling does not add a pill")
    func defaultLinksRemainUnchanged() {
        let attrs = attributes(
            in: "[Issue](shipyard://issue/123)",
            at: 2,
            configuration: .default
        )

        #expect(attrs[.link] as? URL == URL(string: "shipyard://issue/123"))
        #expect(attrs[.linkPill] == nil)
    }

    @Test("configured URL schemes receive a pill without losing link behavior")
    func configuredSchemeReceivesPill() {
        var configuration = MarkdownEditorConfiguration.default
        configuration.theme.link = .systemBlue
        configuration.link.pillURLSchemes = ["SHIPYARD"]
        configuration.link.pillCornerRadius = 6
        configuration.link.pillHorizontalPadding = 4
        configuration.link.pillTopPadding = 1
        configuration.link.pillBottomPadding = 3
        configuration.link.pillBackgroundAlpha = 0.2

        let attrs = attributes(
            in: "[Issue](shipyard://issue/123)",
            at: 2,
            configuration: configuration
        )

        #expect(attrs[.link] as? URL == URL(string: "shipyard://issue/123"))
        let pillColor = attrs[.linkPill] as? NSColor
        #expect(pillColor?.alphaComponent == 0.2)
        #expect(configuration.link.pillTopPadding == 1)
        #expect(configuration.link.pillBottomPadding == 3)
    }

    @Test("non-matching schemes keep the normal link appearance")
    func nonMatchingSchemeDoesNotReceivePill() {
        var configuration = MarkdownEditorConfiguration.default
        configuration.link.pillURLSchemes = ["shipyard"]
        configuration.link.pillCornerRadius = 6

        let attrs = attributes(
            in: "[Website](https://example.com)",
            at: 2,
            configuration: configuration
        )

        #expect(attrs[.link] as? URL == URL(string: "https://example.com"))
        #expect(attrs[.linkPill] == nil)
    }

    @Test("a scheme alone does not opt into drawing without pill geometry")
    func schemeWithoutGeometryDoesNotReceivePill() {
        var configuration = MarkdownEditorConfiguration.default
        configuration.link.pillURLSchemes = ["shipyard"]

        let attrs = attributes(
            in: "[Issue](shipyard://issue/123)",
            at: 2,
            configuration: configuration
        )

        #expect(attrs[.linkPill] == nil)
    }

    @Test("vertical padding alone opts a configured scheme into pill drawing")
    func verticalPaddingEnablesPill() {
        var configuration = MarkdownEditorConfiguration.default
        configuration.link.pillURLSchemes = ["shipyard"]
        configuration.link.pillBottomPadding = 2

        let attrs = attributes(
            in: "[Issue](shipyard://issue/123)",
            at: 2,
            configuration: configuration
        )

        #expect(attrs[.linkPill] is NSColor)
    }
}
#endif
