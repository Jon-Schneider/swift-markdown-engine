//
//  MarkdownUITextView.swift
//  MarkdownEngine
//
//  iOS read-only Markdown view (Phase 2a). A `UITextView` backed by a TextKit-2
//  stack whose layout-manager delegate installs the cross-platform
//  `MarkdownTextLayoutFragment`; the view itself is the fragment's
//  `MarkdownFragmentContext`, supplying theme/config/selection/scale.
//
//  Scope: rendering only (not editable). Editing, input handling, IME, gestures,
//  and selection-model work are later Phase 2 passes.
//

#if canImport(UIKit)
import UIKit

public final class MarkdownUITextView: UITextView {

    public var configuration: MarkdownEditorConfiguration
    public var fontName: String
    public var fontSize: CGFloat

    /// Resolved base body font (set on each render). Part of `MarkdownFragmentContext`.
    public var baseFont: PlatformFont
    /// TextKit-2 measurement bridge. Part of `MarkdownFragmentContext`.
    /// Internal: `LayoutBridge` is an internal type, so this can't be `public`.
    var layoutBridge: LayoutBridge?

    // Retained TextKit-2 stack pieces (NSTextContainer.textLayoutManager and
    // NSTextLayoutManager.delegate are weak, so we must own them).
    private let contentStorage: NSTextContentStorage
    private var markdownLayoutDelegate: MarkdownLayoutManagerDelegate?

    private var renderedMarkdown: String = ""
    private var lastInterfaceStyle: UIUserInterfaceStyle = .unspecified

    public init(
        configuration: MarkdownEditorConfiguration = .default,
        fontName: String = "SF Pro",
        fontSize: CGFloat = 16
    ) {
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.baseFont = PlatformFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)

        // Build an explicit TextKit-2 stack (the `usingTextLayoutManager:`
        // convenience initializer is not subclass-friendly).
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        self.contentStorage = contentStorage

        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        adjustsFontForContentSizeCategory = true

        let delegate = MarkdownLayoutManagerDelegate()
        delegate.context = self           // weak inside the delegate; self owns `delegate`
        markdownLayoutDelegate = delegate
        layoutManager.delegate = delegate
        layoutBridge = LayoutBridge(layoutManager)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Rendering

    /// Parse + style `storageText` and display it. Reuses the shared styling
    /// pipeline (`WikiLinkService` → `TextStylingService` → `MarkdownStyler`),
    /// identical to the macOS restyle path minus the live-edit incrementality.
    public func render(markdown storageText: String) {
        renderedMarkdown = storageText
        lastInterfaceStyle = traitCollection.userInterfaceStyle

        // Storage form (`[[Name|id]]`) → display form (`[[Name]]`).
        let display = WikiLinkService.makeDisplayState(from: storageText).display
        let ns = display as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        let (resolvedBaseFont, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        baseFont = resolvedBaseFont

        let attributed = NSMutableAttributedString(
            string: display,
            attributes: TextStylingService.makeBaseTypingAttributes(
                font: resolvedBaseFont,
                paragraphStyle: paragraph,
                theme: configuration.theme
            )
        )

        // Read-only: no caret, so no token is "active" (markers stay rendered/hidden).
        let styled = MarkdownStyler.styleAttributes(
            text: display,
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            caretLocation: NSNotFound,
            activeTokenIndices: [],
            colorScheme: MarkdownColorScheme.resolved(from: traitCollection),
            configuration: configuration
        )
        for (range, attrs) in styled {
            let clipped = NSIntersectionRange(range, fullRange)
            guard clipped.length > 0 else { continue }
            for (key, value) in attrs {
                attributed.addAttribute(key, value: value, range: clipped)
            }
        }

        attributedText = attributed
        if let tlm = textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // Re-render on light/dark flips so themed colors track the appearance.
        if traitCollection.userInterfaceStyle != lastInterfaceStyle, !renderedMarkdown.isEmpty {
            render(markdown: renderedMarkdown)
        }
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
}
#endif
