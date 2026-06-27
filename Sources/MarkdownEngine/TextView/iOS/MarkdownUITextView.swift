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
        autocorrectionType = .no            // marked-text/autocorrect lifecycle is a later pass
        smartDashesType = .no
        smartQuotesType = .no
        delegate = self

        let layoutDelegate = MarkdownLayoutManagerDelegate()
        layoutDelegate.context = self
        markdownLayoutDelegate = layoutDelegate
        layoutManager.delegate = layoutDelegate
        layoutBridge = LayoutBridge(layoutManager)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCheckboxTap(_:)))
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

    // MARK: - Checkbox tap-toggle

    @objc private func handleCheckboxTap(_ recognizer: UITapGestureRecognizer) {
        // For a scroll view, `location(in: self)` is already in content coordinates
        // (bounds.origin == contentOffset).
        toggleCheckbox(at: recognizer.location(in: self))
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
        switch MarkdownLists.computeListInsertion(
            currentText: textView.text, affectedCharRange: range,
            replacementString: text, configuration: configuration
        ) {
        case .allowDefault:
            return true
        case .block:
            return false
        case .replace(let replaceRange, let replaceText, let caret):
            applyUndoableEdit(replacing: replaceRange, with: replaceText,
                              finalSelection: NSRange(location: caret, length: 0))
            return false
        }
    }

    public func textViewDidChange(_ textView: UITextView) {
        if isApplyingProgrammaticEdit { return }
        restyleInPlace()
        emitStorageTextIfChanged()
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        if isApplyingProgrammaticEdit { return }
        // Reveal/hide the caret token's raw markers — restyle only when the active set shifts.
        let display = textStorage.string
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: selectedRange, tokens: tokens(for: display), in: display as NSString
        )
        if active != lastActiveTokens { restyleInPlace() }
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
