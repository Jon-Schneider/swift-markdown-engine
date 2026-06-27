# Porting MarkdownEngine to iOS (iOS 16+, core-editing MVP)

## Context

`MarkdownEngine` is currently a **macOS-only** TextKit 2 Markdown editor (`Package.swift` declares `platforms: [.macOS(.v14)]`). The goal is to make it also run on **iOS**, so the same engine can back iOS apps.

> **Status: feasibility supported — this is an execution plan, not a feasibility study.** The two load-bearing risks are addressed with evidence, not paper argument: (1) both SPM dependencies clear iOS 16 (verified), and (2) the TextKit-2 draw **coordinate/flip convention** was validated by the Phase 0.5 spike — *off-screen* (not a real `UITextView`), on *iOS 26.5 only*, proving the flip question and nothing more. The per-helper port and real-view/iOS-16 validation are open and tracked in Phases 1–2. What remains is engineering, sequenced below. No production code has been changed yet.

**Definition of done (MVP):** a tagged release in which the iOS demo target builds and runs in the simulator, the core-editing feature set below works, and the acceptance checklist at the end is fully green. Anything outside that is Phase 4 (post-MVP).

Decisions locked with the user:
- **Minimum target: iOS 16+.** TextKit 2 (`NSTextLayoutManager`, `NSTextLayoutFragment`, `NSTextContentStorage`, `NSTextLayoutManagerDelegate`, `UITextView(usingTextLayoutManager:)`) is public on iOS 16, which is everything this port needs — so there is **no reason to set the floor higher**. We deliberately do *not* require iOS 26: nothing in this plan uses an API newer than iOS 16, and a higher floor would discard installed base for no technical gain. There is no TextKit 1 / legacy fallback path; iOS 16's TextKit 2 is the single code path.
  - **Verified (pre-flight):** both SPM dependencies clear iOS 16 with room to spare — **HighlighterSwift 3.1.0 declares `.iOS(.v13)`**, **SwiftMath 1.7.3 declares `.iOS(.v11)`** (`swift package resolve`, 2026-06-26). The floor is a confirmed fact, not an assumption.
- **Scope: core-editing MVP** → type/edit/render Markdown with live styling, bullets, checkboxes, code blocks, LaTeX, blockquotes. **Defer** the scroll-away header, horizontally-scrollable wide tables, custom scroller styling.
- **Deliverable now: the plan.** Implementation is a follow-up.

### What ports cleanly, and what doesn't

TextKit 2 genuinely crosses over — `NSTextLayoutManager` and friends are real on iOS 16, so the *layout* pipeline is a port, not a rewrite. That part of the earlier survey holds. But three claims in the prior draft were optimistic enough to be dangerous, and this plan corrects them with measured facts from the current tree:

1. **The "mechanical alias swap" is not small.** `import AppKit` appears in **48 of 59 source files**, and `NSColor`/`NSFont`/`NSImage`/`NSBezierPath` appear at **~160 sites**. This is a large, error-prone sweep across the styling, theme, services, renderer, and bridge layers — not a low-risk afterthought. Each site is a future `#if`-rot hazard. It is tracked as real work (see the inventory below), not folded into a comfortable "40%."
2. **Coordinate flipping — feared, then spiked, now de-risked (but only the flip).** The fragment's six draw helpers were authored against a **flipped** space (`NSGraphicsContext(cgContext:flipped:true)` appears 6× in `MarkdownTextLayoutFragment.swift`), which looked like six hand-derived geometry rewrites. The Phase 0.5 spike **retired that specific fear**: pushing UIKit's already-top-left context via `UIGraphicsPushContext` lets the *identical* macOS y-down math render upright (vector + raster image + SF-Symbol, PNG-confirmed). **This is a coordinate proof, not a port proof.** The same helpers still carry real non-coordinate divergences — `selectedRanges` (macOS-only) at fragment l.505/550, `NativeTextView`-config casts, `backingScaleFactor`/`NSScreen` (l.204-205/576-577), `usingColorSpace` (l.280) — that the spike hardcoded away. Those, plus `renderingSurfaceBounds` clipping (never exercised off-screen) and the real SwiftMath LaTeX raster path, are Phase 1 work, not "cleared."
3. **Dark/light appearance is threaded through MVP code, not just the LaTeX bridge.** `MarkdownStyler+Tables.swift:63` reads `…textView?.effectiveAppearance ?? NSApp.effectiveAppearance` to render tables — and tables are in the MVP. Neither `effectiveAppearance` nor `NSApp` exists on iOS. Color scheme must be threaded *into the styler* via `StylingContext`. This is promoted to **Phase 0**, not a bridge footnote.

`NSParagraphStyle`/`NSMutableParagraphStyle` are Foundation and need no abstraction. `NSString.size(withAttributes:)` / `.draw(at:withAttributes:)` are provided by UIKit too (verify only). Those two facts from the prior draft are correct and unchanged.

The hard part is the **interaction/view layer plus the IME/undo/appearance plumbing**, not text layout.

---

## File inventory (the real denominator)

48 files import AppKit. This is the actual scope; the prose above is just its summary. Classification: **Port** = type-alias swap + `import`, no logic change. **Adapt** = real per-platform code. **Rewrite** = re-home onto UIKit event model. **Defer** = `#if os(macOS)` for MVP.

### Shared core — Port (alias swap only)
| File | Type sites | Note |
|---|---|---|
| `Parser/MarkdownToken.swift` | 0 | `import AppKit` → `import Foundation` (only uses `NSAttributedString.Key`) |
| `Parser/BlockLevelTokenizer.swift` | 1 | alias swap |
| `Configuration/MarkdownEditorConfiguration.swift` | 0 | depends on theme only |
| `Styling/HeadingHelpers.swift` | 3 | alias swap |
| `Styling/MarkdownASTStyler.swift` | 22 | alias swap; high site count, verify each |
| `Styling/MarkdownStyler.swift` | 16 | alias swap |
| `Styling/MarkdownStyler+BulletMarkers.swift` | 0 | alias swap |
| `Styling/MarkdownStyler+Images.swift` | 1 | alias swap |
| `Styling/MarkdownStyler+TaskCheckboxes.swift` | 0 | alias swap |
| `Styling/TextStylingService.swift` | 4 | alias swap |
| `Services/WikiLinkService.swift` | 0 | alias swap |
| `Renderer/LayoutBridge.swift` | 2 | `NSFont` → `PlatformFont` |
| `Renderer/EmbeddedImageCache.swift` | 2 | `NSImage` → `PlatformImage` |

