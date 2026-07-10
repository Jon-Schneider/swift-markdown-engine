# Changelog

All notable changes to swift-markdown-engine are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (attachment drop & paste)
- First-class image/file **drop** support so a native drop can no longer corrupt the
  Markdown source. A rich `NSTextView`/`UITextView` otherwise performs its own drop,
  splicing an `NSTextAttachment` (U+FFFC) or file-path text into the backing store —
  which round-trips to storage. The editor now intercepts image/file drops on the text
  view itself (a host-level SwiftUI `.onDrop` can't win — the text view is the frontmost
  registered destination) and routes each item to a new host hook:
  - `NativeTextViewWrapper(onDropAttachment:)` / `MarkdownUITextViewWrapper(onDropAttachment:)`,
    called with a `DroppedItem` (pre-read `data` with a main-thread size guard, plus
    `fileURL` for the large / security-scoped case, `suggestedName`, `isImage`, `type`).
  - The host returns an `AttachmentDisposition`; the engine wraps the returned reference
    as `![](ref)` (image) or `[name](ref)` (other file). With no hook set, attachment
    drops are neutralized (nothing inserted) so the source is never corrupted. Dropped
    plain text still inserts as text, and intra-editor text drag-to-move is preserved.
  - Platform divergence: on macOS an image drop is padded onto its own line (block embed);
    on iOS it inserts an inline `![](ref)` at the drop point (the `UITextPasteDelegate`
    transform exposes no drop offset for the own-line math). On iOS the `DroppedItem` always
    carries a `fileURL` (files are copied to a temp location); on macOS `fileURL` is the
    original dropped URL. In both cases `data` is pre-read only up to a 20 MB guard.

### Changed (breaking: paste hook return type & payload)
- `onPasteImage` now returns `AttachmentDisposition` instead of `String?`. The old `nil`
  conflated "I handled it, insert nothing" with "I decline, do your default" — the
  ambiguity behind a paste double-insert. Migrate the return value:
  - `nil` → `.declined` (falls through to the default text paste).
  - a reference/embed string → `.insert(ref)` — **but note the payload also changed**: the
    engine now wraps the returned value as `![](ref)`, so pass the bare storage reference.
    On **macOS** the old hook inserted the returned string *verbatim* (you returned a full
    `![](…)` / `![[…]]` embed); returning that same full string now yields `![](![[…]])`.
    Return just the reference. (iOS already returned a bare reference, so iOS callers only
    change the enum wrapper.)
  - `.consumed` — new: you're staging bytes asynchronously; inserts nothing AND does not
    fall through to the default text paste (this is the paste double-insert fix).
  - `.insert("")` is treated as `.consumed` (never inserts an empty `![]()`).
- macOS `onPasteImage` is now gated on `PasteboardImageReader.canPasteImage` (matching iOS
  `hasImages`), so it fires only for image pastes rather than every paste. A host that used
  it to intercept non-image pastes must move that logic elsewhere.

### Fixed (attachment drop & paste)
- Native drag-and-drop of an image/file onto the editor corrupted the stored Markdown
  (silent U+FFFC / stray file path that persisted and synced). Drops are now intercepted
  and routed to `onDropAttachment` (see above); no corruption regardless of whether a
  hook is set.
- A synchronous `onPasteImage` had no way to say "consumed, insert nothing", so a source
  carrying both image bytes and a URL string (e.g. a browser "Copy Image") double-inserted
  by falling through to the string flavor. `.consumed` now stops that fall-through.

### Added
- Broadened per-element styling configuration for an Apple Notes-grade look, all
  backward-compatible (defaults reproduce previous rendering):
  - Checkboxes: `CheckboxStyle.uncheckedSymbolName` / `checkedSymbolName`;
    `Theme.checkboxCheckedTint` / `checkboxUncheckedTint` / `completedTaskText`
    (dims completed items).
  - Headings: `HeadingStyle.fontWeights` (per level) and optional
    `bottomSpacingEm` (dedicated bottom spacing).
  - Inline code: `InlineCodeStyle.cornerRadius` / `horizontalPadding` (drawn
    rounded pill) and `Theme.inlineCodeText`.
  - Code blocks: `CodeBlockStyle.cornerRadius` / `backgroundHorizontalInset`.
  - Ordered lists: `Theme.orderedListNumberColor` and
    `ListStyle.orderedNumberWeight`.
  - Body: `ParagraphStyle.lineSpacing`.
  - Links: `LinkStyle.underlinesResolvedLinks`.
  - Images: `ImageEmbedStyle.cornerRadius`.
  - Added `PlatformFont.withWeightCompat` and a cross-platform rounded-rect path
    helper to support the above.
  - Known limitation (macOS): the SwiftUI wrapper reads the full configuration
    only at mount. Changing a styling knob or theme color *after* mount has no
    effect until the editor is reconstructed — not even on a subsequent edit,
    because the coordinator keeps its mount-time configuration and restyling
    reads that stale copy (a pre-existing macOS-wide behavior — theme colors
    already behaved this way; only a few fields such as `heightBehavior`,
    marker visibility, and services are re-synced live). iOS live-updates via
    `reapplyConfiguration`. Set styling config when constructing the editor.
    Live macOS reconfiguration is a tracked follow-up.

