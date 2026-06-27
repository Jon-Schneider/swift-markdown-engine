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
        MarkdownUITextViewWrapper(text: sampleMarkdown, configuration: configuration)
            .ignoresSafeArea(edges: .bottom)
    }
}

private let sampleMarkdown = """
# MarkdownEngine on iOS

A **read-only** render through the cross-platform TextKit-2 fragment ported in Phase 1.

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

## Blockquote
> A quoted line in the left gutter,
> continued on a second line.

## Emphasis
Some *italic*, some **bold**, and a bit of `inline code`.

---

That horizontal rule above is drawn by the fragment too.
"""