### Shared core — Adapt (real per-platform code)
| File | Type sites | Why it's not a clean swap |
|---|---|---|
| `Configuration/MarkdownEditorTheme.swift` | 24 | system-color defaults differ: `.labelColor`/`.secondaryLabelColor`/`.linkColor` (AppKit) vs `.label`/`.secondaryLabel`/`.link` (UIKit) — `#if` per default |
| `Services/MarkdownEditorServices.swift` | 11 | protocol return types → `PlatformImage`/`PlatformFont`/`PlatformColor`; every conformer follows |
| `Styling/MarkdownStyler+Latex.swift` | 4 | image pass + appearance dependency |
| `Styling/MarkdownStyler+Tables.swift` | 24 | **MVP**; `effectiveAppearance` probe at line 63 must become a threaded color scheme (see Phase 0) |
| `Renderer/MarkdownTextLayoutFragment.swift` | 17 | the 6 flipped-context draw helpers — **see Phase 0.5 spike** |

### Bridges — Adapt
| File | Type sites | Note |
|---|---|---|
| `MarkdownEngineCodeBlocks/HighlighterSwiftBridge.swift` | 7 | `NSApp.keyWindow?.effectiveAppearance` (line 113) → injected color scheme |
| `MarkdownEngineLatex/SwiftMathBridge.swift` | 7 | `NSApp.keyWindow?.effectiveAppearance` (line 72) → injected color scheme |

### View layer — Rewrite (re-home onto UIKit)
`Input/MarkdownInputHandler.swift`, `Input/MarkdownListHandler.swift` (mostly pure logic, but called from the AppKit delegate — extract behind a protocol), `TextView/PasteboardImageReader.swift` (`NSPasteboard` → `UIPasteboard`), `TextView/NativeTextViewWrapper.swift` (add `UIViewRepresentable` sibling), and the `Coordinator/` + `NativeTextView/` extensions enumerated in the subsystem table below.

### View layer — Defer (`#if os(macOS)` for MVP)
`TextView/ScrollingHeaderController.swift`, `TextView/ClampedScrollView.swift`, `TextView/NativeTextViewContainer.swift` (macOS uses it for header+overscroll stacking; iOS uses bare `UITextView` scrolling for MVP), `Renderer/WideTableOverlay.swift`, `NativeTextView+CursorRects.swift`, `NativeTextView+DragSelectBoost.swift`, `NativeTextView+SpellingToggles.swift`.

> **Not deferred — `TextView/BottomOverscrollPolicy.swift` is cross-platform.** It is pure `CGFloat` math with a *gratuitous* `import AppKit` (uses no `NS*` symbol). Phase 0 conditionalizes that import → `import Foundation`, and the type stays available on both platforms (its consumer, `NativeTextViewContainer`, is the deferred part). This is what lets `BottomOverscrollPolicyTests` run in the iOS suite below; it must **not** be `#if os(macOS)`-gated.

---

## Subsystem decisions — including the ones the prior plan omitted

Every AppKit coordinator/extension gets an explicit **port / adapt / defer / drop** decision. The starred rows are subsystems the previous draft did not mention at all.