### Fixed
- `CheckboxStyle.sizeFromFontHeightFactor` / `sizeFromMarkerWidthFactor` /
  `iconInsetFraction` and `InlineCodeStyle.fontSizeScale` were declared but
  ignored by the render path; they now take effect (defaults unchanged).
  Note: inline code is now sized by `InlineCodeStyle.fontSizeScale` rather than
  incidentally tracking `CodeBlockStyle.fontSizeScale`. The `.default` look is
  byte-identical (both are `0.85`), but a consumer who set
  `codeBlock.fontSizeScale` and left `inlineCode` at its default will now see
  inline code at the inline default instead of the code-block value.
- `HeadingStyle.fontWeights` / `ListStyle.orderedNumberWeight` had no effect on
  *named* fonts (including the engine's default "SF Pro") — the weight trait was
  added to a descriptor already pinned to a specific PostScript face, which
  CoreText will not re-weight, so headings silently rendered regular instead of
  the requested weight. `PlatformFont.withWeightCompat` now re-keys on the font
  family so the weighted face is actually selected.
- `LinkStyle.underlinesResolvedLinks = false` did not remove the underline on
  macOS (`NSTextView` re-underlines `.link` ranges via its `linkTextAttributes`).
  The view now derives `linkTextAttributes` from the config — the theme link
  color plus a conditional underline — so the toggle governs Markdown links,
  auto-detected URLs, and resolved wiki-links uniformly. (This also fixes a
  regression in an interim build where auto-links/wiki-links, which carry only
  `.link`, briefly lost their color/underline; the default `.linkColor` look is
  unchanged.)
- `ImageEmbedStyle.cornerRadius` also rounded (and clipped) table and block-LaTeX
  images, which share the image draw path; it now applies only to genuine image
  embeds. Inline-code pills no longer paint over the text-selection highlight,
  and oversized corner radii are clamped so short pills don't glitch on iOS.

### Added (bullets & blockquotes)
- Configurable bullet and blockquote styling, so the rendered look (e.g. an
  Apple Notes match) can be tuned without editing engine source:
  - `ListStyle.bulletGlyph` (default `•`) and `ListStyle.bulletGlyphSizeScale`
    (default `1.0`, a fraction of the line font; the glyph is optically centered
    on the text as it scales).
  - `BlockquoteStyle.indentPerLevel` (default `18`, the per-level column width
    for the bar and the text), `BlockquoteStyle.barWidth` (default `3`), and
    `BlockquoteStyle.barLeadingInset` / `textLeadingInset` (defaults `4.5` / `9`)
    which position the bar within its column and the quoted text after it, so the
    bar-to-text gap is tunable independently of the column width.
  - `MarkdownEditorTheme.bulletColor` and `MarkdownEditorTheme.blockquoteBarColor`
    (both optional; `nil` preserves the historical `bodyText` / `mutedText @ 50%`),
    resolved through `MarkdownEditorTheme.resolvedBulletColor` /
    `resolvedBlockquoteBarColor` so the fallback derivation lives in the theme.
  All defaults reproduce the previous rendering, so `.default` is unchanged. The
  previously-internal `MarkdownTextLayoutFragment.blockquoteIndentPerLevel` /
  `blockquoteBarWidth` constants were removed in favor of the config values.
- `MarkdownEditorBus.findQuery` / `findResults`: query-based in-document find. The host posts a
  search string (+ current index) and the engine matches against its OWN displayed text,
  highlighting in display coordinates and posting the match count back. This is correct where the
  displayed text differs from the source — e.g. node links rendered shorter than `[[Name|UUID]]`,
  LaTeX, or images — which the legacy `findScrollToRange` (host-computed source-coordinate ranges)
  highlighted at the wrong offset. Opt-in; `findScrollToRange` is unchanged for existing embedders.

## [0.7.1] - 2026-06-20

### Added
- `MarkdownEditorConfiguration.heightBehavior` (`.scrolls` default / `.fitsContent`):
  in `.fitsContent` the editor grows to its content height and reports it to
  SwiftUI, so an enclosing `ScrollView` scrolls the page instead of a nested
  internal scroller. Opt-in, off by default — no change for existing embedders. (#75)
- `BlockquoteStyle` configuration struct with `extraLineHeight` to control line
  spacing inside blockquotes, following the `ListStyle.extraLineHeight` /
  `ParagraphStyle.lineHeightExtraSpacing` pattern. Defaults to `0` (no extra
  spacing), preserving existing rendering. (#76)

### Fixed
- Mouse-wheel / trackball scrolling no longer clamps back at the bottom past a
  stale-small content-height measurement. (#71)
- Inspector clip mask and caret reveal at the document end. (#73)
- Scroll position is remembered per document across switches, and Writing Tools
  results stay styled and visible after accept. (#70)
- Empty-file placeholder no longer clips to one line after a view rebuild. (#69)

## [Unreleased]

### Added
- Scroll-away header: `NativeTextViewWrapper` gains `header: AnyView?`,
  `headerCollapsedHeight: CGFloat`, and `headerExpanded: Bool`. The engine
  hosts the supplied SwiftUI view above the document body, scrolling with
  it; collapsing animates the reserved band down to `headerCollapsedHeight`
  (the top row stays visible, lower rows clip away). The hosted content
  refreshes on every SwiftUI update and stays fully interactive. Composes
  with `readingWidth`. See the README's *Scrolling Header* section.

### Changed
- The scroll view's `documentView` is now always an engine-internal
  container view (hosting the text view, the optional scroll-away header,
  and the reading column's breakout overlays) rather than sometimes the
  `NSTextView` itself. Embedders that reached into
  `scrollView.documentView` expecting an `NSTextView` must adapt — the
  document view's class was never API.
- **Breaking**: The editor's enclosing scroll view no longer applies a
  hard-coded `top: 55.4` content inset. The default is now `0` on every
  edge, matching the most common embedding case where the editor fills
  its container exactly. Embedders that previously relied on the engine
  reserving header space (e.g. for a translucent toolbar) must opt in
  explicitly:

  ```swift
  var config = MarkdownEditorConfiguration.default
  config.safeAreaInsets = SafeAreaInsets(top: 55.4)
  ```

### Added
- `SafeAreaInsets` struct exposing `top` / `leading` / `trailing` / `bottom`
  inset knobs for the editor's enclosing scroll view, configurable via
  `MarkdownEditorConfiguration.safeAreaInsets`.
- `MarkdownASTStyler` now stamps `.spellingState: 0` on fenced code blocks
  and inline `` `code` `` spans, completing the engine's existing
  spell-check suppression convention (links, wiki-links, LaTeX, and tables
  already carry the same attribute). The system spell-checker no longer
  underlines tokens inside code regions even when continuous spell
  checking is enabled.

### Fixed
- Undo is now kept per `documentId`, so Cmd+Z keeps working after switching
  files. The single reused `NSTextView` previously wiped its undo manager on
  every document switch; the editor now vends a per-document `UndoManager`
  (via the new `undoManager(for:)` delegate method) whose undo/redo stack
  survives switching away and back. (#77)
- A document's surviving undo stack is dropped when its text is reloaded
  *changed* while it was switched away (e.g. renaming a node rewrites the
  `[[label]]` in every file that links it), so Cmd+Z can no longer replay
  stale ranges against the rewritten content.
- `NativeTextViewWrapper` keeps links clickable and text selectable
  when `isEditable: false`; `isSelectable` is no longer coupled to
  `isEditable`. (#31)
- `NativeTextViewWrapper` now applies its initial styling pass even when
  the bound text starts at its final value (e.g. supplied as a SwiftUI
  `@State` initializer). Previously the editor would render the raw
  Markdown source until the user clicked into the document, because the
  coordinator's `lastSyncedText` already matched the bound text at first
  `updateNSView`. The early-return now also requires `didInitialFormatting`
  to be true, which only flips after the first styling pass completes.

### Added
- Initial public API surface:
  - `NativeTextViewWrapper` — SwiftUI bridge for the AppKit-backed editor
  - `MarkdownEditorConfiguration` — every spacing / sizing / behavior knob
  - `MarkdownEditorTheme` — color palette, defaults to system colors
  - `MarkdownEditorServices` — container for the four service protocols
  - Service protocols: `WikiLinkResolver`, `EmbeddedImageProvider`,
    `SyntaxHighlighter`, `LatexRenderer`
  - No-op default implementations: `NoOpWikiLinkResolver`,
    `NoOpEmbeddedImageProvider`, `PlainTextSyntaxHighlighter`,
    `NoOpLatexRenderer`
  - `WikiLinkService` — bidirectional storage / display roundtrip helper
  - `PasteboardImageReader` — pasteboard image inspection helpers
  - Selection / replacement value types: `WikiLinkSelection`,
    `InlineSelectionState`, `InlineReplacementRequest`, `CodeBlockSelection`
  - `CodeBlockButton` — drop-in copy button overlay
- DocC documentation catalog with landing page and topic groups
- Triple-slash documentation comments on the full public API surface

[Unreleased]: https://github.com/nodes-app/swift-markdown-engine/compare/0.7.1...HEAD
[0.7.1]: https://github.com/nodes-app/swift-markdown-engine/compare/0.7.0...0.7.1
