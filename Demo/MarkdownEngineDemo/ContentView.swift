//
//  ContentView.swift
//  MarkdownEngine
//
//  Created by Nicolas von Mallinckrodt on 29.04.26.
//

import SwiftUI
import AppKit
import MarkdownEngine

// Optional bridge products. Each is independent — drop either of these
// `#if` blocks (or remove the matching Swift Package product dependency
// from the Xcode project) and the demo still compiles. Code blocks fall
// back to plain monospace; LaTeX falls back to its raw `$…$` source.
#if canImport(MarkdownEngineCodeBlocks)
import MarkdownEngineCodeBlocks
#endif
#if canImport(MarkdownEngineLatex)
import MarkdownEngineLatex
#endif

struct ContentView: View {
    @State private var text: String = sampleMarkdown
    @StateObject private var controller = MarkdownEditorController()
    @State private var showHeader = false
    @State private var headerExpanded = true
    /// Seamless-editing mode. Switching this at runtime restyles immediately —
    /// `.seamless` hides every Markdown marker (true WYSIWYG); `.revealAll` is
    /// the "show raw Markdown" escape hatch.
    @State private var markerVisibility: MarkerVisibility = .revealOnEdit
    /// In seamless mode, whether Backspace at content start unwraps the whole
    /// hidden marker (on) or does a plain native delete (off).
    @State private var backspaceUnwrap = true

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            header: showHeader ? AnyView(demoHeader) : nil,
            headerCollapsedHeight: 40,
            headerExpanded: headerExpanded
        )
        .controller(controller)
        // Slash-command menu: the engine publishes `slashMenuContext` when the caret sits in a
        // `/command`; the host renders the menu anchored at the caret and applies a choice.
        .overlay(alignment: .topLeading) {
            if let context = controller.slashMenuContext {
                SlashMenuOverlay(context: context) { block in
                    // Bind the edit to the range the *visible* menu was built from.
                    controller.insertBlock(block, replacing: context.sourceRange)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                // Markers: live switch between the historical reveal-on-edit
                // surface, the always-hidden seamless surface, and the raw
                // "reveal everything" escape hatch.
                Picker("Markers", selection: $markerVisibility) {
                    Text("Reveal on edit").tag(MarkerVisibility.revealOnEdit)
                    Text("Seamless").tag(MarkerVisibility.seamless)
                    Text("Reveal raw").tag(MarkerVisibility.revealAll)
                }
                .pickerStyle(.segmented)

                // Seamless-only: Backspace-to-unwrap vs. plain native delete.
                Toggle("Backspace unwraps", isOn: $backspaceUnwrap)
                    .disabled(markerVisibility != .seamless)

                // Scroll-away header: an embedder-supplied SwiftUI view hosted
                // above the body that scrolls with it. "Expanded" animates
                // between the full content height and `headerCollapsedHeight`
                // (the top row stays visible; the rows below clip away).
                Toggle("Header", isOn: $showHeader)
                Toggle("Expanded", isOn: $headerExpanded)
                    .disabled(!showHeader)
            }
        }
    }

    /// Sample scroll-away header: a fixed top row (kept visible when collapsed)
    /// plus detail rows that reveal/hide with the `headerExpanded` toggle.
    private var demoHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scroll-away header").font(.headline)
                Spacer()
            }
            .frame(height: 40)   // == headerCollapsedHeight: the always-visible row

            VStack(alignment: .leading, spacing: 6) {
                Text("These rows clip away when the header collapses.")
                Text("The header scrolls with the document body and stays fully interactive.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
    }

    /// The engine talks to your app through service protocols. Two of them —
    /// `SyntaxHighlighter` and `LatexRenderer` — render the code-block and
    /// LaTeX visuals. The base `MarkdownEngine` ships no-op defaults
    /// (plain monospace, raw `$…$`); the optional `MarkdownEngineCodeBlocks`
    /// and `MarkdownEngineLatex` products ship ready-made bridges backed by
    /// HighlighterSwift and SwiftMath respectively.
    ///
    /// This demo opportunistically plugs in whichever bridges are linked,
    /// so you can see exactly what each one adds.
    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.markers.visibility = markerVisibility
        config.markers.seamlessBackspaceUnwrap = backspaceUnwrap

        // Resolve `![alt](url)` to a generated swatch so the sample's image
        // renders (the default provider returns nil). Lets you see seamless's
        // atomic image treatment: the image stays rendered, the raw source
        // never appears, the caret skips it, and Backspace deletes it whole.
        config.services.images = DemoImageProvider()

        #if canImport(MarkdownEngineCodeBlocks)
        // Syntax highlighting for fenced code blocks. Auto-switches between
        // `atom-one-light` and `atom-one-dark` with system appearance.
        config.services.syntaxHighlighter = HighlighterSwiftBridge()
        #endif

        #if canImport(MarkdownEngineLatex)
        // LaTeX rendering for `$inline$` and `$$block$$` math. Uses the
        // Latin Modern math font and tints formulas to match the theme.
        config.services.latex = SwiftMathBridge()
        #endif

        return config
    }
}

