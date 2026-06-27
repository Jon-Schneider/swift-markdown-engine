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
        fontSize: CGFloat = 16
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

        isEditable = true
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

    // MARK: - Loading

    /// Load `storageText` (storage form) and style it. Resets the document, so this
    /// is for initial / external content — in-place edits go through the delegate.
    public func render(markdown storageText: String) {
        lastRenderedSource = storageText
        applyTextContainerInset()            // configuration may have changed with the text
        let displayState = WikiLinkService.makeDisplayState(from: storageText)
        wikiLinkMetadata = displayState.metadata
        isApplyingProgrammaticEdit = true
        text = displayState.display          // plain text; restyleInPlace adds the styling
        isApplyingProgrammaticEdit = false
        restyleInPlace()
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
        restyleInPlace()
    }

    /// Compute and publish the current selection's formatting state (for a host toolbar).
    /// Cheap — reuses the cached token parse for the bold/italic check.
    private func publishSelectionState() {
        guard let onSelectionStateChange else { return }
        let display = textStorage.string
        onSelectionStateChange(MarkdownFormatting.selectionState(
            text: display, selection: selectedRange, tokens: tokens(for: display)
        ))
    }

    /// Force-publish the selection state now (the controller calls this on attach so a
    /// freshly-shown toolbar isn't stale).
    func publishSelectionStateNow() { publishSelectionState() }

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
        guard let range = uiTextRange(for: nsRange) else { return }
        isApplyingProgrammaticEdit = true
        replace(range, withText: string)
        // `replace` parks the caret at the end of the inserted text; restore the
        // intended selection BEFORE restyling so the styler resolves marker
        // reveal/hide against the right caret (e.g. a checkbox toggle must not leave
        // the caret inside the box, which would suppress the rendered glyph).
        if let finalSelection, let selRange = uiTextRange(for: finalSelection) {
            selectedTextRange = selRange
        }
        isApplyingProgrammaticEdit = false
        restyleInPlace()
        emitStorageTextIfChanged()
        publishSelectionState()
    }

    // MARK: - Styling

    /// Base body size scaled for the current Dynamic Type setting. All derived sizes
    /// (headings, code, checkbox metrics) are computed relative to it by the styler,
    /// so scaling the base propagates everywhere.
    private func scaledFontSize() -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: fontSize, compatibleWith: traitCollection)
    }

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
            selectionRange: selectedRange, tokens: parsed, in: ns
        )
        lastActiveTokens = active

        let styled = MarkdownStyler.styleAttributes(
            text: display, fontName: fontName, fontSize: effectiveFontSize, layoutBridge: layoutBridge,
            caretLocation: selectedRange.location, activeTokenIndices: active,
            precomputedTokens: parsed,
            colorScheme: MarkdownColorScheme.resolved(from: traitCollection),
            configuration: configuration
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
            selectionRange: selectedRange, tokens: parsed, in: ns
        )
        lastActiveTokens = active

        // `scopedRanges` lets the AST styler skip out-of-scope work; the image/table passes
        // still run over all tokens but only get *applied* where they intersect a candidate.
        let styled = MarkdownStyler.styleAttributes(
            text: display, fontName: fontName, fontSize: effectiveFontSize, layoutBridge: layoutBridge,
            caretLocation: selectedRange.location, activeTokenIndices: active,
            precomputedTokens: parsed,
            scopedRanges: paragraphs,
            colorScheme: MarkdownColorScheme.resolved(from: traitCollection),
            configuration: configuration
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

    /// Apply a formatting command to `range` via the undoable edit path.
    func applyFormatting(_ command: MarkdownFormattingCommand, in range: NSRange) {
        let edit = MarkdownFormatting.edit(for: command, text: text, selection: range)
        applyUndoableEdit(replacing: edit.range, with: edit.text, finalSelection: edit.selection)
    }

    fileprivate func formatAction(_ title: String, _ command: MarkdownFormattingCommand, _ range: NSRange) -> UIAction {
        let active = MarkdownFormatting.isActive(command, text: text, selection: range)
        var attributes: UIMenuElement.Attributes = []
        var state: UIMenuElement.State = .off
        switch command {
        case .bold, .italic:
            state = active ? .on : .off                       // toggleable
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
        // provisional — let the input system drive it; don't run list logic on it.
        if markedTextRange != nil { return true }
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
        publishSelectionState()
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
        let current = MarkdownDetection.computeActiveTokenIndices(selectionRange: selectedRange, tokens: parsed, in: ns)
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
            UIMenu(title: "Heading", children: (1...3).map { formatAction("H\($0)", .heading($0), range) }),
            UIMenu(title: "Lists", children: [
                formatAction("Bullet", .bulletList, range),
                formatAction("Numbered", .numberedList, range),
            ]),
        ])
        return UIMenu(children: suggestedActions + [format])
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        if isApplyingProgrammaticEdit { return }
        if markedTextRange != nil { return }   // selection churns during composition
        let display = textStorage.string
        let ns = display as NSString
        let parsed = tokens(for: display)
        let current = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: selectedRange, tokens: parsed, in: ns
        )
        let previous = lastActiveTokens
        defer { previousCaretLocation = selectedRange.location }
        // Publish toolbar state on every selection change (formatting context can change —
        // e.g. moving between a list line and a plain line — without the active-token set
        // shifting), reusing the tokens already parsed above.
        onSelectionStateChange?(MarkdownFormatting.selectionState(text: display, selection: selectedRange, tokens: parsed))
        // Reveal/hide the caret token's raw markers — restyle only when the active set shifts.
        guard current != previous else { return }

        // Scope to the paragraph the caret entered + the one it left + the tokens whose
        // active state changed (so their markers reveal/hide), not the whole document.
        let caretLoc = min(selectedRange.location, ns.length)
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
