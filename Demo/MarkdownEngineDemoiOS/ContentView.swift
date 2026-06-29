//
//  ContentView.swift
//  MarkdownEngineDemoiOS
//
//  Hosts the Phase 2a read-only iOS Markdown view (`MarkdownUITextViewWrapper`).
//  No bridge products: code blocks render with a plain background (no syntax
//  coloring), LaTeX/tables are not rendered on iOS yet (later Phase 2 passes).
//

import SwiftUI
import UIKit
import MarkdownEngine
#if canImport(MarkdownEngineCodeBlocks)
import MarkdownEngineCodeBlocks
#endif
#if canImport(MarkdownEngineLatex)
import MarkdownEngineLatex
#endif

struct ContentView: View {
    @State private var text = sampleMarkdown
    @StateObject private var controller = MarkdownEditorController()
    /// Seamless-editing mode (live toggle). `.seamless` hides every Markdown
    /// marker; `.revealAll` is the "show raw Markdown" escape hatch.
    @State private var markerVisibility: MarkerVisibility = .revealOnEdit
    /// In seamless mode, whether Backspace at content start unwraps the whole
    /// hidden marker (on) or does a plain native delete (off).
    @State private var backspaceUnwrap = true

    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.textInsets = TextInsets(horizontal: 16, vertical: 12)
        config.markers.visibility = markerVisibility
        config.markers.seamlessBackspaceUnwrap = backspaceUnwrap
        // Resolve `![alt](url)` to a generated swatch so the sample's image
        // renders (the default provider returns nil). Lets you see seamless's
        // atomic image treatment: the image stays rendered, the raw source
        // never appears, the caret skips it, and Backspace deletes it whole.
        config.services.images = DemoImageProvider()
        #if canImport(MarkdownEngineCodeBlocks)
        config.services.syntaxHighlighter = HighlighterSwiftBridge()
        #endif
        #if canImport(MarkdownEngineLatex)
        config.services.latex = SwiftMathBridge()
        #endif
        return config
    }

    var body: some View {
        VStack(spacing: 0) {
            // Live seamless-mode switch (reveal-on-edit / seamless / reveal raw).
            Picker("Markers", selection: $markerVisibility) {
                Text("Reveal on edit").tag(MarkerVisibility.revealOnEdit)
                Text("Seamless").tag(MarkerVisibility.seamless)
                Text("Reveal raw").tag(MarkerVisibility.revealAll)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Seamless-only: Backspace-to-unwrap vs. plain native delete.
            if markerVisibility == .seamless {
                Toggle("Backspace unwraps markers", isOn: $backspaceUnwrap)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            MarkdownUITextViewWrapper(
                text: text,
                configuration: configuration,
                onTextChange: { edited in
                    text = edited   // write-back: edits round-trip into the model
                },
                onPasteImage: { data in
                    // Host owns storage: save the pasted bytes and return a reference the
                    // editor inserts as ![](path).
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("pasted-\(UUID().uuidString).png")
                    try? data.write(to: url)
                    return url.path
                }
            )
            .controller(controller)

            // Host-built formatting toolbar: its buttons reflect the cursor context
            // (controller.selectionState) and issue commands back to the editor.
            FormatBar(
                state: controller.selectionState,
                inLink: controller.inlineLinkContext != nil,
                onCommand: { controller.applyFormatting($0) },
                onFind: { controller.presentFind(showingReplace: true) },
                onLink: {
                    // A real host would show a text/URL editor here; the demo inserts a sample.
                    if controller.inlineLinkContext != nil {
                        controller.updateLinkAtCaret(text: "edited", url: "https://edited.example.com")
                    } else {
                        controller.insertLink(text: "example", url: "https://example.com")
                    }
                }
            )
        }
        .ignoresSafeArea(edges: .bottom)
        // Slash-command menu: the engine publishes `slashMenuContext` when the caret sits in a
        // `/command`; the host renders the menu, anchored at the caret, and applies a choice.
        .overlay(alignment: .topLeading) {
            if let context = controller.slashMenuContext {
                SlashMenuOverlay(context: context) { block in
                    // Bind the edit to the range the *visible* menu was built from, not whatever
                    // the engine has republished since (defensive against a re-publish race).
                    controller.insertBlock(block, replacing: context.sourceRange)
                }
            }
        }
    }
}

/// The `/` block-insert menu — a floating card anchored at the caret. Driven entirely by the
/// engine's published `SlashMenuContext` (query + caret rect): the host owns presentation, the
/// engine owns detection and the edit. A `GeometryReader` maps the context's window-space caret
/// rect into this overlay's local space and clamps the card on-screen.
private struct SlashMenuOverlay: View {
    let context: SlashMenuContext
    let onSelect: (MarkdownBlockInsert) -> Void

    private static let cardWidth: CGFloat = 260
    private static let rowHeight: CGFloat = 44
    private static let maxVisibleRows = 6
    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8

    private var items: [MarkdownSlashMenuItem] {
        MarkdownSlashMenu.items(matching: context.query)
    }

    private var cardHeight: CGFloat {
        CGFloat(min(max(items.count, 1), Self.maxVisibleRows)) * Self.rowHeight
    }

    var body: some View {
        GeometryReader { proxy in
            // The overlay's own origin in window space; subtract it to convert the caret rect
            // (window coords) into this container's local coordinates.
            let containerOrigin = proxy.frame(in: .global).origin
            let caret = context.anchorRect
            // Clamp to the container so the card can't overflow a narrow Slide-Over / split width.
            let cardWidth = min(Self.cardWidth, max(120, proxy.size.width - 2 * Self.margin))

            // Prefer ABOVE the caret. The software keyboard always sits below the caret (the text
            // view keeps the caret just above it), and keyboard avoidance is the text view's own
            // `contentInset` — SwiftUI never shrinks this overlay for the keyboard, so a downward
            // menu would render *under* it. Fall back to below only when there's no room above
            // (caret near the very top of the screen, where the keyboard isn't).
            let aboveY = caret.minY - containerOrigin.y - Self.gap - cardHeight
            let belowY = caret.maxY - containerOrigin.y + Self.gap
            let y = aboveY >= 0 ? aboveY : belowY

            // Left-align to the caret, clamped within the container's width.
            let rawX = caret.minX - containerOrigin.x
            let x = min(max(0, rawX), max(0, proxy.size.width - cardWidth))

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
                .frame(height: cardHeight)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(uiColor: .separator)))
        .shadow(radius: 12, y: 4)
    }

    // Tap-only on iOS (no arrow/Return nav until `onKeyPress`, iOS 17+), so rows carry no
    // "selected" highlight — that would imply a keyboard affordance that doesn't exist here.
    private func row(_ item: MarkdownSlashMenuItem) -> some View {
        Button {
            onSelect(item.block)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .frame(width: 24)
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

/// A host-owned formatting bar driven entirely by the engine's published selection state.
private struct FormatBar: View {
    let state: MarkdownSelectionState
    let inLink: Bool
    let onCommand: (MarkdownFormattingCommand) -> Void
    let onFind: () -> Void
    let onLink: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            button("bold", active: state.isBold) { onCommand(.bold) }
            button("italic", active: state.isItalic) { onCommand(.italic) }
            button("strikethrough", active: state.isStrikethrough) { onCommand(.strikethrough) }
            button("chevron.left.forwardslash.chevron.right", active: state.isInlineCode) { onCommand(.inlineCode) }
            button("textformat.size", active: false) { onCommand(.clearFormatting) }
            Divider().frame(height: 24)
            button("number", active: state.headingLevel == 1) { onCommand(.heading(1)) }
            button("textformat.size.smaller", active: state.headingLevel == 2) { onCommand(.heading(2)) }
            Divider().frame(height: 24)
            button("list.bullet", active: state.isBulletList) { onCommand(.bulletList) }
            button("list.number", active: state.isNumberedList) { onCommand(.numberedList) }
            button("checkmark.square", active: state.isChecked) { onCommand(.toggleCheckbox) }
            button("increase.indent", active: false) { onCommand(.indent) }
            button("decrease.indent", active: false) { onCommand(.outdent) }
            Divider().frame(height: 24)
            button("text.quote", active: state.isBlockquote) { onCommand(.blockquote) }
            button("curlybraces", active: state.isCodeBlock) { onCommand(.codeBlock) }
            Divider().frame(height: 24)
            button("magnifyingglass", active: false, action: onFind)
            button("link", active: inLink, action: onLink)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func button(_ systemName: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 36, height: 32)
                .background(active ? Color.accentColor.opacity(0.25) : .clear)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private let sampleMarkdown = """
# MarkdownEngine on iOS

An **editable** Markdown view on the cross-platform TextKit-2 fragment. Tap to type — lists continue, checkboxes toggle, and edits write back to the model.

## Lists & checkboxes
- First bullet
- Second bullet
  - Nested bullet
- [ ] An unchecked task
- [x] A completed task

## Code block
```swift
let answer = 42
func greet(_ name: String) -> String {
    return "hello, \\(name)"
}
print(greet("iOS"))
```

## Image
A standalone image renders inline; in seamless mode the `![alt](url)` source is hidden and the image is treated as one atomic unit.

![A sample image](demo://card)

## Math (LaTeX)
Inline math like $E = mc^2$ flows with the text, and block math centers:

$$\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}$$

## Tables
A narrow table fits the column; a wide one scrolls horizontally.

| Feature   | Status | Notes            |
|-----------|:------:|------------------|
| Lists     |   ✓    | continue on ⏎    |
| Checkboxes|   ✓    | tap to toggle    |
| **Tables**|   ✓    | rendered as $E=mc^2$ |

| Platform | Renderer | Min OS | Highlighting | LaTeX | Tables | Horizontal scroll | Notes |
|----------|----------|:------:|:------------:|:-----:|:------:|:-----------------:|-------|
| macOS    | TextKit 2 (AppKit) | 13 | HighlighterSwift | SwiftMath | ✓ | NSScrollView overlay | the original surface |
| iOS      | TextKit 2 (UIKit) | 16 | HighlighterSwift | SwiftMath | ✓ | UIScrollView overlay | this port — **swipe the wide table sideways** |

## Links
A [markdown link](https://apple.com) renders as styled text; tap the link button while the caret is inside it.

## Blockquote
> A quoted line in the left gutter,
> continued on a second line.

## Emphasis
Some *italic*, some **bold**, and a bit of `inline code`.

---

That horizontal rule above is drawn by the fragment too.
"""

/// Resolves any `![alt](url)` to a generated gradient swatch so the demo can
/// show real image rendering without bundling assets or hitting the network.
/// A concrete named type (not a closure) per the engine's injection style.
private struct DemoImageProvider: EmbeddedImageProvider {
    func image(for reference: EmbeddedImageRequest) -> PlatformImage? {
        let size = CGSize(width: 240, height: 140)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero,
                                      end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let label = "🖼 demo image" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 20),
                .foregroundColor: UIColor.white,
            ]
            let textSize = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                   y: (size.height - textSize.height) / 2),
                       withAttributes: attrs)
        }
    }

    func fingerprint() -> AnyHashable { "demo-image-v1" }
}