/// The `/` block-insert menu — a floating card anchored at the caret. Driven entirely by the
/// engine's published `SlashMenuContext` (query + caret rect): the host owns presentation, the
/// engine owns detection and the edit. On macOS the context's `anchorRect` is already in the
/// wrapper's local (scroll) space, so it maps straight into this overlay — no `.global` mapping.
///
/// Dismissal is driven by the engine's caret/text changes (typing past the `/`, moving the caret,
/// or picking a block). A demo gap: it does NOT dismiss on focus loss to non-editor chrome (no
/// Escape / resign-first-responder hook) — a real host would add one once verified not to race the
/// row click. Rows are click-only (parity with iOS).
private struct SlashMenuOverlay: View {
    let context: SlashMenuContext
    let onSelect: (MarkdownBlockInsert) -> Void

    private static let cardWidth: CGFloat = 260
    private static let rowHeight: CGFloat = 30
    private static let maxVisibleRows = 8
    private static let gap: CGFloat = 4
    private static let margin: CGFloat = 8
    private static let verticalPadding: CGFloat = 6

    private var items: [MarkdownSlashMenuItem] {
        MarkdownSlashMenu.items(matching: context.query)
    }

    private var listHeight: CGFloat {
        CGFloat(min(max(items.count, 1), Self.maxVisibleRows)) * Self.rowHeight
    }

    private var cardHeight: CGFloat { listHeight + 2 * Self.verticalPadding }

