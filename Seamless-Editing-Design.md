# True Seamless (WYSIWYG) Editing — Design Understanding

> Status: **design / alignment doc** (no implementation). Captures my understanding of the
> goal and the changes required, so we agree on scope before building. Please correct
> anything that doesn't match your intent.

## 1. What you're looking for (the goal)

A **rendered editing mode where the user never sees raw Markdown syntax**. You type a
Markdown shortcut (or tap a button) and the element simply *appears* — and the syntax
characters are **gone for good**, even while you're editing that element.

- Type `> ` → the blockquote gutter bar appears and the `> ` is **not there at all**.
- Type `# ` → a heading; the `#` is gone.
- Type `- ` → a bullet; the `- ` is gone.
- Same idea for `**bold**`, `*italic*`, `~~strike~~`, `` `code` ``, `[links](…)`, tables, etc.

The key phrase from you: *"`>` is only shown on the line the caret is on, but for a seamless
experience it should not be there at all."* — i.e. **no reveal-on-edit**; markers stay hidden
**always**.

Markdown stays the **storage / serialization format** under the hood. It is simply never the
*editing surface*.

## 2. Where we are today (current behavior)

The editor is already a **"live preview" hybrid**, not a raw-Markdown editor:

- Markers are **hidden by default** and the element is rendered (bar, heading size, bold, …).
- Markers are **revealed only when the caret is on that element** so you can edit the raw
  Markdown — then re-hidden when the caret leaves.

That reveal-on-edit is the *one thing* standing between today's editor and "seamless." Concretely,
in `MarkdownASTStyler` every element does some variant of:

```swift
if ctx.isActive(tokenRange) {          // caret on the element → show the marker (muted)
    attrs.append((markerRange, [.foregroundColor: ctx.theme.mutedText]))
} else {                               // else → hide it (clear color, tiny font)
    attrs.append((markerRange, [.foregroundColor: .clear, .font: ctx.inlineMarkerFont]))
}
```

(See `styleBlockquote`, and the parallel active/inactive branches for headings, emphasis,
strikethrough, inline code, list markers, thematic breaks, and link brackets.)

So the machinery to hide a marker **already exists** — seamless mode is mostly "always take the
hidden branch," plus the hard caret/deletion work below.

## 3. The guiding principle

**Keep the Markdown in the text buffer; just hide the syntax characters permanently.**

Do **not** move to a block/rich-text model where markers are removed from the buffer. That is a
different editor architecture and would break selection math, undo, find, and the whole
parse→style pipeline (all of which operate on the Markdown string today). Instead, the buffer
still literally contains `> Hello` / `# Title` / `**bold**`; the user just never sees the
`>` / `#` / `**`. This keeps parsing, serialization, undo, and find working unchanged.

## 4. The hard part (why this is a project, not a config flag)

Rendering the markers as always-hidden is the easy ~20%. The hard ~80% is **caret, selection,
and deletion behavior over now-invisible characters** — this is where every "hide Markdown"
editor (iA Writer, Obsidian Live Preview, Typora, Bear) lives or dies:

1. **Caret positioning.** Where does the caret sit relative to a zero-width `>`? What do Home /
   End / arrow keys do at the start of a quoted/heading line?
