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
