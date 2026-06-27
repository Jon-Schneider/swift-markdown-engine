//
//  ContentView.swift
//  MarkdownEngineDemoiOS
//
//  Hosts the Phase 2a read-only iOS Markdown view (`MarkdownUITextViewWrapper`).
//  No bridge products: code blocks render with a plain background (no syntax
//  coloring), LaTeX/tables are not rendered on iOS yet (later Phase 2 passes).
//

import SwiftUI
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

    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.textInsets = TextInsets(horizontal: 16, vertical: 12)
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
            FormatBar(state: controller.selectionState) { command in
                controller.applyFormatting(command)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

/// A host-owned formatting bar driven entirely by the engine's published selection state.
private struct FormatBar: View {
    let state: MarkdownSelectionState
    let onCommand: (MarkdownFormattingCommand) -> Void

    var body: some View {
        HStack(spacing: 4) {
            button("bold", active: state.isBold) { onCommand(.bold) }
            button("italic", active: state.isItalic) { onCommand(.italic) }
            Divider().frame(height: 24)
            button("number", active: state.headingLevel == 1) { onCommand(.heading(1)) }
            button("textformat.size.smaller", active: state.headingLevel == 2) { onCommand(.heading(2)) }
            Divider().frame(height: 24)
            button("list.bullet", active: state.isBulletList) { onCommand(.bulletList) }
            button("list.number", active: state.isNumberedList) { onCommand(.numberedList) }
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

## Blockquote
> A quoted line in the left gutter,
> continued on a second line.

## Emphasis
Some *italic*, some **bold**, and a bit of `inline code`.

---

That horizontal rule above is drawn by the fragment too.
"""