    var body: some View {
        GeometryReader { proxy in
            let caret = context.anchorRect
            let cardWidth = min(Self.cardWidth, max(120, proxy.size.width - 2 * Self.margin))
            // No keyboard occlusion on macOS — default below the caret, flip above only when the
            // card would overflow the bottom edge.
            let belowY = caret.maxY + Self.gap
            let aboveY = caret.minY - Self.gap - cardHeight
            let fitsBelow = belowY + cardHeight <= proxy.size.height
            let y = fitsBelow ? belowY : max(0, aboveY)
            let x = min(max(0, caret.minX), max(0, proxy.size.width - cardWidth))

            card
                .frame(width: cardWidth)
                .offset(x: x, y: y)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("No matching blocks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: Self.rowHeight, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                }
                .frame(height: listHeight)
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(radius: 10, y: 3)
    }

    // Click-only (parity with iOS): no row carries a "selected" highlight, which would imply
    // keyboard nav the demo doesn't wire up.
    private func row(_ item: MarkdownSlashMenuItem) -> some View {
        Button {
            onSelect(item.block)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(Color.accentColor)
                Text(item.title)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Builds the demo markdown shown when the editor first loads.
///
/// The text is composed from a fixed header/footer plus three feature
/// sections — inline formatting, block math, and code — that swap between
/// a full showcase and a short "feature unavailable" note depending on
/// which optional bridge products are linked.
///
/// When a bridge is missing, the fallback links to the README section
/// that explains how to enable that feature in your own app.
private var sampleMarkdown: String {
    [
        markdownHeader,
        inlineFormattingSection,
        latexSection,
        codeSection,
        imageSection,
        markdownFooter,
    ].joined(separator: "\n\n")
}

private let markdownHeader = """
# MarkdownEngine

A native macOS Markdown editor built on **TextKit 2**, bridged to SwiftUI — brought to you by [nodes-web.com](https://nodes-web.com).

Edit this text live. Formatting updates as you type.

---
"""

/// Inline formatting demo. Drops the inline-LaTeX example sentence when
/// the LaTeX bridge isn't linked, so the reader doesn't see raw `$…$`.
private var inlineFormattingSection: String {
    #if canImport(MarkdownEngineLatex)
    return #"""
    ## Inline formatting

    Mix **bold**, *italic*, and ***both at once***. Reach for `inline code` when a short snippet helps. Inline math fits naturally in prose — the Pythagorean identity says $a^2 + b^2 = c^2$, and Euler's identity famously claims $e^{i\pi} + 1 = 0$.
    """#
    #else
    return """
    ## Inline formatting

    Mix **bold**, *italic*, and ***both at once***. Reach for `inline code` when a short snippet helps.
    """
    #endif
}

/// Block LaTeX demo when the `MarkdownEngineLatex` bridge is linked;
/// otherwise a short note pointing to the README section that explains
/// how to enable LaTeX rendering.
private var latexSection: String {
    #if canImport(MarkdownEngineLatex)
    return #"""
    ## Block math

    $$
    \int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
    $$

    $$
    \frac{\partial}{\partial t}\Psi(\mathbf{r}, t) = -\frac{i}{\hbar}\hat{H}\,\Psi(\mathbf{r}, t)
    $$
    """#
    #else
    return """
    ## LaTeX

    LaTeX (`$inline$` and `$$block$$`) is parsed but not rendered without the optional `MarkdownEngineLatex` product. See [LaTeX Rendering](https://github.com/nodes-app/swift-markdown-engine#latex-rendering) in the README to wire it up.
    """
    #endif
}

/// Fenced code-block demo when the `MarkdownEngineCodeBlocks` bridge is
/// linked; otherwise a plain monospace example and a link to the
/// README's Code Blocks section.
private var codeSection: String {
    #if canImport(MarkdownEngineCodeBlocks)
    return #"""
    ## Code

    Swift, with syntax highlighting:

    ```swift
    import SwiftUI
    import MarkdownEngine

    struct Editor: View {
        @State private var text = "# Hello"

        var body: some View {
            NativeTextViewWrapper(text: $text)
                .frame(minWidth: 640, minHeight: 480)
        }
    }
    ```

    And a little JSON:

    ```json
    {
      "engine": "MarkdownEngine",
      "features": ["latex", "code", "wiki-links"],
      "version": 1.0
    }
    ```
    """#
    #else
    return #"""
    ## Code

    Fenced code blocks render as plain monospace without the optional `MarkdownEngineCodeBlocks` product. See [Code Blocks](https://github.com/nodes-app/swift-markdown-engine#code-blocks) in the README for syntax-highlighted output:

    ```swift
    let greeting = "Hello, world!"
    ```
    """#
    #endif
}

/// Standalone-image demo. The `DemoImageProvider` resolves the URL to a
/// generated swatch; in seamless mode the image is one atomic unit.
private let imageSection = """
## Image

A standalone image renders inline; in seamless mode the `![alt](url)` source is hidden and the image is treated as one atomic unit.

![A sample image](demo://card)
"""

private let markdownFooter = """
---

Built by [nodes-web.com](https://nodes-web.com).
"""

/// Resolves any `![alt](url)` to a generated gradient swatch so the demo can
/// show real image rendering without bundling assets or hitting the network.
/// A concrete named type (not a closure) per the engine's injection style.
private struct DemoImageProvider: EmbeddedImageProvider {
    func image(for reference: EmbeddedImageRequest) -> PlatformImage? {
        let size = NSSize(width: 240, height: 140)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [.systemIndigo, .systemTeal])?
                .draw(in: rect, angle: -45)
            let label = "🖼 demo image" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 20),
                .foregroundColor: NSColor.white,
            ]
            let textSize = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                                   y: (rect.height - textSize.height) / 2),
                       withAttributes: attrs)
            return true
        }
    }

    func fingerprint() -> AnyHashable { "demo-image-v1" }
}
