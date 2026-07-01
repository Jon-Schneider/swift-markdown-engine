//
//  MarkdownUITextView.swift
//  MarkdownEngine
//
//  iOS Markdown view (Phase 2a read-only → Phase 2b editable). A `UITextView` on a
//  TextKit-2 stack whose layout-manager delegate installs the cross-platform
//  `MarkdownTextLayoutFragment`; the view is the fragment's `MarkdownFragmentContext`.
//
//  Phase 2b adds: editing with live restyle, the shared list/blockquote/indent/
//  auto-pair input behaviors (via `MarkdownLists.computeListInsertion`), and
//  tap-to-toggle task checkboxes. Out of scope (later passes): marked-text/IME,
//  autocorrect lifecycle, paste, context menus, link taps, undo integration.
//

#if canImport(UIKit)
import UIKit

public final class MarkdownUITextView: UITextView {

    public var configuration: MarkdownEditorConfiguration
    public var fontName: String
    public var fontSize: CGFloat

    /// Resolved base body font (updated on each restyle). Part of `MarkdownFragmentContext`.
    public var baseFont: PlatformFont
    /// TextKit-2 measurement bridge. Part of `MarkdownFragmentContext`.
    /// Internal: `LayoutBridge` is an internal type, so this can't be `public`.
    var layoutBridge: LayoutBridge?

    /// The storage-form Markdown last loaded from outside (so the SwiftUI wrapper
    /// re-renders only on a genuine external change, never wiping in-place edits).
    public private(set) var lastRenderedSource: String?