| Subsystem (file) | Decision | Rationale / risk |
|---|---|---|
| `Coordinator+Restyling.swift` | **Adapt** | core restyle loop; drives `rebuildTextStorageAndStyle()`. Must fire from `UITextViewDelegate`. |
| `Coordinator+TextDelegate.swift` | **Adapt** | ★ contains `NSApp.currentEvent?.type` at **line 198**, in the *selection-change* path, to suppress link-preview on non-key events. No `NSApp` on iOS — replace with an explicit "last input was keyboard vs. gesture" flag set by the input handlers. Must be resolved, not ignored. |
| `Coordinator+WritingTools.swift` | ★ **Drop for MVP** | macOS Writing Tools API. iOS has a different surface; not in MVP. Gate `#if os(macOS)`; revisit post-MVP. |
| `Coordinator+Autocorrect.swift` | ★ **Adapt** | iOS autocorrect + marked-text lifecycle differs (Risk #2). Needs its own iOS implementation, not a port. |
| `Coordinator+Find.swift` | **Adapt** | depends on the selection model; see selection note below. |
| `Coordinator+InlineSelection.swift` | **Adapt** | selection-model dependent. |
| `Coordinator+CodeBlocks.swift` | **Port** | mostly logic. |
| `Coordinator+Notifications.swift` | **Adapt** | AppKit notification names → UIKit equivalents. |
| `NativeTextView.swift` (`setMarkedText` override, l.75) | ★ **Rewrite** | macOS overrides `setMarkedText` to restyle the marked paragraph. `UITextView` exposes marked text via `UITextInput`; there is **no equivalent override**. The restyle-during-IME hook must be rebuilt against `UITextInput`/`textViewDidChange`. Underestimated before as "needs care." |
| `NativeTextView+PasteHandling.swift` | **Rewrite** | `NSPasteboard` → `UIPasteboard`; override `paste(_:)` / `canPerformAction(_:withSender:)`. |
| `NativeTextView+ClickRemap.swift`, `+TaskCheckbox.swift` | **Rewrite** | `mouseDown` → `UITapGestureRecognizer` for checkbox toggle + paragraph-spacing remap. |
| `NativeTextView+CaretWorkarounds.swift`, `+FrameAndOverscroll.swift`, `+Placeholder.swift`, `+SpellingPolicy.swift` | **Adapt** | per-feature; some collapse to no-ops on iOS. |
| Undo (`UndoManager` across 5 files) | ★ **Adapt + test** | per-document undo just landed (commits `445247a`, `71bb6e6`). `UITextView` undo coalescing + the marked-text/undo interaction differ from AppKit. Needs explicit IME-interaction tests, not a "logic ports" hand-wave. |

### Selection model (called out because Find depends on it)
macOS uses `selectedRanges` (plural, discontiguous); iOS `UITextView` exposes a single `selectedTextRange`/`selectedRange`. The recently-shipped in-document find (`0a47d68`) and multi-range styling assume the plural model. This is **not** a 1:1 swap — anywhere that iterates multiple selection ranges needs a documented single-range behavior on iOS.

### Accessibility / keyboard (MVP table stakes, previously unlisted)
- **Dynamic Type**: honor `UIContentSizeCategory` (at minimum scale the base font; ideally `UIFontMetrics`). An editor that ignores it is a bug report.
- **Keyboard management**: first-responder lifecycle, keyboard-avoidance insets, optional `inputAccessoryView`. The macOS container's custom flipped stacking does not exist on iOS; UITextView content insets + keyboard insets replace it.
- **RTL / bidirectional text** (Key Risk #3): blockquote bars and bullets currently paint at a hardcoded *left* gutter; under RTL they belong on the right. Decide **support vs. documented defer** for MVP — do not leave it implicit.
- These are explicitly in MVP scope so they are not "discovered" late.

---

## Architecture: shared core + thin platform-conditional view layer

```
#if canImport(UIKit)  → UIKit types & UITextView path
#else                 → AppKit types & NSTextView path
```

### Phase −1 — Pre-flight go/no-go (done where possible)

The facts that can invalidate the headline decisions, checked **before** committing to the work:

- **[DONE ✅] Dependency floor.** `swift package resolve` → HighlighterSwift 3.1.0 (`.iOS(.v13)`), SwiftMath 1.7.3 (`.iOS(.v11)`). Both clear iOS 16. **Go.**
- **[PARTIAL ✅ — coordinate/flip thesis only] TextKit-2 layout.** The Phase 0.5 spike (a throwaway SPM package, `Spike/FlipSpike/`) proved a **narrow but load-bearing** point: the macOS fragment's `point.y + tb.origin.y` y-down draw math renders **upright** on iOS when the context is established via `UIGraphicsPushContext` instead of `NSGraphicsContext(flipped:true)` — for vector drawing, raster `PlatformImage.draw(in:)`, and a tinted SF-Symbol. **Path A works for the coordinate convention; Path B (manual flip) is not needed.** **Scope honesty:** the spike (a) ran **only on iOS 26.5**, not the iOS 16 floor; (b) used an **off-screen `NSTextLayoutManager` render loop, not a real `UITextView`** — so `renderingSurfaceBounds` clipping and the UITextView draw path are *unvalidated*; (c) **hardcoded** away the `selectedRanges` / `NativeTextView`-config / `backingScaleFactor` / `usingColorSpace` plumbing the real bullet/checkbox/code-bg helpers depend on; (d) used a per-platform-built oracle, so it **did not** exercise SwiftMath's real LaTeX rasterization. The flip risk is genuinely retired; the helper-level port is **not** "done." **Go on feasibility; the remaining items are tracked in Phase 1.**

### Landing strategy — how this merges without a mega-branch

Each phase is sized to land on `main` as an independently-reviewable PR, most with **zero macOS behavior change**:

| Merge unit | Size | Lands independently? | macOS behavior change |
|---|---|---|---|
| Phase 0 — alias typealiases + `import` sweep + color-scheme threading | **L** (broad: ~160 sites across 48 files, but mechanical) | **Yes** | None (pure refactor; `PlatformColor` ≡ `NSColor` on macOS) |
| Phase 0.5 — flip spike harness | **S** (done ✅) | **Yes** (deletable throwaway, or kept as an iOS test) | None |
| Phase 1 — fragment draw-helper port | **M** (6 helpers; coordinate convention proven, per-helper port — selection/config/scaling/clipping/LaTeX round-trip — open) | **Yes** (gated; macOS path untouched) | None |
| Phase 2 — iOS view/input layer | **L** (the genuine rewrite: input, IME, selection, paste, gestures) | **Yes** (all new `#if canImport(UIKit)` files) | None |
| Phase 3 — SwiftUI bridge + iOS demo | **S** (mirror an existing representable; new demo target) | **Yes** | None |

Sizes are **relative effort** (S/M/L) grounded in the inventory counts, not hour estimates — enough to sequence and staff. The critical path runs Phase 0 → 1 → 2; Phase 0.5 is done and Phase 3 is small. **Phase 2 (L) is the real work** and the place to expect surprises.

The rule: **no phase changes macOS runtime behavior.** If a phase's diff would alter the macOS path, it's mis-scoped. Phase 0 ships first and proves the refactor is inert before any iOS code exists.

### Phase 0 — Foundation + appearance threading (low-to-medium risk)

Groundwork that keeps building on macOS while unblocking iOS compilation of the non-view modules.

- **`Package.swift`**: add `.iOS(.v16)` to `platforms`. Confirm `HighlighterSwift` and `SwiftMath` resolve for iOS 16 (both declare iOS support — verify the *minimum* each requires is ≤ 16, or the floor rises).
- **New `Sources/MarkdownEngine/Platform/Platform.swift`**: conditional `typealias`es — `PlatformColor`, `PlatformFont`, `PlatformImage`, `PlatformBezierPath`, `PlatformFontDescriptor` — plus small shims where the APIs diverge (`UIBezierPath.addLine(to:)` vs `NSBezierPath.line(to:)`, `UIColor(white:alpha:)` vs `NSColor`).
- **Alias sweep** across the Port/Adapt core rows above (~160 sites). Theme system-color defaults wrapped in `#if` per the mapping in the inventory.
- **Color-scheme threading (promoted from a footnote):** add an explicit `colorScheme` (light/dark) to `StylingContext` and to the service call sites that currently probe `effectiveAppearance`/`NSApp` — `MarkdownStyler+Tables.swift:63`, `HighlighterSwiftBridge.swift:113`, `SwiftMathBridge.swift:72`. On macOS the value is derived from the text view's `effectiveAppearance` (no behavior change); on iOS it is passed in from `traitCollection`/SwiftUI environment. This is **MVP-blocking** because tables are MVP.

**Exit criteria:** macOS target builds & all existing tests pass; iOS target compiles the **non-view** modules (Parser/Styling/Config/Services/`LayoutBridge`); no `effectiveAppearance`/`NSApp` reference remains in the shared core.

### Phase 0.5 — Coordinate-flip spike (do this BEFORE Phase 1) ⚠️

The single scariest unknown, isolated so it fails fast on day one rather than in Phase 2.

- *(As actually run)* a throwaway SPM harness drew five tagged primitives (bullet, blockquote bar, checkbox, a red/yellow orientation-oracle image, an SF-Symbol) through a custom `NSTextLayoutFragment` and an **off-screen `NSTextLayoutManager` render** into a `UIGraphicsImageRenderer`, replacing the `NSGraphicsContext(cgContext:flipped:true)` dance with `UIGraphicsPushContext`. *(Caveat, see result: this is **not** a `UITextView(usingTextLayoutManager:)` integration — a real-view spike was not done and remains a Phase 2 gap.)*
- **Decision gate (bounded — there is a guaranteed escape hatch):**
  - *Path A (clean):* iOS draws in native top-left coordinates; the helpers' Y math runs unchanged. Preferred if it's genuinely "free."
  - *Path B (fallback, known cost):* if re-deriving the geometry were fiddly, push a vertical flip transform onto the iOS `CGContext` (`translate(x:0, y:height)` + `scale(x:1, y:-1)`) so the **existing `flipped:true` math runs unchanged**. Converts "rewrite helpers" into "wrap the context once" — so the spike can't run open-ended.

**Exit criteria:** the primitives render upright on iOS via Path A or Path B, with the chosen path documented. This is the **second go/no-go gate** for *the coordinate question only*; helper-level portability (selection, config, scaling) is Phase 1.

> **RESULT (Path A confirmed for the coordinate question; off-screen, iOS 26.5):** ran the spike on iPhone 17 Pro / iOS 26.5, **PNG-verified** (not just pixel-asserted), via an **off-screen layout-manager render — not a `UITextView`**. **Path A renders upright for every primitive tested** — `UIGraphicsPushContext` + the unchanged macOS y-down math — with the production fragment draw code **not modified**. Read the scope limits below before treating any helper as "ported."
>
> **What the spike PROVED (narrow — the coordinate/flip convention only):**
> - The y-down draw math (`point.y + tb.origin.y`) renders **upright** on iOS under `UIGraphicsPushContext`, for: a text glyph (`NSString.draw(at:)`), `BezierPath` fill, `BezierPath` stroke, raster `PlatformImage.draw(in:)`, and a tinted SF-Symbol. So **no per-primitive flip transform** is needed — the macOS→iOS change for the coordinate question is just the context-establishment swap.
> - That's it. This proves the *flip convention*, not that any production helper is portable.
>
> **What the spike did NOT prove (all Phase 1 work — NOT cleared):**
> - **The bullet/checkbox helpers don't compile on iOS as written.** They read `tv.selectedRanges` (plural, macOS-only — fragment l.505/550), cast `textView as? NativeTextView` for theme/config (l.276/409/461/513/589), pixel-snap via `window?.backingScaleFactor`/`NSScreen` (l.204-205/576-577), and `drawCodeBlockBackground` uses `NSColor.usingColorSpace(.deviceRGB)` (l.280). The spike **hardcoded all of this away**. Each needs an iOS path (`selectedTextRange`, injected config, `UIScreen.scale`, UIColor color-space).
> - **No `UITextView` was involved.** The spike used a bare `NSTextLayoutManager` + manual `draw(at:in:)` into a `UIGraphicsImageRenderer`, *not* `UITextView(usingTextLayoutManager:)` as this phase originally prescribed. So `renderingSurfaceBounds` clipping (fragment l.57-71, which the full-width code-bg and blockquote-bar helpers depend on) was **structurally unable to fail** and is unvalidated; the real UITextView draw context is assumed-by-proxy, not tested.
> - **Real LaTeX rasterization (SwiftMath → `UIImage`) was never run.** The oracle is a per-platform hand-built bitmap tuned to land red-on-top, so it cannot detect a genuine SwiftMath image-origin bug. Image-draw orientation is cleared; the LaTeX *round-trip* is not.
> - **iOS 16.** The spike ran only on **iOS 26.5**. TextKit-2 fragment behavior and the private selector below shifted across 16→18; the floor the plan underwrites is unverified.
> - **`@objc(extraLineFragmentAttributes)` private selector** behavior on iOS (Risk #2) — and see the **App Store private-API risk** in the risk list.
> - **SF-Symbol tinting.** The spike forced a solid tint; a template symbol without an explicit color may inherit the context fill — verify the real checkbox tint.
> - **Behavioral validation generally.** The spike asserts vertical band order only — no horizontal/gutter position, no selection-skip, no pixel-snap. A helper drawing in the wrong gutter would still pass.
>
> **Lesson carried into Phase 1 snapshot tests:** the harness initially produced a convincing **false** "upside-down" failure from two *measurement* bugs (an extra CGImage read-flip, and a points-vs-pixels @3x mismatch). So: **verify a suspected flip against an actual rendered PNG before concluding the draw code is wrong, and convert device pixels → points (`scale = pixelHeight / pointHeight`) before any geometry assertion.** A "flipped" pixel result is as likely to be a measurement artifact as a real bug.
>
> **Verifiability caveat:** the spike lives in `Spike/` and is **gitignored by design** (throwaway), so this result is not reproducible from the committed tree and no PNG/CI log is checked in. The ✅ rests on the recorded run above, not a committed artifact. The durable CI gate is the **iOS test scheme** in Phase 2's verification — that, not the spike, is what keeps the port honest over time.

> **ADDENDUM — real `UITextView(usingTextLayoutManager:)` spike (the off-screen gap, now closed for the clipping question):**
> The Phase 0.5 result above used a *bare* `NSTextLayoutManager` + manual `draw(at:in:)`, so it was — as the plan flagged — structurally unable to test `renderingSurfaceBounds` clipping. A follow-up spike (`Spike/FlipSpike/Sources/FlipSpike/UITextViewSpike.swift` + `Tests/.../UITextViewSpikeTests.swift`, run via `xcodebuild test -scheme FlipSpike -destination 'platform=iOS Simulator,…'`) closes that gap by hosting a custom `NSTextLayoutFragment` inside a **real `UITextView(usingTextLayoutManager: true)`** (installed through `textView.textLayoutManager?.delegate`) and rendering the **view's own draw path**.
>
> **What it PROVED (PNG-verified, iPhone 17 Pro / iOS 26.5):**
> - The custom fragment installs into a real `UITextView` via the layout-manager delegate, and the **view's draw cycle invokes the fragment's `draw(at:in:)`** — no manual enumerate loop.
> - **`renderingSurfaceBounds` clipping is real on iOS.** Control pass (returning `super.renderingSurfaceBounds`): a full-container-width code background is **clipped to the text's used width**, and a left-gutter blockquote bar **disappears entirely**.
> - **Production's expansion defeats the clip.** With the surface expanded the way `MarkdownTextLayoutFragment.renderingSurfaceBounds` does (reach `-layoutFragmentFrame.origin.x`, span full container width), both the full-width background **and** the gutter bar render correctly. So the production override is *load-bearing on iOS*, and it works.
> - The y-down/`UIGraphicsPushContext` convention from Phase 0.5 also holds inside the real view (full-width fill and gutter bar land upright in their own line bands).
>
> **What it did NOT prove (still open):**
> - **Headless render path, not on-screen present.** A hostless `xctest` has no render server, so `drawHierarchy(afterScreenUpdates:)` returns blank; the spike captures via `CALayer.render(in:)`, which drives the view's `drawRect`/fragment draws synchronously (so it *does* exercise the view's clipping — the point) but is not a present-to-screen + `simctl`/MCP screenshot. A true on-screen capture is still a Phase 2 nicety.
> - **iOS 26.5 only** — same floor caveat as Phase 0.5; the separate iOS-16 re-run item still stands.
> - **Still a self-contained probe fragment**, not the production helpers — `selectedTextRange`/injected-config/`UIScreen.scale`/UIColor-color-space remain Phase 1.

### Phase 1 — iOS renderer adaptation (medium risk)

- **`Renderer/MarkdownTextLayoutFragment.swift`**: wrap each helper's draw body in the cross-platform context helper (`UIGraphicsPushContext` on iOS, the existing flipped `NSGraphicsContext` on macOS) and swap `NSBezierPath` → `PlatformBezierPath`. **The spike proved only that the coordinate convention survives** — the helpers themselves still need real per-platform work before they compile or behave on iOS:
  - **`selectedRanges` → `selectedTextRange`.** `drawBulletMarkers` (l.505) and `drawTaskCheckboxes` (l.550) read `tv.selectedRanges` (plural, macOS-only) to skip drawing over a selected marker — won't compile on iOS, and the selection-skip behavior must be reimplemented against the single iOS selection.
  - **`NativeTextView` config/theme casts** (l.276/409/461/513/589): five helpers reach `textView as? NativeTextView` for `.configuration`/`.theme`. On iOS there is no `NativeTextView` (Phase 2) — thread config/theme in another way, or sequence these helpers after the iOS view type exists.
  - **Pixel snapping** (l.204-205/576-577): `window?.backingScaleFactor ?? NSScreen.main` → `UIScreen.scale`/`traitCollection.displayScale`.
  - **Color space**: `isCodeBlockBackgroundColor` uses `NSColor.usingColorSpace(.deviceRGB)` (l.280) — needs the UIColor equivalent.
  - **`renderingSurfaceBounds` clipping** (l.57-71): never exercised by the off-screen spike; the full-width code-bg and blockquote-bar helpers depend on it. Validate inside a real `UITextView`.
  - **LaTeX round-trip + SF-Symbol tint**: run a real SwiftMath→`UIImage` render (origin correctness), and tint the checkbox symbol explicitly so it doesn't inherit the context fill.
  - **Risk flag (Risk #2):** the `@objc(extraLineFragmentAttributes)` private-TextKit-2 workaround (`MarkdownTextLayoutFragment.swift:50`, "FB15131180"). Verify on iOS; **define the acceptance test first** (trailing-paragraph bullet/spacing renders correctly) and ship the no-op fallback only if that test fails. **Also assess the App Store private-API risk** (see Key Risks).
- **`Renderer/WideTableOverlay.swift`**: deferred — gate `#if os(macOS)`. For MVP, render tables as a static (non-horizontally-scrolling) attributed/image block.

**Exit criteria:** a TextKit 2 stack on iOS renders a styled attributed string with bullets/checkboxes/code-bg/blockquote bars correctly in a test-harness view.

> **RESULT (Phase 1 done — renderer ported, harness-verified on iOS 26.5):** `MarkdownTextLayoutFragment.swift` is now AppKit-free. The macOS-only `container.textView as? NativeTextView` chain (theme/config/highlighter/selection/scale, 5 sites + the delegate) is replaced by an injected **`MarkdownFragmentContext`** protocol (`Renderer/MarkdownFragmentContext.swift`); the 6 flipped-`NSGraphicsContext` sites, the even-odd selection cut-out, `NSColor.usingColorSpace`, `NSScreen.backingScaleFactor`, and the SF-Symbol checkbox move to **`Renderer/PlatformDrawing.swift`** shims (`withFlippedDrawingContext`, `fillEvenOdd`, `PlatformColor.rgbComponents`, `tintedSymbolImage`). On macOS each shim is the original idiom and `NativeTextView` conforms to the protocol with byte-identical expressions, so the refactor is **inert**: macOS builds clean and the suite is green except 4 `ScrollingHeaderControllerTests` that **fail identically on the pre-change Phase 0 tree** (a pre-existing animation-timing flake, unrelated). On iOS, all six primitives — bullet, tinted checkbox, full-width code-bg **with the even-odd cut-out**, blockquote bar, HR, and an upright image — were **PNG-verified** in a real `UITextView(usingTextLayoutManager:)` via the `FlipSpike` harness (`RendererPortHarness`).
>
> **Scope honesty:** the `MarkdownEngine` target still does **not** iOS-compile (39 bare-AppKit view/input files remain — Phase 2), so the in-place file's real iOS compilation is proven only when Phase 2 un-gates the target; until then the `FlipSpike` harness (which **mirrors** the ported helpers + shims, not imports them) is the iOS evidence — same caveat structure as Phase 0.5. The iOS source that *feeds* the context (selection from `selectedTextRange`, `traitCollection.displayScale`) is the Phase-2 view; Phase 1 delivered the cross-platform **mechanism**. Still open from Phase 1's risk list: the `extraLineFragmentAttributes` App-Store/iOS assessment and the real SwiftMath→`UIImage` LaTeX round-trip.

### Phase 2 — iOS view & input layer (the real work)

- **New `Sources/MarkdownEngine/TextView/iOS/MarkdownUITextView.swift`**: `UITextView(usingTextLayoutManager: true)`, `textLayoutManager?.delegate = MarkdownLayoutManagerDelegate()`. Mirror macOS insets/typing attributes.
- **Input/keyboard**: extract the AppKit-specific entry points in `MarkdownListHandler`/`MarkdownInputHandler` behind a small protocol; drive the shared logic from `UITextViewDelegate.textView(_:shouldChangeTextIn:replacementText:)` + `UIKeyCommand`. Resolve the `NSApp.currentEvent` branch (l.198) via an explicit input-source flag.
- **Marked text / IME**: rebuild the `setMarkedText` restyle hook against `UITextInput`/`textViewDidChange` (per the subsystem table). Per-keystroke restyle must not fight the IME.
- **Selection / hit-testing**: `selectedRanges` → `selectedTextRange`; document single-range behavior for Find. TextKit 2 hit-testing in `LayoutBridge` ports. Re-home checkbox toggle + spacing remap to `UITapGestureRecognizer`.
- **Paste**: `NSPasteboard` → `UIPasteboard`; override `paste(_:)` / `canPerformAction(_:withSender:)`.
- **Context menu (MVP)**: `NSMenu` → `UIEditMenuInteraction` + `UIMenu`/`UIAction` for Bold/Italic/Heading/List.
- **Accessibility/keyboard**: Dynamic Type + keyboard-avoidance per the table-stakes section.

**Drop for MVP (`#if os(macOS)`):** `ScrollingHeaderController`, `ClampedScrollView` + `WideTableOverlay` + `SubtleScroller`, `+CursorRects`/`+DragSelectBoost` (mouse-only), Writing Tools, spelling-toggle UI. iOS gets system `UITextView` scrolling/selection.

> **RESULT (Phase 2a done — iOS target compiles + read-only rendering view + iOS demo):** scoped first slice of Phase 2.
> - **Compile sweep:** the `MarkdownEngine` target now builds for the iOS simulator. ~32 macOS-only view/input/coordinator files are `#if os(macOS)`-gated whole-file; three shared files are partially gated (`MarkdownStyler.styleTables` call, `TextStylingService.restyle`, `WikiLinkService.resolveIdentifier`); `MarkdownLists` was split so its pure helpers (`indentLevel`/regexes) stay cross-platform while its `NSTextView` editing methods are gated. `BottomOverscrollPolicy` kept cross-platform (gratuitous AppKit import dropped). Cross-platform shims added to `Platform.swift` for the real API divergences the agents/compiler surfaced: `NSValue(cgRect:)`/`cgRectValue`, `NSTextContainer.size`, font `.boldTrait`/`.italicTrait` + `withSymbolicTraitsCompat`, and an inert `.spellingState` iOS key. **This finally proves the Phase 1 renderer iOS-compiles for real** (closing that caveat). macOS stays inert (127/131; same 4 pre-existing `ScrollingHeaderControllerTests` flakes).
> - **iOS view:** new `TextView/iOS/MarkdownUITextView.swift` (a `UITextView` on an explicit TextKit-2 stack that *is* the fragment's `MarkdownFragmentContext`) + `MarkdownUITextViewWrapper.swift` (`UIViewRepresentable`). Read-only: reuses the shared `WikiLinkService` → `TextStylingService` → `MarkdownStyler.styleAttributes` pipeline; `MarkdownColorScheme.resolved(from: UITraitCollection)` added.
> - **Demo:** a new `Demo/MarkdownEngineDemoiOS.xcodeproj` (iOS 16, only the `MarkdownEngine` product — no AppKit bridges) **runs in the simulator**; a screenshot on iPhone 17 Pro / iOS 26.5 confirms bullets, checkbox symbols (with strikethrough), blockquote gutter bar, thematic-break rule, and heading/bold/italic/inline-code, dark-mode themed.
>
> **Out of scope / next Phase 2 passes:** editing, input handlers, marked-text/IME, autocorrect, selection model, paste, tap-to-toggle checkboxes, context menus, keyboard/Dynamic-Type; and iOS tables/LaTeX/syntax-highlighting (the `+Tables` compositor, `WideTableOverlay`, and both bridges remain macOS-gated). Every new `#if os(macOS)` gate is a Phase 4 un-defer row.
>
> *(Update: editing/checkboxes/Dynamic-Type/keyboard landed in Phase 2b; **syntax highlighting + LaTeX bridges were subsequently ported to iOS** and verified in the demo. Still out: tables, marked-text/IME, autocorrect, paste, context menus, link taps, undo.)*

> **RESULT (Phase 2b done — iOS editing + input behaviors + checkbox toggle + Dynamic Type/keyboard):** the iOS view is now an editor.
> - **Shared input logic:** the macOS-only `MarkdownLists.handleInsertion(textView:)` decision logic was lifted into a pure, cross-platform `computeListInsertion(currentText:affectedCharRange:replacementString:configuration:) -> ListInsertionDecision` (`.allowDefault`/`.block`/`.replace`). macOS `handleInsertion` is now a thin adapter (behavior-identical); the iOS `UITextViewDelegate` drives the same function. Locked by **13 cross-platform unit tests** (`ListInsertionTests`, run on the macOS host) covering Enter continuation (bullet/numbered/checkbox/blockquote), empty-item exit, Tab indent + nesting cap, auto-pairs, `[[`→`[[]]`, `-`+`>`→`→`, code-fence completion.
> - **Editable `MarkdownUITextView`:** `isEditable`, own `UITextViewDelegate`. `restyleInPlace()` does attribute-only restyle (caret-preserving) with active-token marker reveal; `shouldChangeTextIn` drives `computeListInsertion`; `textViewDidChange`/`…ChangeSelection` restyle. **Tap-to-toggle checkboxes** via a `UITapGestureRecognizer` (attribute hit-test through the cross-platform `LayoutBridge.boundingRect`, flip `[ ]`↔`[x]`, restyle — mirrors `NativeTextView+TaskCheckbox`).
> - **Accessibility/keyboard:** Dynamic Type via `UIFontMetrics` (verified at XXXL in the sim — title wraps, everything scales); standard keyboard-avoidance (bottom content inset from the keyboard frame).
> - **Verified:** 4 real-view iOS-simulator integration tests (bullet continuation, pass-through typing, auto-close, checkbox toggle both directions) in the gitignored FlipSpike harness; editable demo runs with no rendering regression. macOS inert (140/144; the 4 reds are the pre-existing `ScrollingHeaderControllerTests` flakes).
> - **App Store private-API item RESOLVED:** the `@objc(extraLineFragmentAttributes)` private-selector override (FB15131180) is now `#if os(macOS)`-gated — **confirmed absent from the built iOS binary** (`strings`), so the iOS library won't trip ITMS-90338 for it. Accepted iOS trade-off: minor trailing-line-spacing drift at document end (tracked).
> - **Perf data point:** a worst-case full-document restyle of a ~13k-char multi-page doc is **~16.75 ms in the simulator** — at the 16 ms budget, so **paragraph-scoped restyle is a needed follow-up for large docs** (typical/small docs are comfortably under). The plan's "<16 ms on a low-end *device*" gate still needs a real-device measurement.
> - **Decisions made autonomously (overnight, user asleep):** (1) **Did NOT** port the syntax-highlighting/LaTeX bridges — they require threading a color scheme through the `SyntaxHighlighter` protocol + the fragment (5+ shared-styler call sites) and external-library iOS validation; too much macOS-regression risk to land unsupervised. Left as the next scoped workstream. (2) **Did NOT** attempt marked-text/IME/autocorrect — the plan's #1 risk and not interactively testable here (no UI-automation tools); autocorrect/smart-substitutions are disabled on the iOS view for now. (3) **RTL: documented defer** (see Key Risks #3 update) — gutter bars/bullets stay left for MVP. (4) iOS-16 re-run remains blocked: **no iOS 16 runtime is installed** in this environment (only 18.3/18.4/18.6/26.5).

### Phase 3 — SwiftUI bridge

- **Split `TextView/NativeTextViewWrapper.swift`**: keep the `NSViewRepresentable` under `#if os(macOS)`; add a sibling `UIViewRepresentable` (`#if canImport(UIKit)`) exposing the **same public API**. **First task: enumerate that public surface** from `NativeTextViewWrapper.swift` — the initializer params, the text `Binding`, and each callback closure — into a shared protocol both representables conform to, so "can't silently drift" is compiler-enforced, not aspirational.
- Add an **iOS demo target** (decided: a dedicated iOS demo, not `#if` branches in the macOS Demo, so the simulator path is exercised independently).

### Phase 4 — Deferred parity (post-MVP) — un-defer backlog

Each MVP deferral maps to its re-enablement so the `#if os(macOS)` gates don't become permanent:

| Deferred for MVP | Re-enable as |
|---|---|
| `ScrollingHeaderController` | iOS scroll-away header (UIKit content-offset observation) |
| `ClampedScrollView` + `NativeTextViewContainer` | iOS scroll clamping / overscroll if needed beyond system `UITextView` (the `BottomOverscrollPolicy` math is already cross-platform) |
| `WideTableOverlay` | horizontally-scrollable wide tables on iOS |
| `Coordinator+WritingTools` | iOS text-editing / Writing Tools surface |
| `NativeTextView+CursorRects` / `+DragSelectBoost` / spelling-toggle UI | iPad pointer interactions + richer context menus |
| `MarkdownStyler+Tables` (NSImage table compositor) | iOS table rendering (cross-platform image compositor, or a CoreText/UIKit renderer) |
| ~~`HighlighterSwiftBridge` / `SwiftMathBridge`~~ | **DONE** — both bridges ported to iOS (color-scheme threaded through `SyntaxHighlighter`/`LatexRenderer` + the fragment; off `NSApp`/`NSImage`/`DistributedNotificationCenter`). iOS syntax highlighting + LaTeX verified in the demo. |
| `@objc(extraLineFragmentAttributes)` (FB15131180, gated off iOS) | a public-API trailing-metrics fix for iOS document-end spacing (only if the degradation proves visible) |
| RTL gutter mirroring (bars/bullets hardcoded left) | mirror gutter-drawn blockquote bars + bullets under right-to-left layout |
| iOS marked-text/IME + autocorrect + paste + context menu + link taps + undo | the deferred Phase-2 interaction passes (autocorrect/smart-substitutions are currently disabled on the iOS view) |
| Full-document restyle on iOS (`MarkdownUITextView.restyleInPlace`) | paragraph-scoped incremental restyle (the macOS path is already scoped) for large-doc keystroke perf |

Anything still gated after MVP must appear in this table — a gate with no backlog row is a bug.

---

## Key risks

1. **Coordinate-flip geometry** (Phase 0.5 spike) — feared as six geometry rewrites; the spike **resolved it** as a one-line context swap (Path A). *Resolved for the coordinate question only* — the helper-level port (selection, config, scaling, clipping; see Phase 1) is separate and not de-risked by this.
2. **`extraLineFragmentAttributes` private selector** on iOS — two distinct risks:
   - *Functional:* acceptance test (trailing-paragraph bullet/spacing renders correctly) defined before relying on it. **Degraded state if the no-op fallback engages:** the final paragraph's bullet enlargement / trailing line spacing may be slightly off at document end — **acceptable-but-tracked** for MVP, a conscious sign-off, not a silent regression.
   - *App Store (new):* `@objc(extraLineFragmentAttributes)` overrides a **private Apple selector**. This is a `MarkdownEngine` *library* embedded by third-party apps, so it is a private-API / static-analysis flag at App Store review. **Assess before committing to it:** confirm whether it trips ITMS-90338-class rejections; if so, the no-op fallback (or an alternative trailing-metrics fix) becomes **mandatory, not optional**. Do not ship a private selector to the App Store on the assumption it's fine because STTextView does it on macOS.
3. **Right-to-left / bidirectional text** — the blockquote-bar and bullet helpers paint at a **hardcoded left gutter** (`point.x - layoutFragmentFrame.origin.x`); under RTL these belong on the right. iOS users expect proper RTL far more than the macOS app likely did. **DECISION (Phase 2b): documented defer for MVP** — gutter-drawn bars/bullets stay at the left gutter on iOS; no mirroring. This is a conscious, recorded omission (not silent), with a Phase 4 un-defer backlog row for RTL gutter mirroring.
4. **Marked text / IME & autocorrect** — `setMarkedText` has no iOS override equivalent; the restyle hook is a rewrite. **Named test cases** (not "test IME"): Japanese kana→kanji conversion, Pinyin candidate selection, emoji/dictation insertion, and **undo invoked during an active marked-text session**. These are the lifecycles that actually break.
5. **Per-keystroke restyle cost on real hardware** — `rebuildTextStorageAndStyle()` is block-scoped/incremental (ARCHITECTURE invariant), but iOS devices are slower than a Mac. **Acceptance threshold: < 16 ms/keystroke (60 fps budget) on a low-end supported device for a multi-page document.** Measure on hardware, not just the simulator.
6. **Selection model divergence** — plural `selectedRanges` → single `selectedTextRange`; Find *and* the bullet/checkbox selection-skip depend on it.
7. **System-color parity** — a few macOS dynamic colors have no exact UIKit twin; pick closest and theme.
8. **`#if` maintenance tax forever** — two event/selection/IME surfaces under one public API. Mitigated by the API-parity protocol (Phase 3) and shared-behavior tests (below).

## Verification

- **Build both destinations**: `-destination 'platform=macOS'` and `-destination 'platform=iOS Simulator,name=<sim>'` (via xcodebuild MCP `build_sim`).
- **Real iOS test target**: the existing `testTarget` runs on the host (macOS), so `#if canImport(UIKit)`-guarded tests in it **never execute** — they compile out. Add an **iOS test scheme** (run via xcodebuild MCP `test_sim`) so the portable styling/measurement layers and the undo/marked-text interaction are actually exercised on iOS in CI. Without this, "tests stay green" only means the old macOS tests still pass and proves nothing about the port.
- **Shared-behavior tests (named, not hypothetical)**: of the 12 existing test files, **5 are platform-pure and run on iOS as-is** — `ASTPipelineTests`, `BlockParserTests`, `InlineParserTests`, `ListParsingTests`, `BlockquotePasteTests` — plus **`BottomOverscrollPolicyTests`, which runs on iOS once Phase 0 conditionalizes the gratuitous `import AppKit` in `BottomOverscrollPolicy.swift`** (the type itself is pure `CGFloat` math). These are the initial cross-platform suite. **`MarkdownASTStylerTests` is styling *logic* but currently AppKit-coupled** (asserts on `NSColor`/`NSFont`) — it crosses over once the Phase 0 alias swap reaches it, and should be the first added to the iOS suite. The remaining 5 (`NativeTextViewContainerTests`, `ScrollingHeaderControllerTests`, `TableCellTests`, `PerDocumentUndoTests`, `HeightBehaviorTests`) are view-coupled and stay macOS-gated until their subsystems port.
- **Manual smoke test** in the iOS Simulator (`build_run_sim`): type a doc with headings, `- ` bullets, `- [ ]` checkboxes, a fenced code block, `$x^2$` LaTeX, and a blockquote; confirm live styling, bullet enlargement, checkbox tap-toggle, Dynamic Type scaling, keyboard-avoidance, and caret/selection behave.

## Acceptance checklist (sign-off gate)

- [x] **Pre-flight:** both SPM deps clear iOS 16 — HighlighterSwift 3.1.0 (`.iOS(.v13)`), SwiftMath 1.7.3 (`.iOS(.v11)`). *(verified 2026-06-26)*
- [x] `Package.swift` floor set to `.iOS(.v16)`. *(Phase 0)*
- [x] **Phase 0.5 spike: Path A (coordinate/flip) passed** — off-screen render on iPhone 17 Pro / iOS 26.5; `UIGraphicsPushContext` + unchanged macOS math renders upright, no flip transform. *(verified 2026-06-26 — scope-limited; see the gaps below)*
- [ ] **Re-run the spike on an iOS 16 simulator** (the floor; 26.5 ≠ 16) before treating the coordinate thesis as proven for the minimum target. *(BLOCKED in the current environment — no iOS 16 runtime installed; only 18.3/18.4/18.6/26.5. Needs an iOS 16 sim or device.)*
- [x] **Spike the real `UITextView(usingTextLayoutManager:)` path** — done. A custom `NSTextLayoutFragment` installed via `UITextView.textLayoutManager?.delegate`, rendered through the *view's own* draw path, **PNG-verified** on iPhone 17 Pro / iOS 26.5: `renderingSurfaceBounds` clipping is **real** (control pass clips both a full-width background and a left-gutter bar), and production's surface expansion defeats it exactly as intended. *(verified 2026-06-26 — iOS 26.5 only; see Phase 0.5 addendum for scope/caveats)*
- [x] Helper-level port done: injected config/theme via `MarkdownFragmentContext` (no `NativeTextView` cast), selection abstracted (macOS `selectedRanges` → protocol; iOS `selectedTextRange` feeds it in Phase 2), `displayScale` pixel-snap, UIColor color-space (`rgbComponents`) — across all 6 draw helpers. *(Phase 1, harness-verified on iOS 26.5 2026-06-26; the in-place file iOS-compiles only once Phase 2 un-gates the target.)*
- [x] Real **SwiftMath→`UIImage`** LaTeX round-trip renders upright on iOS. *(Bridge port: `SwiftMathBridge` is cross-platform; the iOS demo renders inline `$E=mc^2$` and block `$$\int…$$` correctly — screenshot-verified on iOS 26.5. Syntax highlighting via `HighlighterSwiftBridge` also ported and verified (atom-one-dark colors).)*
- [x] **App Store private-API assessment** for `extraLineFragmentAttributes` complete; fallback decided. *(Phase 2b: gated `#if os(macOS)`; verified ABSENT from the built iOS binary via `strings`. iOS uses the no-op fallback — trailing-metrics degradation accepted/tracked.)*
- [x] **RTL decision** made — **documented defer** for MVP: gutter-drawn blockquote bars and bullets stay at the left gutter on iOS (no mirroring). Re-enablement is a Phase 4 backlog row. *(Phase 2b)*
- [ ] No phase altered macOS runtime behavior (each merge unit reviewed as inert on macOS).
- [ ] No `effectiveAppearance` / `NSApp` reference remains in the shared core; color scheme threaded via `StylingContext`.
- [ ] Every starred subsystem (Writing Tools, autocorrect, `NSApp.currentEvent`, `setMarkedText`, undo) has its decision implemented or explicitly `#if os(macOS)`-gated.
- [x] `extraLineFragmentAttributes` acceptance test passes on iOS, or degraded state consciously signed off. *(Phase 2b: degraded state consciously signed off — the private selector is gated off iOS; trailing-line-spacing drift at document end is accepted and tracked.)*
- [ ] IME named cases pass (kana→kanji, Pinyin, emoji/dictation, undo-during-marked-text).
- [~] Per-keystroke restyle < 16 ms on a low-end device for a multi-page doc. *(Phase 2b: measured ~16.75 ms for a worst-case full-document restyle of a ~13k-char doc in the **simulator** — at budget. Small/typical docs are well under. Open items: paragraph-scoped restyle for large docs, and a real low-end **device** measurement.)*
- [ ] iOS test scheme runs in CI and is green; the 6 platform-pure suites (+ `MarkdownASTStylerTests` post-alias) pass on iOS.
- [x] Dynamic Type + keyboard-avoidance. *(Phase 2b: Dynamic Type via `UIFontMetrics` — verified scaling in the simulator at XXXL; keyboard-avoidance implemented (bottom inset from keyboard frame) — build-verified, interactive focus not automatable here.)*
- [ ] Every remaining `#if os(macOS)` gate has a Phase 4 un-defer backlog row.
