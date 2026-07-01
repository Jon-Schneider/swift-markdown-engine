#if os(macOS)
//
//  NativeTextView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//
//  AppKit `NSTextView` subclass used by the markdown editor. Stored state
//  lives here; behavior is split across `NativeTextView+<Feature>.swift`
//  files in this folder (frame & overscroll, caret workarounds, click remap,
//  paste handling, drag-select boost, task checkbox, spelling policy).
//
//  Bottom-overscroll math lives in `BottomOverscrollPolicy.swift`.
//  Pasteboard image inspection lives in `PasteboardImageReader.swift`.
//

import AppKit
import UniformTypeIdentifiers

final class NativeTextView: NSTextView {
    // MARK: Frame & overscroll state
    var baseContentHeight: CGFloat = 0
    var activeBottomOverscroll: CGFloat = 0
    var isApplyingManagedFrameSize = false
    /// Set on switch/resize to force full-layout height measurement until the cascade settles.
    var pendingFullLayoutMeasure = false
    /// Coalesces wide-table overlay updates to once per runloop (resize fires many per frame).
    var pendingWideTableOverlayUpdate = false
    var suppressAutoRevealOnce: Bool = false
    /// True once the view has become first responder at least once, i.e. a real caret
    /// has been established. `applyInlineInsertion` uses this to choose between the
    /// current/last-known caret and the end-of-document final fallback.
    private(set) var didEstablishCaret = false

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            didEstablishCaret = true
            // Report focus GAIN to the host `focus` binding. Driven from the first-responder
            // transition itself — NOT the `textDidBeginEditing`/`textDidEndEditing` NSText
            // notifications, which fire around an *editing session* (first mutation … edit end),
            // so a click-to-focus with no typing would never report, and a focus stolen back by
            // the reconcile would leave the binding stuck `true`. The coordinator (our delegate)
            // owns the reporter; it dedups against the binding, so a host-driven focus that lands
            // us here writes back the same value and doesn't loop.
            (delegate as? NativeTextViewCoordinator)?.onFocusChange?(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // Report focus LOSS. Crucial for the reconcile: when the user clicks away, this writes
        // `false` back so the next `updateNSView` pass does NOT see a stale `true` and yank first
        // responder back from wherever they just clicked.
        if resigned {
            (delegate as? NativeTextViewCoordinator)?.onFocusChange?(false)
        }
        return resigned
    }

    /// Mark a caret as established (as if the view had become first responder) so
    /// `applyInlineInsertion` targets the current selection instead of the end-of-document
    /// fallback. Internal for tests that can't enter the responder chain without a window.
    func establishCaretForTesting() { didEstablishCaret = true }

    // MARK: Configuration
    var configuration: MarkdownEditorConfiguration = .default {
        didSet {
            overscrollPercent = configuration.overscroll.percent
            maxOverscrollPoints = configuration.overscroll.maxPoints
            minOverscrollPoints = configuration.overscroll.minPoints
        }
    }
    var overscrollPercent: CGFloat = MarkdownEditorConfiguration.default.overscroll.percent
    var maxOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.maxPoints
    var minOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.minPoints

    // MARK: Editor wiring
    var onPasteImage: ((NSPasteboard) -> String?)?
    weak var layoutBridge: LayoutBridge?
    var baseFont: NSFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    // MARK: Caret-workaround state
    var caretIndicatorObservation: NSKeyValueObservation?
    weak var observedCaretIndicator: NSView?
    var isApplyingCaretShift: Bool = false

    // MARK: Drag-select state
    var dragStartMouseScreenLoc: NSPoint?

    // MARK: Placeholder state
    /// Click-through ghost-text label shown while the document is empty;
    /// managed by `NativeTextView+Placeholder.swift`.
    weak var placeholderView: PlaceholderLabelView?

    // MARK: Wide-table overlay state
    /// Live NSScrollView per wide table; keyed by source-ID hash.
    var wideTableOverlays: [Int: WideTableOverlay] = [:]
    /// Persisted horizontal scroll offset per wide table; survives restyles.
    var tableHorizontalScrollOffsets: [Int: CGFloat] = [:]

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Forward appearance changes to the embedder's highlighter via its registered notification.
        if let name = configuration.services.syntaxHighlighter.appearanceDidChangeNotification {
            NotificationCenter.default.post(name: name, object: self)
        }
    }

    // setMarkedText skips textDidChange, so restyle the marked paragraph to apply markdown attrs.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        guard hasMarkedText(),
              let coord = delegate as? NativeTextViewCoordinator else { return }
        let marked = markedRange()
        guard marked.location != NSNotFound, marked.length > 0 else { return }
        let nsText = self.string as NSString
        let paragraph = nsText.paragraphRange(for: marked)
        coord.restyleParagraphs([paragraph], in: self)
    }

    deinit { caretIndicatorObservation?.invalidate() }
}

#endif