    /// Called when the user's edits change the document, with the text in STORAGE
    /// form (wiki-links re-encoded to `[[Name|id]]`). Lets the SwiftUI host persist
    /// edits — without it, edits would live only inside the view and be lost.
    public var onTextChange: ((String) -> Void)?
    /// Called when the user taps a link (markdown link, auto-detected URL, or
    /// wiki-link whose id parses as a URL). Lets the host open/navigate it.
    public var onLinkTap: ((URL) -> Void)?
    /// Called whenever the formatting active at the selection may have changed (caret move
    /// or edit), so a host toolbar can reflect it. Wired by `MarkdownEditorController`.
    var onSelectionStateChange: ((MarkdownSelectionState) -> Void)?
    /// Called when the inline link under the caret changes (entered / left / edited), so the
    /// host can show a link-edit affordance. Wired by `MarkdownEditorController`.
    var onInlineLinkContextChange: ((InlineLinkContext?) -> Void)?
    /// Called when the `/` slash-command context at the caret changes (opened / filtered / closed),
    /// so the host can show the block-insert menu. Wired by `MarkdownEditorController`.
    var onSlashMenuContextChange: ((SlashMenuContext?) -> Void)?
    /// Called when an image is pasted, with the image's PNG bytes. The host persists it
    /// however it likes and returns a path/URL to reference (or nil to decline and fall
    /// back to the default paste); the editor then inserts `![](returnedPath)`.
    public var onPasteImage: ((Data) -> String?)?
    private var wikiLinkMetadata: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata] = [:]

    // Retained TextKit-2 stack pieces (the container/layout-manager back-refs are weak).
    private let contentStorage: NSTextContentStorage
    private var markdownLayoutDelegate: MarkdownLayoutManagerDelegate?

    private var lastInterfaceStyle: UIUserInterfaceStyle = .unspecified
    private var lastContentSizeCategory: UIContentSizeCategory = .unspecified
    /// Suppresses delegate re-entrancy while we mutate storage / set text ourselves.
    private var isApplyingProgrammaticEdit = false
    /// Active token set from the last restyle — selection changes only restyle when it shifts.
    private var lastActiveTokens: Set<Int> = []
    /// Token cache keyed by exact text, so caret moves don't re-parse an unchanged document.
    private var tokenCache: (text: String, tokens: [MarkdownToken])?
    /// Rendered-height cache for revealed standalone blocks (plan 1.2) — lets a revealed `$$…$$`
    /// block reserve its formula's height so the content below doesn't jump on caret entry/exit.
    private let blockRenderHeightCache = BlockRenderHeightCache()

    // MARK: Incremental (paragraph-scoped) restyle state
    /// Post-edit range of the change captured in `shouldChangeTextIn`, consumed by
    /// `textViewDidChange` to scope the restyle to the edited paragraph(s).
    private var pendingEditedRange: NSRange?
    /// Active-token set *before* the pending edit — so a token whose active state flips
    /// across the edit (e.g. the caret leaving a `**bold**` span) restyles both states.
    private var pendingPreEditActiveTokens: Set<Int>?
    /// Caret location at the last restyle; the paragraph the caret *left* needs restyling
    /// too (to re-hide markers it had revealed).
    private var previousCaretLocation: Int?
    /// Reentrancy guard: snapping the caret out of a hidden marker sets
    /// `selectedRange`, which re-enters `textViewDidChangeSelection`.
    private var isSnappingSeamlessCaret = false
    /// ``` fence count at the last restyle. A change means a code block opened/closed,
    /// which can re-tokenize large regions, so the edit path falls back to a full restyle.
    private var previousBacktickCount = 0

    // MARK: Wide-table horizontal-scroll overlays (see MarkdownTableScrollView.swift)
    /// Live overlay scroll views, keyed by the table's content `sourceID`.
    var tableScrollOverlays: [Int: MarkdownTableScrollView] = [:]
    /// Per-`sourceID` horizontal scroll offset, persisted across restyles so a table
    /// keeps its scroll position when the document re-styles around it.
    var tableHorizontalScrollOffsets: [Int: CGFloat] = [:]
    /// Coalesces overlay reconciles to one per runloop tick (mirrors the macOS path).
    var pendingTableScrollOverlayUpdate = false
    /// Last laid-out width; a change means a rotation/resize, which re-styles so each
    /// table's reserved display width (baked at style time) tracks the new container.
    private var lastLayoutWidth: CGFloat = -1

    public init(
        configuration: MarkdownEditorConfiguration = .default,
        fontName: String = "SF Pro",
        fontSize: CGFloat = 16,
        isEditable: Bool = true
    ) {
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.baseFont = PlatformFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        self.contentStorage = contentStorage

        super.init(frame: .zero, textContainer: container)

        // Host-controlled read-only mode (macOS `NativeTextViewWrapper.isEditable` parity).
        // `false` blocks typing outright; the styling suppression + mutation gate below make
        // a read-only document render as clean styled text with tappable-but-immutable content.
        // Note the platform divergence: macOS must set `insertionPointColor = .clear` because a
        // selectable-but-non-editable NSTextView still blinks a caret. UITextView does NOT render
        // an insertion caret when `isEditable == false` (only long-press selection handles for
        // copy), so there is deliberately no iOS analog to clear.
        self.isEditable = isEditable
        isSelectable = true
        backgroundColor = .clear
        applyTextContainerInset()
        // Dynamic Type is applied manually by scaling the base size via UIFontMetrics
        // in `restyleInPlace` (our fonts aren't metrics-tracking), so the system's own
        // auto-adjust would double-count — leave it off.
        adjustsFontForContentSizeCategory = false
        // Autocorrect (and its marked-text suggestion bar) is fine now that restyle
        // is guarded against active marked text. But Markdown is plain text, so keep
        // smart quotes/dashes/substitutions OFF — curly quotes and em-dashes would
        // corrupt code, links, and `--`/`...` syntax.
        autocorrectionType = .default
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        // System find/replace UI (iOS 16+). The built-in find runs a substring scan
        // over `textStorage`, which holds DISPLAY text: in seamless mode the Markdown
        // markers are still real characters but rendered zero-width *in place*, and
        // wiki-links keep their `[[ ]]` brackets (only the `|id` is dropped from the
        // buffer). Consequences:
        //  - a SINGLE visible token highlights correctly — markers don't shift the
        //    glyphs, so the highlight lands on the rendered text (verified live);
        //  - KNOWN LIMITATION: a query that SPANS a hidden marker finds nothing
        //    (e.g. "editable view" across `**editable** view`, or "See Page" across
        //    `See [[Page]]`), because the marker chars sit between the words in the
        //    haystack;
        //  - KNOWN LIMITATION: a query INSIDE a hidden run (an inline link's
        //    `](url)` tail, image/LaTeX source) matches a zero-width position →
        //    invisible highlight.
        // A correct fix needs a custom `UITextSearching` over marker-stripped text
        // wired through a bespoke `UIFindInteraction` (UITextView's own
        // `performTextSearch` is not `open`, so it can't be overridden). Deferred —
        // see plan 2.2's downgrade note.
        isFindInteractionEnabled = true
        delegate = self

        let layoutDelegate = MarkdownLayoutManagerDelegate()
        layoutDelegate.context = self
        markdownLayoutDelegate = layoutDelegate
        layoutManager.delegate = layoutDelegate
        layoutBridge = LayoutBridge(layoutManager)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardFrameWillChange(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Keyboard avoidance

    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard isFirstResponder,
              let endFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let space = window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
        let keyboardInView = convert(endFrame, from: space)
        let overlap = bounds.intersection(keyboardInView)
        let bottomInset = overlap.isNull ? 0 : overlap.height
        contentInset.bottom = bottomInset
        verticalScrollIndicatorInsets.bottom = bottomInset
        if let range = selectedTextRange {
            scrollRectToVisible(caretRect(for: range.end), animated: true)
        }
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        contentInset.bottom = 0
        verticalScrollIndicatorInsets.bottom = 0
    }

    // MARK: - Find / replace (system UI)

    /// Present the system find (or find-and-replace) navigator over this editor
    /// (iOS 16+ `UIFindInteraction`). The editor becomes first responder first so
    /// the navigator attaches; on iPad with a hardware keyboard ⌘F also triggers it
    /// natively. Hosts call this from a toolbar button (iPhone has no ⌘F).
    public func presentFind(showingReplace: Bool) {
        if !isFirstResponder { becomeFirstResponder() }
        // Never offer Replace on a read-only document, even if the host asked for it.
        findInteraction?.presentFindNavigator(showingReplace: showingReplace && isEditable)
    }

    // MARK: - Loading

    /// Load `storageText` (storage form) and style it. Resets the document, so this
    /// is for initial / external content — in-place edits go through the delegate.
    public func render(markdown storageText: String) {
        lastRenderedSource = storageText
        applyTextContainerInset()            // configuration may have changed with the text
        // Document reset: drop the previous doc's wide-table overlays synchronously (so they
        // don't paint over the new content for a frame) and its persisted scroll offsets (so
        // a new table that hashes to an old sourceID doesn't inherit a stale scroll position).
        removeAllTableScrollOverlays()
        tableHorizontalScrollOffsets.removeAll()
        let displayState = WikiLinkService.makeDisplayState(from: storageText)
        wikiLinkMetadata = displayState.metadata
        isApplyingProgrammaticEdit = true
        text = displayState.display          // plain text; restyleInPlace adds the styling
        isApplyingProgrammaticEdit = false
        restyleInPlace()
        // Republish host state after an (external) load so the toolbar / link context reflect
        // the new document, deferred out of any SwiftUI view-update cycle.
        DispatchQueue.main.async { [weak self] in self?.publishHostStateNow() }
    }

    /// Convert the current (display-form) text back to storage form and notify the
    /// host via `onTextChange` if it changed. `makeStorageState` is a pass-through
    /// when the document has no wiki-links. Updates `lastRenderedSource` so the
    /// wrapper's `updateUIView` doesn't re-render (and reset the caret) on the echo.
    private func emitStorageTextIfChanged() {
        let storageState = WikiLinkService.makeStorageState(
            from: textStorage.string, existingMetadata: wikiLinkMetadata, textStorage: textStorage
        )
        wikiLinkMetadata = storageState.metadata
        guard storageState.storage != lastRenderedSource else { return }
        lastRenderedSource = storageState.storage
        onTextChange?(storageState.storage)
    }

    /// Re-apply configuration-derived state (insets + styling) without changing the
    /// text — used by the SwiftUI wrapper when only `configuration` changes (e.g. a
    /// new theme or syntax highlighter) so the displayed attributes don't go stale.
    public func reapplyConfiguration() {
        applyTextContainerInset()
        // Entering seamless (e.g. a runtime toggle) with the caret already inside
        // a now-hidden marker must pull it to the visible content, else the next
        // keystroke lands before the marker and breaks the block. Idempotent and
        // line-scoped, so it's safe to run on every config apply. Skipped when read-only:
        // an inert view has no "next keystroke" to protect, and must not silently move
        // the user's selection (macOS never snaps a non-editable caret either).
        if isEditable, configuration.markers.visibility == .seamless, selectedRange.length == 0,
           !isSnappingSeamlessCaret {
            let proposed = selectedRange.location
            let snapped = MarkdownSeamlessInput.normalizedCaret(
                text: textStorage.string, proposed: proposed,
                previous: proposed, configuration: configuration
            )
            if snapped != proposed {
                isSnappingSeamlessCaret = true
                selectedRange = NSRange(location: snapped, length: 0)
                isSnappingSeamlessCaret = false
            }
        }
        restyleInPlace()
    }

    /// Publish the host-facing selection state (toolbar) + inline-link context (link editor)
    /// for the current selection. Cheap — reuses the cached token parse.
    private func publishHostState() {
        guard onSelectionStateChange != nil || onInlineLinkContextChange != nil else { return }
        let display = textStorage.string
        publishHostState(display: display, tokens: tokens(for: display))
    }

    /// Same, reusing tokens the caller already parsed (avoids a second cache lookup).
    private func publishHostState(display: String, tokens: [MarkdownToken]) {
        onSelectionStateChange?(MarkdownFormatting.selectionState(
            text: display, selection: selectedRange, tokens: tokens
        ))
        onInlineLinkContextChange?(inlineLinkContext(tokens: tokens, display: display))
        onSlashMenuContextChange?(slashMenuContext(display: display))
    }

    /// The `/` slash-command context for the caret, or nil. Only a zero-length caret triggers it
    /// (typing, not a selection); the menu opens on a `/` at line start or after whitespace.
    private func slashMenuContext(display: String) -> SlashMenuContext? {
        // No block-insert menu on a read-only document (a caret parked on a literal `/foo`
        // must not offer to insert). Editing is blocked anyway; this keeps the host UI honest.
        guard isEditable,
              selectedRange.length == 0,
              let trigger = MarkdownSlashMenu.trigger(in: display, caret: selectedRange.location)
        else { return nil }
        return SlashMenuContext(
            query: trigger.query, sourceRange: trigger.sourceRange, anchorRect: caretAnchorRect()
        )
    }

    /// Force-publish host state now (the controller calls this on attach so freshly-shown
    /// host UI isn't stale).
    func publishHostStateNow() { publishHostState() }

    // MARK: - Inline links

    /// Whether a zero-or-more-length selection sits within `range` (inclusive of the edges).
    private func selectionEnclosed(by range: NSRange) -> Bool {
        selectedRange.location >= range.location && NSMaxRange(selectedRange) <= NSMaxRange(range)
    }

    /// The inline-link context for the caret, or nil. (Markdown links for now; wiki-links
    /// are a follow-up slice.)
    private func inlineLinkContext(tokens: [MarkdownToken], display: String) -> InlineLinkContext? {
        // The inline-link context exists only to offer a link-EDIT affordance; a read-only
        // document refuses the edit (`updateLinkAtCaret` → `applyUndoableEdit` no-ops), so
        // never advertise it. Link *navigation* (tap) is a separate path and still works.
        guard isEditable else { return nil }
        guard let token = tokens.first(where: { $0.kind == .link && selectionEnclosed(by: $0.range) }) else {
            return nil
        }
        let ns = display as NSString
        let source = ns.substring(with: token.range)
        return InlineLinkContext(
            kind: .markdownLink,
            text: ns.substring(with: token.contentRange),
            target: Self.markdownLinkURL(from: source) ?? "",
            sourceRange: token.range,
            anchorRect: caretAnchorRect()
        )
    }

    /// Caret rect in WINDOW coordinates, for anchoring a host popover/overlay. Window space (not
    /// the text view's content space) is what a SwiftUI host needs: it positions an overlay in
    /// `.global` coordinates, which already accounts for the editor's on-screen origin and the
    /// scroll offset (`caretRect(for:)` alone is in scrolled content space). Falls back to the raw
    /// caret rect if the view isn't yet in a window.
    ///
    /// Caveat: SwiftUI `.global` equals the UIKit window only when the host fills the window. In a
    /// sheet/popover/Stage-Manager-inset host, map this rect through a known UIView's window rather
    /// than assuming the two origins coincide. Note this is a snapshot taken at publish time (on
    /// selection/text change), so it can lag a manual scroll while the menu stays open.
    private func caretAnchorRect() -> CGRect {
        guard let position = selectedTextRange?.start else { return .zero }
        let rect = caretRect(for: position)
        return window == nil ? rect : convert(rect, to: nil)
    }

    /// Extract the URL from a `[text](url)` source (the run between the last `](` and the
    /// trailing `)`), tolerant of brackets in the link text.
    static func markdownLinkURL(from linkSource: String) -> String? {
        guard linkSource.hasSuffix(")"),
              let open = linkSource.range(of: "](", options: .backwards) else { return nil }
        let urlStart = open.upperBound
        let urlEnd = linkSource.index(before: linkSource.endIndex)
        return urlStart <= urlEnd ? String(linkSource[urlStart..<urlEnd]) : ""
    }

    /// Insert `[text](url)` at the selection. A non-empty selection becomes the link text.
    func insertMarkdownLink(text: String?, url: String) {
        let ns = textStorage.string as NSString
        let selection = selectedRange
        let linkText: String
        if selection.length > 0 {
            linkText = ns.substring(with: selection)
        } else if let text, !text.isEmpty {
            linkText = text
        } else {
            linkText = url.isEmpty ? "link" : url
        }
        let markdown = "[\(linkText)](\(url))"
        let caret = selection.location + (markdown as NSString).length
        applyUndoableEdit(replacing: selection, with: markdown, finalSelection: NSRange(location: caret, length: 0))
    }

    /// Replace the markdown link the caret is in with `[text](url)`. No-op if not in a link.
    func updateMarkdownLinkAtCaret(text: String, url: String) {
        let display = textStorage.string
        guard let token = tokens(for: display).first(where: { $0.kind == .link && selectionEnclosed(by: $0.range) }) else {
            return
        }
        let markdown = "[\(text)](\(url))"
        let caret = token.range.location + (markdown as NSString).length
        applyUndoableEdit(replacing: token.range, with: markdown, finalSelection: NSRange(location: caret, length: 0))
    }

    private func applyTextContainerInset() {
        let insets = configuration.textInsets
        textContainerInset = UIEdgeInsets(
            top: insets.vertical, left: insets.horizontal,
            bottom: insets.vertical, right: insets.horizontal
        )
    }

    // MARK: - Undoable edits

    private func uiTextRange(for nsRange: NSRange) -> UITextRange? {
        guard let start = position(from: beginningOfDocument, offset: nsRange.location),
              let end = position(from: start, offset: nsRange.length) else { return nil }
        return textRange(from: start, to: end)
    }

    /// Apply a programmatic replacement through `UITextInput` so the system's undo
    /// manager records it. Direct `textStorage` mutation would leave the undo stack's
    /// recorded ranges pointing at stale offsets — a later undo can then replay against
    /// a shifted document and raise `NSRangeException`. Restyles once afterward.
    private func applyUndoableEdit(replacing nsRange: NSRange, with string: String, finalSelection: NSRange?) {
        // Read-only documents accept NO programmatic mutation — this is the single choke point
        // for every edit (formatting, link/slash inserts, checkbox toggle, blockquote paste, cut),
        // the iOS analog of macOS gating each edit behind `shouldChangeText(in:)` (which returns
        // false when `!isEditable`). Loading content via `render()` bypasses this path, so a
        // read-only view still displays its document; only in-place edits are refused.
        guard isEditable else { return }
        guard let range = uiTextRange(for: nsRange) else { return }
        isApplyingProgrammaticEdit = true
        replace(range, withText: string)
        // `replace` parks the caret at the end of the inserted text; restore the
        // intended selection BEFORE restyling so the styler resolves marker
        // reveal/hide against the right caret (e.g. a checkbox toggle must not leave
        // the caret inside the box, which would suppress the rendered glyph).
        if let finalSelection, let selRange = uiTextRange(for: finalSelection) {
            selectedTextRange = selRange
            // Sync the seamless caret-normalization baseline to this programmatic caret move.
            // Otherwise `previousCaretLocation` keeps the PRE-edit caret, and a deferred
            // selection-change reads the new caret (which the edit may have shifted left as the
            // document shrank) as a leftward arrow step at a block's content start — escaping the
            // caret to the previous line. Surfaced by merge-up-over-blank-line Backspace and
            // heading slash-inserts, where the final caret lands at a hidden marker's content start.
            previousCaretLocation = finalSelection.location
        }
        isApplyingProgrammaticEdit = false
        restyleInPlace()
        emitStorageTextIfChanged()
        publishHostState()
    }

    /// Move the collapsed caret to `location` with NO text change (table grid
    /// navigation). Setting `selectedRange` drives `textViewDidChangeSelection`,
    /// which restyles the reveal/hide as the caret enters/leaves a cell or exits the
    /// table — so no explicit restyle is needed here. `previousCaretLocation` is
    /// synced first so the seamless caret-normalization there reads no phantom
    /// directional step (the target is already inside the revealed table, where
    /// `normalizedCaret` doesn't snap anyway, but this keeps the baseline honest).
    private func moveCaretProgrammatically(to location: Int) {
        let clamped = max(0, min(location, (textStorage.string as NSString).length))
        previousCaretLocation = clamped
        selectedRange = NSRange(location: clamped, length: 0)
    }

    // MARK: - Styling

    /// Base body size scaled for the current Dynamic Type setting. All derived sizes
    /// (headings, code, checkbox metrics) are computed relative to it by the styler,
    /// so scaling the base propagates everywhere.
    private func scaledFontSize() -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: fontSize, compatibleWith: traitCollection)
    }

    /// Caret index handed to the styler. Read-only documents pass `-1` (no caret) so a
    /// tap/selection never reveals the raw token syntax under the caret — mirrors the macOS
    /// restyle (`caretLocation = isEditable ? selectedRange().location : -1`).
    private var stylingCaretLocation: Int { isEditable ? selectedRange.location : -1 }

    private func tokens(for display: String) -> [MarkdownToken] {
        if let cache = tokenCache, cache.text == display { return cache.tokens }
        let parsed = MarkdownTokenizer.parseTokensViaAST(in: display)
        tokenCache = (display, parsed)
        return parsed
    }

    /// Re-apply Markdown styling to the current text as ATTRIBUTE edits only — the
    /// string and the selection are untouched, so the caret stays put. Mirrors the
    /// macOS restyle (`beginEditing`/`setAttributes`/`addAttribute`/`endEditing`).
    private func restyleInPlace() {
        let display = textStorage.string
        let ns = display as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let effectiveFontSize = scaledFontSize()
        lastContentSizeCategory = traitCollection.preferredContentSizeCategory

        let (resolvedBaseFont, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName, fontSize: effectiveFontSize, layoutBridge: layoutBridge, configuration: configuration
        )
        baseFont = resolvedBaseFont
        let baseAttributes = TextStylingService.makeBaseTypingAttributes(
            font: resolvedBaseFont, paragraphStyle: paragraph, theme: configuration.theme
        )
        typingAttributes = baseAttributes

        let parsed = tokens(for: display)
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: selectedRange, tokens: parsed, in: ns,
            suppressed: !isEditable,
            markerVisibility: configuration.markers.visibility
        )
        lastActiveTokens = active

        let styled = MarkdownStyler.styleAttributes(
            text: display, fontName: fontName, fontSize: effectiveFontSize, layoutBridge: layoutBridge,
            caretLocation: stylingCaretLocation, activeTokenIndices: active,
            precomputedTokens: parsed,
            colorScheme: MarkdownColorScheme.resolved(from: traitCollection),
            configuration: configuration,
            blockRenderHeightCache: blockRenderHeightCache
        )

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes, range: fullRange)
        for (range, attrs) in styled {
            let clipped = NSIntersectionRange(range, fullRange)
            guard clipped.length > 0 else { continue }
            for (key, value) in attrs { textStorage.addAttribute(key, value: value, range: clipped) }
        }
        textStorage.endEditing()

        // Resync the incremental-restyle bookkeeping so the next scoped pass measures
        // against this fully-styled state.
        previousBacktickCount = ParagraphRestyleScoping.backtickFenceCount(in: display)
        previousCaretLocation = selectedRange.location

        // Reconcile the wide-table scroll overlays against the freshly-styled storage
        // (creates / repositions / removes them to match the `.scrollableBlock*` attrs).
        updateTableScrollOverlays()
    }

    /// Incremental restyle: re-style only `paragraphCandidates` (and their styled spans),
    /// leaving the rest of the document's attributes untouched. This is the per-keystroke
    /// path — full-document `restyleInPlace()` stays the fallback for loads / config /
    /// trait / width changes. Mirrors the macOS `TextStylingService.restyle` apply loop.
    private func restyleScoped(paragraphCandidates: [NSRange]) {
        let display = textStorage.string
        let ns = display as NSString
        let paragraphs = ParagraphRestyleScoping.normalize(paragraphCandidates, documentLength: ns.length)
        // No usable scope (e.g. empty document) → fall back to a full restyle.
        guard !paragraphs.isEmpty else { restyleInPlace(); return }

        let effectiveFontSize = scaledFontSize()
        lastContentSizeCategory = traitCollection.preferredContentSizeCategory

        let (resolvedBaseFont, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName, fontSize: effectiveFontSize, layoutBridge: layoutBridge, configuration: configuration
        )
        baseFont = resolvedBaseFont
        let baseAttributes = TextStylingService.makeBaseTypingAttributes(
            font: resolvedBaseFont, paragraphStyle: paragraphStyle, theme: configuration.theme
        )
        typingAttributes = baseAttributes

        let parsed = tokens(for: display)
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: selectedRange, tokens: parsed, in: ns,
            suppressed: !isEditable,
            markerVisibility: configuration.markers.visibility
        )
        lastActiveTokens = active

        // `scopedRanges` lets the AST styler skip out-of-scope work; the image/table passes
        // still run over all tokens but only get *applied* where they intersect a candidate.
        let styled = MarkdownStyler.styleAttributes(
            text: display, fontName: fontName, fontSize: effectiveFontSize, layoutBridge: layoutBridge,
            caretLocation: stylingCaretLocation, activeTokenIndices: active,
            precomputedTokens: parsed,
            scopedRanges: paragraphs,
            colorScheme: MarkdownColorScheme.resolved(from: traitCollection),
            configuration: configuration,
            blockRenderHeightCache: blockRenderHeightCache
        )

        textStorage.beginEditing()
        for paragraph in paragraphs {
            // Reset the paragraph to base, then re-apply the styled spans clipped to it.
            textStorage.setAttributes(baseAttributes, range: paragraph)
            textStorage.removeAttribute(.link, range: paragraph)
            for (range, attrs) in styled {
                let clipped = NSIntersectionRange(range, paragraph)
                guard clipped.length > 0 else { continue }
                for (key, value) in attrs { textStorage.addAttribute(key, value: value, range: clipped) }
            }
        }
        textStorage.endEditing()

        previousBacktickCount = ParagraphRestyleScoping.backtickFenceCount(in: display)
        updateTableScrollOverlays()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Width only changes on rotation / multitasking resize (vertical scrolling moves
        // bounds.origin, not bounds.size), so this guard keeps per-frame scroll layout cheap.
        guard bounds.width != lastLayoutWidth else { return }
        lastLayoutWidth = bounds.width
        // The first real width (and any later change) must re-style: the initial render
        // may have run pre-layout with a fallback container width, and a table's reserved
        // display width / wide-vs-narrow classification depends on the true width.
        // restyleInPlace() ends by reconciling overlays.
        if lastRenderedSource != nil { restyleInPlace() }
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard lastRenderedSource != nil else { return }
        // Re-style on a light/dark flip (themed colors) or a Dynamic Type change
        // (rescaled fonts). restyleInPlace re-reads both from the trait collection.
        let styleChanged = traitCollection.userInterfaceStyle != lastInterfaceStyle
        let sizeChanged = traitCollection.preferredContentSizeCategory != lastContentSizeCategory
        if styleChanged || sizeChanged {
            lastInterfaceStyle = traitCollection.userInterfaceStyle
            restyleInPlace()
        }
    }

    // MARK: - Paste

    /// Pasting multiple lines while the caret sits on a blockquote line prefixes the
    /// continuation lines with that line's `>` markers, so the whole paste stays in
    /// the quote (parity with the macOS editor). Plain pastes fall through to the system.
    public override func paste(_ sender: Any?) {
        guard isEditable else { super.paste(sender); return }
        // Image paste: hand the bytes to the host (which persists them) and insert the
        // returned reference as `![](path)`. Falls through to the default paste if there's
        // no image, no handler, or the host declines (returns nil).
        if onPasteImage != nil, UIPasteboard.general.hasImages,
           let data = UIPasteboard.general.image?.pngData(),
           insertPastedImage(data) {
            return
        }
        // Multi-line text paste inside a blockquote → keep the quote markers.
        guard let pasted = UIPasteboard.general.string, pasted.contains("\n") else {
            super.paste(sender)
            return
        }
        let transformed = MarkdownLists.blockquoteContinuedPaste(pasted, at: selectedRange.location, in: text)
        guard transformed != pasted else {
            super.paste(sender)
            return
        }
        let insertLocation = selectedRange.location
        applyUndoableEdit(
            replacing: selectedRange, with: transformed,
            finalSelection: NSRange(location: insertLocation + (transformed as NSString).length, length: 0)
        )
    }

    // Seamless copy/cut place the *visible* text on the pasteboard (hidden markers
    // stripped); outside seamless the system default copies the raw source.
    //
    // KNOWN RAW-SOURCE LEAK PATHS (intentionally NOT intercepted): only `copy`/`cut`
    // are overridden, so other UIKit text-export paths still emit the raw buffer —
    // drag-and-drop (`UITextDraggable` / `itemsForBeginning`), the Share sheet, and
    // any host-driven `text`/`attributedText` read. Accepted scope boundary for the
    // "copy visible text" item (drag/Share aren't "copy"); route them through
    // `MarkdownSeamlessInput.visibleText` if a future requirement needs them covered.
    public override func copy(_ sender: Any?) {
        guard configuration.markers.visibility == .seamless, selectedRange.length > 0 else {
            super.copy(sender)
            return
        }
        UIPasteboard.general.string = MarkdownSeamlessInput.visibleText(
            of: selectedRange, in: text, configuration: configuration
        )
    }

    public override func cut(_ sender: Any?) {
        let range = selectedRange
        guard configuration.markers.visibility == .seamless, range.length > 0 else {
            super.cut(sender)
            return
        }
        UIPasteboard.general.string = MarkdownSeamlessInput.visibleText(
            of: range, in: text, configuration: configuration
        )
        applyUndoableEdit(replacing: range, with: "",
                          finalSelection: NSRange(location: range.location, length: 0))
    }

    /// Hand `imageData` to the host's `onPasteImage`; if it returns a reference, insert
    /// `![](reference)` at the selection through the undoable edit path. Returns whether an
    /// image was inserted. Internal so tests can exercise it without the pasteboard.
    @discardableResult
    func insertPastedImage(_ imageData: Data) -> Bool {
        guard let onPasteImage, let reference = onPasteImage(imageData), !reference.isEmpty else {
            return false
        }
        let markdown = "![](\(reference))"
        let insertLocation = selectedRange.location
        applyUndoableEdit(
            replacing: selectedRange, with: markdown,
            finalSelection: NSRange(location: insertLocation + (markdown as NSString).length, length: 0)
        )
        return true
    }

    // MARK: - Formatting commands

    /// Insert a slash-menu `block`, replacing the `/query` at `sourceRange`. Single-undo.
    func insertSlashBlock(_ block: MarkdownBlockInsert, replacing sourceRange: NSRange) {
        let edit = MarkdownSlashMenu.insertEdit(block, replacing: sourceRange, in: text)
        // `insertEdit` returns an identity no-op for an invalid/stale range; skip it so the public
        // `insertBlock(replacing:)` API truly does nothing (no caret jump to EOF, no undo step)
        // rather than applying an empty replacement. Mirrors `applyFormatting` and the macOS guard.
        if isIdentity(edit) { return }
        applyUndoableEdit(replacing: edit.range, with: edit.text, finalSelection: edit.selection)
    }

    /// Apply a formatting command to `range` via the undoable edit path.
    func applyFormatting(_ command: MarkdownFormattingCommand, in range: NSRange) {
        let edit = MarkdownFormatting.edit(for: command, text: text, selection: range)
        // Skip an identity edit (e.g. Clear Formatting with nothing to clear) so it doesn't
        // push a spurious undo step or force a redundant restyle. Mirrors the macOS guard.
        if isIdentity(edit) { return }
        applyUndoableEdit(replacing: edit.range, with: edit.text, finalSelection: edit.selection)
    }

    /// Whether `edit` would replace a range with exactly its current contents (a no-op). Applied
    /// to every command (not just the new ones): no command produces a text-identical edit that
    /// only moves the caret, so a text-only comparison is sufficient and can't drop a real edit.
    private func isIdentity(_ edit: FormattingEdit) -> Bool {
        (text as NSString).substring(with: edit.range) == edit.text
    }

    fileprivate func formatAction(_ title: String, _ command: MarkdownFormattingCommand, _ range: NSRange) -> UIAction {
        let active = MarkdownFormatting.isActive(command, text: text, selection: range)
        var attributes: UIMenuElement.Attributes = []
        var state: UIMenuElement.State = .off
        switch command {
        case .bold, .italic, .strikethrough, .inlineCode, .blockquote, .codeBlock, .toggleCheckbox:
            state = active ? .on : .off                       // toggleable
        case .clearFormatting, .indent, .outdent:
            // Plain actions (never "on"), disabled when the edit would be an identity (nothing to
            // clear / off a list line / already at the root). Mirrors macOS `validateMenuItem`.
            if isIdentity(MarkdownFormatting.edit(for: command, text: text, selection: range)) {
                attributes.insert(.disabled)
            }
        default:
            if active { attributes.insert(.disabled) }        // heading/list: disabled once applied (macOS parity)
        }
        return UIAction(title: title, attributes: attributes, state: state) { [weak self] _ in
            self?.applyFormatting(command, in: range)
        }
    }

    // MARK: - Checkbox tap-toggle

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        // For a scroll view, `location(in: self)` is already in content coordinates
        // (bounds.origin == contentOffset).
        let point = recognizer.location(in: self)
        if toggleCheckbox(at: point) { return }   // checkbox wins
        handleLinkTap(at: point)
    }

    /// Open a `.link` at `point` (view coords) via `onLinkTap`. Makes links tappable
    /// even while editing (a plain tap otherwise just places the caret).
    private func handleLinkTap(at point: CGPoint) {
        guard let onLinkTap, let layoutBridge else { return }
        let containerPoint = CGPoint(x: point.x - textContainerInset.left,
                                     y: point.y - textContainerInset.top)
        var fraction: CGFloat = 0
        let index = layoutBridge.characterIndex(
            for: containerPoint, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index != NSNotFound, index < textStorage.length,
              let link = textStorage.attribute(.link, at: index, effectiveRange: nil) else { return }
        if let url = link as? URL {
            onLinkTap(url)
        } else if let string = link as? String, let url = URL(string: string) {
            onLinkTap(url)
        }
    }

    /// Toggle a task checkbox if `point` (in view coordinates) lands on one,
    /// flipping `[ ]`↔`[x]` in the source and restyling. Returns whether a
    /// checkbox was hit. Internal so iOS-simulator integration tests can drive it.
    @discardableResult
    func toggleCheckbox(at point: CGPoint) -> Bool {
        guard let layoutBridge else { return false }
        // The boundingRect hit-test needs current layout (a prior edit may have left
        // it dirty), otherwise the checkbox's rect comes back empty and we miss it.
        if let tlm = textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        let containerPoint = CGPoint(x: point.x - textContainerInset.left,
                                     y: point.y - textContainerInset.top)

        let fullRange = NSRange(location: 0, length: textStorage.length)
        var hitRange: NSRange?
        var hitIsChecked = false
        textStorage.enumerateAttribute(.taskCheckbox, in: fullRange, options: []) { value, attrRange, stop in
            guard let isChecked = value as? Bool else { return }
            if layoutBridge.boundingRect(forCharacterRange: attrRange, in: textContainer).contains(containerPoint) {
                hitRange = attrRange
                hitIsChecked = isChecked
                stop.pointee = true
            }
        }
        guard let effectiveRange = hitRange else { return false }
        let nsText = textStorage.string as NSString
        guard nsText.substring(with: effectiveRange).range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil else { return false }

        let replacement = hitIsChecked ? "[ ]" : "[x]"
        // Length-preserving ([ ]<->[x]) → the existing selection offsets stay valid.
        // Keep the caret where it was so the toggled box keeps rendering as a glyph.
        applyUndoableEdit(replacing: effectiveRange, with: replacement, finalSelection: selectedRange)
        return true
    }

    /// Force a restyle, optionally invalidating the token cache so it re-parses (the
    /// realistic per-keystroke cost). Internal for iOS-simulator perf measurement.
    func restyleNowForTesting(invalidatingCache: Bool = true) {
        if invalidatingCache { tokenCache = nil }
        restyleInPlace()
    }

    /// Force a paragraph-scoped restyle of the caret's paragraph (the realistic
    /// per-keystroke cost for an edit that doesn't cross a block boundary). Internal for
    /// iOS-simulator perf measurement against `restyleNowForTesting` (full document).
    func restyleScopedNowForTesting(invalidatingCache: Bool = true) {
        if invalidatingCache { tokenCache = nil }
        let ns = textStorage.string as NSString
        let caretLoc = min(selectedRange.location, ns.length)
        let caretParagraph = ns.paragraphRange(for: NSRange(location: caretLoc, length: 0))
        restyleScoped(paragraphCandidates: [caretParagraph])
    }

    /// Active-token set from the last restyle (the tokens whose markers are revealed).
    /// Internal for read-only suppression tests: a read-only document keeps this empty
    /// regardless of caret position, so no `**`/`_` markers ever show.
    var activeTokenIndicesForTesting: Set<Int> { lastActiveTokens }

    /// View-coordinate rect of the first task-checkbox glyph, if any. Internal for testing.
    func firstCheckboxBoundingRect() -> CGRect? {
        guard let layoutBridge else { return nil }
        var result: CGRect?
        textStorage.enumerateAttribute(.taskCheckbox, in: NSRange(location: 0, length: textStorage.length), options: []) { value, attrRange, stop in
            guard value is Bool else { return }
            result = layoutBridge.boundingRect(forCharacterRange: attrRange, in: textContainer)
                .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
            stop.pointee = true
        }
        return result
    }
}

