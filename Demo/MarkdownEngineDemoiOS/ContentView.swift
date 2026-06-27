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

struct ContentView: View {
    var body: some View {
        MarkdownUITextViewWrapper(text: sampleMarkdown)
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
```
let answer = 42
print("hello, iOS")
```

## Blockquote
> A quoted line in the left gutter,
> continued on a second line.

## Emphasis
Some *italic*, some **bold**, and a bit of `inline code`.

---

That horizontal rule above is drawn by the fragment too.
"""