2. **Smart deletion (unwrap).** Backspace at the *start of the content* must remove the **entire
   hidden marker** (unwrap the element: `> ` / `# ` / `- ` / `**…**`) as one action — not nibble
   invisible characters one at a time, which feels broken ("I pressed backspace and nothing
   happened").
3. **Typing at boundaries.** Typing at line start must land *after* the hidden marker (into the
   content), not before it.
4. **Selection & copy/paste.** Selecting across an element boundary; and a decision: does copying
   a blockquote line yield `> text` (Markdown, round-trips on paste) or `text` (what's visible)?
5. **Click hit-testing.** Clicking near the line start lands the caret in the right place despite
   the invisible marker occupying that position.

This is the bulk of the work and the part that determines whether it *feels* native.

## 5. Changes needed (technical)

### 5.1 One seamless-mode switch (not per-element flags)
A single cross-platform config, e.g. `markerVisibility: .revealOnEdit (today) | .alwaysHidden
(seamless)`, applied uniformly to **all** markers. Per-element flags (the `alwaysHidesMarker`
spike we reverted) are rejected — they produce an inconsistent editor and dodge the caret work.

### 5.2 Styler: always take the hidden branch
In `MarkdownASTStyler`, gate every `ctx.isActive(...)` marker-reveal on the mode: in seamless
mode, always hide. Markers to cover: blockquote `>`, heading `#`, emphasis `**`/`*`,
strikethrough `~~`, inline code `` ` ``, list markers `- `/`* `/`+ `/`1. `, code fences ```` ``` ````,
link/image brackets, table pipes.

**Make hidden markers truly zero-width.** Some hidden markers today use `clear color + tiny font`
(which still has a small advance), others use `.kern: -font.pointSize` to collapse width. For
seamless, all hidden markers should collapse to ~zero width (the kern treatment), so layout and
caret geometry don't have invisible gaps.

### 5.3 Input handler: smart caret + deletion
This is the new, substantial piece (cross-platform, lives next to `MarkdownLists.computeListInsertion`):
- **Backspace-to-unwrap**: detect caret at the start of an element's content and delete the whole
  marker in one edit (and select/position the caret sensibly afterward).
- **Caret movement**: treat a hidden marker as atomic — arrow/Home/End skip or land consistently.
  Likely needs custom selection adjustment (and on iOS, careful `UITextInput` position handling).
- Both must be covered by unit tests like the existing `ListInsertionTests` /
  `ParagraphRestyleScopingTests`.

### 5.4 Typing shortcuts (autoformat) — partly there already
Typing `> `, `# `, `- `, etc. at line start should produce the element (the marker stays in the
buffer but is immediately hidden). The existing list-continuation / auto-pair input logic is the
foundation; extend it to blockquote and heading.

### 5.5 Decisions to lock before building
- **Copy/paste semantics**: copy yields Markdown source (recommended, round-trips) vs visible text.
- **Show-source escape hatch**: should seamless mode offer a temporary "reveal raw" toggle for
  power users, or is it fully hidden always?
- **Inline vs block scope**: inline emphasis (`**`) is the glitchiest (hiding *while typing inside*
  the span). Block-level (quote/heading/list) is much cleaner. Recommend shipping block-level
  seamless first.

### 5.6 Cross-platform
Because this is a **styler + input-handler** change (not a view change), it applies to **both**
macOS and iOS. The current macOS app ships reveal-on-edit; seamless would be the new mode (opt-in
via the config switch, so the existing macOS behavior is preserved unless enabled).

## 6. Suggested phasing
- **Phase A — block-level seamless**: blockquote, heading, lists. Always-hidden markers +
  backspace-to-unwrap + caret feel. Highest value, cleanest interaction.
- **Phase B — inline seamless**: bold / italic / strikethrough / code / links. The glitchy last mile.
- **Phase C — semantics**: copy/paste source behavior + optional show-source toggle.

## 7. Recommendation
Prototype **one element end-to-end first** (blockquote): autoformat `> ` in → always-hidden →
backspace-at-start unwraps → caret/selection feel right. That single vertical slice surfaces all
the hard caret/deletion problems in miniature, so we validate the *interaction* before committing
to covering every element on both platforms.

---

### Did I get it right?
Open questions for you:
1. **Scope** — block-level only to start, or everything (inline emphasis included) up front?
2. **Show-source toggle** — fully hidden always, or keep an escape hatch?
3. **Copy semantics** — copy the Markdown source, or the visible text?
4. **Platforms** — seamless as an opt-in mode on both macOS + iOS, or iOS-first?

---

## 8. Implementation status (built)

**Decisions taken** (answers to §7): everything (block + inline) up front · keep a
reveal-raw escape hatch · copy the **visible** text · both macOS + iOS.

**The switch.** `MarkerStyle.visibility: MarkerVisibility` with three modes:
- `.revealOnEdit` (default, unchanged historical behavior),
- `.seamless` (always hidden — the WYSIWYG surface),
- `.revealAll` (the "show raw Markdown" escape hatch).

A runtime change to this value re-syncs and restyles immediately on both platforms,
so an app can wire a toggle by flipping `configuration.markers.visibility`.

**Styler** (`MarkdownASTStyler`). Every marker-reveal decision now routes through
`Ctx.revealMarker(_:)` / `Ctx.showsDecoration(editing:)` instead of the raw
`isActive` caret check: blockquote `>`, heading `#`, list bullet/checkbox, thematic
break, code fence, inline code, emphasis, strikethrough, links, wiki links, images,
escapes. Seamless-hidden markers collapse to ~zero width (kern). Rendered blocks
(LaTeX / images / tables) never reveal their source in seamless (`MarkdownDetection
.computeActiveTokenIndices` is visibility-aware) and always reveal it in `.revealAll`.

**Input** (`MarkdownSeamlessInput`, pure + cross-platform, unit-tested):
- **Backspace-to-unwrap** — at the start of an element's content, one edit removes
  the whole hidden marker: block (`> `, `# `, unordered/checkbox `- `; ordered `1.`
  is left visible) and inline (`**…**`, `*…*`, `~~…~~`, `` `…` ``, `[t](u)`, peeling
  the innermost span first).
- **Caret normalization** — character motion stays *native* (grapheme-correct,
  no `±1` reimplementation). After the system moves a collapsed caret,
  `normalizedCaret` post-adjusts it in two cases: (a) it pulls the caret out of a
  hidden block-marker "dead zone" (so typing can't land before `> `/`# `/`- ` and
  break the block; a single ← escapes to the previous line); and (b) it pushes
  the caret across a *long atomic* hidden inline run — a link's `](url)` tail or a
  whole `![alt](url)` image — so arrowing over one doesn't freeze for N invisible
  keypresses. Short markers (`**`/`*`/`~~`/`` ` ``) are left to native motion. The
  block check is line-scoped; the inline check parses only the caret's paragraph
  and only when the line contains a `]` — no full-document parse on the caret path.
- **Autoformat** — `> ` / `# ` / `- ` need no new code: the keystrokes reach the
  buffer and the styler renders + hides the marker (locked by pass-through tests).
- **Copy/Cut** — `visibleText(of:)` strips hidden markers; wired into both views'
  `copy`/`cut`.

**Wiring.** macOS: `doCommandBy` (`deleteBackward` only) + `textViewDidChangeSelection`
(caret normalization) + `NativeTextView+SeamlessCopy`. iOS: `shouldChangeTextIn`
(backspace), `textViewDidChangeSelection` (caret normalization), `copy`/`cut` overrides.
Character motion itself is left to the system on both platforms.

**Demos.** Both demo apps (`Demo/MarkdownEngineDemo` macOS, `…DemoiOS`) gained a live
segmented control — Reveal on edit · Seamless · Reveal raw — so the modes (and the
runtime toggle) can be exercised by hand. Both demo apps build.

**Tests.** `SeamlessInputTests` (~60 cases across backspace/inline-unwrap/atomic-token
delete/caret-normalization/copy/autoformat/visibility-routing); suite green excluding
two pre-existing animation-settle flakes in `ScrollingHeaderControllerTests` (unrelated
to this work); macOS + iOS-simulator builds of the library and both demo apps pass.

**Not yet done / follow-ups.** Hands-on visual verification of the caret *feel* in the
demo apps is the recommended next step (automated tests cover the logic, not the
feel). Possible polish: a copy-as-Markdown menu alongside copy-visible; richer
inline caret-skip if a future need justifies the complexity.

**Known limitations (full-line hidden block syntax).** Two block elements keep an
editable *source line* in the buffer that seamless renders as (visually) empty or a
rule, and the caret can still land on it:
- **Code-fence lines** (```` ``` ````): hidden in seamless, but the open/close fence
  lines remain; clicking/arrowing onto one and editing mutates the hidden fence.
  (Inside the fenced *body*, seamless edit/caret logic already no-ops via the
  parse-free `isInFencedCode` guard, and copy strips the fences.)
- **Thematic breaks** (`---`/`***`): rendered as a rule even with the caret on the
  source, but there's no atomic caret/delete handling for the rule line yet.

Proper handling means deciding what arrow/Backspace *do* on an invisible full-line
element (treat as an atomic object, skip the line, …) — a Phase-C design question, so
these are consciously deferred rather than partially (and riskily) handled here.

**Review.** Hardened after an Opus hate-review pass: the macOS arrow keys no longer
reimplement (grapheme-breaking) caret motion; per-keystroke `DocumentAST.parse` on
the caret path was removed (line-scoped normalization instead); the iOS block-marker
dead zone is handled; a missing `markerVisibility` argument on one macOS active-token
call site was fixed; Backspace on a rendered image deletes the whole token. Known,
documented design choices: rendered blocks (LaTeX/table/image) only reveal source in
`.revealAll`; copy drops the bullet/checkbox glyphs (copies textual content).