// MARK: - UITextViewDelegate (editing + live restyle)

extension MarkdownUITextView: UITextViewDelegate {

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if isApplyingProgrammaticEdit { return true }
        // During IME composition (kana→kanji, Pinyin, dictation) the text is
        // provisional — let the input system drive it; don't run list logic on it. Clear any
        // pending scope state so an interleaved composition can't carry a stale edited range
        // into the next real edit (the resulting nil → full-restyle fallback is safe).
        if markedTextRange != nil {
            pendingEditedRange = nil
            pendingPreEditActiveTokens = nil
            return true
        }
        // Seamless mode: Backspace at an element's content start unwraps the
        // whole hidden marker in one edit. A backspace arrives as a single-char
        // deletion (`text` empty, `range.length == 1`) with no active selection.
        if configuration.markers.visibility == .seamless,
           text.isEmpty, range.length == 1, selectedRange.length == 0 {
            let caret = NSRange(location: NSMaxRange(range), length: 0)
            if case .replace(let replaceRange, let replaceText, let unwrapCaret) =
                MarkdownSeamlessInput.backspace(
                    currentText: textView.text, selection: caret, configuration: configuration
                ) {
                pendingEditedRange = nil
                pendingPreEditActiveTokens = nil
                applyUndoableEdit(replacing: replaceRange, with: replaceText,
                                  finalSelection: NSRange(location: unwrapCaret, length: 0))
                return false
            }
        }
        // Table grid navigation (plan 1.1): inside a table, Tab walks to the next
        // cell and Enter steps to the cell below / appends a row. Runs BEFORE list
        // handling, which also consumes "\t" (for indent). Outside a table the
        // handler returns `.allowDefault` and we fall through unchanged. (Shift-Tab
        // has no `shouldChangeTextIn` representation on iOS — it's macOS-only.)
        if range.length == 0, text == "\t" || text == "\n" {
            let tableDecision = (text == "\t")
                ? MarkdownTableHandler.tab(currentText: textView.text, selection: range, configuration: configuration)
                : MarkdownTableHandler.newline(currentText: textView.text, selection: range, configuration: configuration)
            switch tableDecision {
            case .allowDefault:
                break
            case .moveCaret(let loc):
                pendingEditedRange = nil
                pendingPreEditActiveTokens = nil
                moveCaretProgrammatically(to: loc)
                return false
            case .replace(let replaceRange, let replaceText, let caret):
                pendingEditedRange = nil
                pendingPreEditActiveTokens = nil
                applyUndoableEdit(replacing: replaceRange, with: replaceText,
                                  finalSelection: NSRange(location: caret, length: 0))
                return false
            }
        }
        switch MarkdownLists.computeListInsertion(
            currentText: textView.text, affectedCharRange: range,
            replacementString: text, configuration: configuration
        ) {
        case .allowDefault:
            // The system will insert; record what changed so textViewDidChange can scope
            // its restyle to the edited paragraph(s) instead of re-styling the whole doc.
            pendingEditedRange = NSRange(location: range.location, length: (text as NSString).length)
            pendingPreEditActiveTokens = lastActiveTokens
            return true
        case .block:
            pendingEditedRange = nil
            pendingPreEditActiveTokens = nil
            return false
        case .replace(let replaceRange, let replaceText, let caret):
            // Programmatic edits restyle themselves (full) via applyUndoableEdit; no pending.
            pendingEditedRange = nil
            pendingPreEditActiveTokens = nil
            applyUndoableEdit(replacing: replaceRange, with: replaceText,
                              finalSelection: NSRange(location: caret, length: 0))
            return false
        }
    }

    public func textViewDidChange(_ textView: UITextView) {
        if isApplyingProgrammaticEdit { return }
        // Don't restyle/emit mid-composition — mutating attributes on the marked
        // range fights the IME. textViewDidChange fires again when it commits.
        if markedTextRange != nil { return }
        restyleForEdit()
        emitStorageTextIfChanged()
        publishHostState()
    }

    /// Restyle after an ordinary edit, scoped to the affected paragraphs. Falls back to a
    /// full restyle when a ``` fence opened/closed (which can re-tokenize regions below).
    private func restyleForEdit() {
        let display = textStorage.string
        let ns = display as NSString

        // No captured edit range (IME commit, dictation — they bypass shouldChangeTextIn),
        // or a ``` fence boundary changed (re-tokenizes large regions): the change's extent
        // is unknown/large, so fall back to a full restyle rather than under-scope it.
        let fenceChanged = ParagraphRestyleScoping.backtickFenceCount(in: display) != previousBacktickCount
        guard let editedRange = pendingEditedRange, !fenceChanged else {
            pendingEditedRange = nil
            pendingPreEditActiveTokens = nil
            restyleInPlace()
            return
        }
        pendingEditedRange = nil

        let caretLoc = min(selectedRange.location, ns.length)
        let caretParagraph = ns.paragraphRange(for: NSRange(location: caretLoc, length: 0))
        var candidates = ParagraphRestyleScoping.caretNeighborhood(in: ns, caretParagraph: caretParagraph)
        candidates += ParagraphRestyleScoping.paragraphs(in: ns, intersecting: editedRange)

        let parsed = tokens(for: display)
        let current = MarkdownDetection.computeActiveTokenIndices(selectionRange: selectedRange, tokens: parsed, in: ns, suppressed: !isEditable, markerVisibility: configuration.markers.visibility)
        let preEdit = pendingPreEditActiveTokens ?? lastActiveTokens
        pendingPreEditActiveTokens = nil
        candidates += ParagraphRestyleScoping.renderedBlockParagraphs(in: ns, tokens: parsed)
        candidates += ParagraphRestyleScoping.tokenRestyleParagraphs(
            in: ns, tokens: parsed, currentActive: current, previousActive: preEdit
        )

        restyleScoped(paragraphCandidates: candidates)
        previousCaretLocation = selectedRange.location
    }

    /// Append a "Format" submenu (Bold / Italic / Heading / Lists) to the edit menu.
    public func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard isEditable else { return nil }
        let format = UIMenu(title: "Format", image: UIImage(systemName: "textformat"), children: [
            formatAction("Bold", .bold, range),
            formatAction("Italic", .italic, range),
            formatAction("Strikethrough", .strikethrough, range),
            formatAction("Inline Code", .inlineCode, range),
            UIMenu(title: "Heading", children: (1...3).map { formatAction("H\($0)", .heading($0), range) }),
            UIMenu(title: "Lists", children: [
                formatAction("Bullet", .bulletList, range),
                formatAction("Numbered", .numberedList, range),
                formatAction("Checkbox", .toggleCheckbox, range),
                formatAction("Indent", .indent, range),
                formatAction("Outdent", .outdent, range),
            ]),
            formatAction("Quote", .blockquote, range),
            formatAction("Code Block", .codeBlock, range),
            formatAction("Clear Formatting", .clearFormatting, range),
        ])
        return UIMenu(children: suggestedActions + [format])
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        if isApplyingProgrammaticEdit { return }
        if markedTextRange != nil { return }   // selection churns during composition
        // Seamless: pull a collapsed caret out of a hidden block marker's dead
        // zone so it rests at the visible content (not before/inside `> `/`# `).
        // Character motion itself stays native (grapheme-correct); this only
        // post-adjusts, and inspects just the caret's line (no document parse).
        // Read-only views skip it: there's no editing to protect and the promise is
        // that a selection the user makes is never silently moved (macOS parity).
        if isEditable,
           !isSnappingSeamlessCaret,
           configuration.markers.visibility == .seamless,
           selectedRange.length == 0 {
            let proposed = selectedRange.location
            let snapped = MarkdownSeamlessInput.normalizedCaret(
                text: textStorage.string, proposed: proposed,
                previous: previousCaretLocation ?? proposed, configuration: configuration
            )
            if snapped != proposed {
                isSnappingSeamlessCaret = true
                selectedRange = NSRange(location: snapped, length: 0)
                isSnappingSeamlessCaret = false
                previousCaretLocation = snapped
                return
            }
        }
        let display = textStorage.string
        let ns = display as NSString
        let parsed = tokens(for: display)
        let current = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: selectedRange, tokens: parsed, in: ns,
            suppressed: !isEditable,
            markerVisibility: configuration.markers.visibility
        )
        let previous = lastActiveTokens
        defer { previousCaretLocation = selectedRange.location }
        // Publish host state (toolbar + inline-link context) on every selection change
        // (formatting context can change — e.g. moving between a list line and a plain line,
        // or in/out of a link — without the active-token set shifting), reusing the tokens
        // already parsed above.
        publishHostState(display: display, tokens: parsed)

        // Reveal/hide markers as the caret enters/leaves an element. Restyle when the active
        // token set shifts OR when the caret crosses task-checkbox / thematic-break / bullet
        // syntax — those glyphs are caret-position-driven but are NOT tokens, so `current !=
        // previous` alone misses them (mirrors the macOS selection-change gate in
        // NativeTextViewCoordinator+TextDelegate).
        let caretLoc = min(selectedRange.location, ns.length)
        let syntaxCrossingChanged: Bool = {
            guard let previousLoc = previousCaretLocation, previousLoc != caretLoc else { return false }
            func changed(_ rangeAt: (Int, String) -> NSRange?) -> Bool {
                let before = rangeAt(previousLoc, display)
                let after = rangeAt(caretLoc, display)
                return before?.location != after?.location || before?.length != after?.length
            }
            return changed(MarkdownStyler.taskSyntaxRange)
                || changed(MarkdownStyler.hrLineRange)
                || changed(MarkdownStyler.bulletSyntaxRange)
        }()
        guard current != previous || syntaxCrossingChanged else { return }

        // Scope to the paragraph the caret entered + the one it left + the tokens whose
        // active state changed (so their markers reveal/hide), not the whole document.
        let caretParagraph = ns.paragraphRange(for: NSRange(location: caretLoc, length: 0))
        var candidates: [NSRange] = [caretParagraph]
        if caretParagraph.length == 0 && caretLoc > 0 {
            candidates.append(ns.paragraphRange(for: NSRange(location: max(0, caretLoc - 1), length: 0)))
        }
        if let previousLoc = previousCaretLocation, previousLoc != caretLoc {
            candidates.append(ns.paragraphRange(for: NSRange(location: min(previousLoc, ns.length), length: 0)))
        }
        candidates += ParagraphRestyleScoping.renderedBlockParagraphs(in: ns, tokens: parsed)
        candidates += ParagraphRestyleScoping.tokenRestyleParagraphs(
            in: ns, tokens: parsed, currentActive: current, previousActive: previous
        )
        restyleScoped(paragraphCandidates: candidates)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension MarkdownUITextView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true   // coexist with the text view's own tap (caret placement)
    }
}

// MARK: - MarkdownFragmentContext

extension MarkdownUITextView: MarkdownFragmentContext {
    /// iOS single-selection model → the protocol's range list (length > 0 only).
    public var selectedDocumentRanges: [NSRange] {
        selectedRange.length > 0 ? [selectedRange] : []
    }

    public var displayScale: CGFloat {
        let scale = traitCollection.displayScale
        return scale > 0 ? scale : UIScreen.main.scale
    }

    public var colorScheme: MarkdownColorScheme {
        MarkdownColorScheme.resolved(from: traitCollection)
    }
}
#endif
