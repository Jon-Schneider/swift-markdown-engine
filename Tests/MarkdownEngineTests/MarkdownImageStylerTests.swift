//
//  MarkdownImageStylerTests.swift
//  MarkdownEngineTests
//
//  Seamless mode treats an `![alt](url)` image as one atomic, always-rendered
//  unit, so it must NEVER show the "active" dual display (rendered image + dimmed
//  raw source). These tests drive `styleImageLinks` with the image token marked
//  active (the adversarial case) and assert the source stays collapsed in
//  seamless while still revealing in revealOnEdit.
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

/// Concrete stub that hands back a 1×1 image for any request, so `styleImageLinks`
/// passes its `guard let image` and reaches the collapse/visible branch.
private struct SinglePixelImageProvider: EmbeddedImageProvider {
    func image(for reference: EmbeddedImageRequest) -> PlatformImage? {
        NSImage(size: NSSize(width: 1, height: 1))
    }
    func fingerprint() -> AnyHashable { 1 }
}

@Suite("Seamless image atomic render")
struct MarkdownImageStylerTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    private func config(_ visibility: MarkerVisibility) -> MarkdownEditorConfiguration {
        MarkdownEditorConfiguration(
            services: MarkdownEditorServices(images: SinglePixelImageProvider()),
            markers: MarkerStyle(visibility: visibility)
        )
    }

    /// Most-negative `.kern` among styled ranges intersecting `range` (nil if none
    /// set a kern there). The collapse path zeroes the URL with a large negative
    /// kern; visibleSource leaves the URL as readable dimmed text (no kern).
    private func minKern(in attrs: [StyledRange], intersecting range: NSRange) -> CGFloat? {
        var values: [CGFloat] = []
        for (r, a) in attrs where NSIntersectionRange(r, range).length > 0 {
            if let k = a[.kern] as? CGFloat { values.append(k) }
        }
        return values.min()
    }

    private func style(_ text: String, _ visibility: MarkerVisibility, active: Set<Int>) -> [StyledRange] {
        MarkdownStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: base,
            caretLocation: 0, activeTokenIndices: active,
            colorScheme: .light, configuration: config(visibility)
        )
    }

    @Test("seamless keeps the URL collapsed even when the image token is active")
    func seamlessForcesCollapsed() {
        let text = "![cat](https://example.com/c.png)"
        let urlRange = (text as NSString).range(of: "https://example.com/c.png")
        // Mark every plausible token index active — the gate must override it.
        let attrs = style(text, .seamless, active: Set(0..<8))
        let kern = minKern(in: attrs, intersecting: urlRange)
        #expect(kern != nil && kern! < 0)   // URL collapsed to zero width → image-only
    }

    @Test("revealOnEdit still reveals the raw source for an active image")
    func revealOnEditShowsSource() {
        let text = "![cat](https://example.com/c.png)"
        let urlRange = (text as NSString).range(of: "https://example.com/c.png")
        let attrs = style(text, .revealOnEdit, active: Set(0..<8))
        let kern = minKern(in: attrs, intersecting: urlRange)
        // Visible source: the URL is readable text, not kern-collapsed.
        #expect(kern == nil || kern! >= 0)
    }

    @Test("revealOnEdit with the image inactive collapses the source (unchanged baseline)")
    func revealOnEditInactiveCollapses() {
        let text = "![cat](https://example.com/c.png)"
        let urlRange = (text as NSString).range(of: "https://example.com/c.png")
        let attrs = style(text, .revealOnEdit, active: [])
        let kern = minKern(in: attrs, intersecting: urlRange)
        #expect(kern != nil && kern! < 0)
    }
}
#endif
