#if os(macOS)
//
//  NativeTextViewCoordinator+Restyling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Re-tokenization, paragraph-scoped restyling, and the inline-replacement
//  pipeline. The TextDelegate extension decides WHEN and on WHICH ranges to
//  restyle; this extension owns the tokenize cache and the actual call into
//  `TextStylingService`.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Atomically rebuilds contents + base attrs + Markdown styling from storage-form `text`.
    func rebuildTextStorageAndStyle(
        _ textView: NSTextView,
        from text: String,
        invalidateLayout: Bool = false
    ) {
        // Storage is raw Markdown; only wiki links transform on display.
        let displayState = WikiLinkService.makeDisplayState(from: text)
        let displayText = displayState.display
        wikiLinkMetadata = displayState.metadata

        if textView.string != displayText {
            textView.string = displayText
        }
        lastSyncedText = text
        let nsDisplay = displayText as NSString
        let fullRange = NSRange(location: 0, length: nsDisplay.length)

        let (baseFont, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: configuration.theme.bodyText,
            .paragraphStyle: paragraph
        ]
        textView.textStorage?.beginEditing()
        textView.textStorage?.removeAttribute(.link, range: fullRange)
        textView.textStorage?.setAttributes(baseAttrs, range: fullRange)

        let tokens = parsedDocument(for: displayText).tokens
        // Hide caret from styling when read-only, else clicks reveal raw token syntax.
        let caretLocation = textView.isEditable ? textView.selectedRange().location : -1
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(),
            tokens: tokens,
            in: nsDisplay,
            suppressed: !textView.isEditable,
            markerVisibility: configuration.markers.visibility
        )

        let ranges = MarkdownStyler.styleAttributes(
            text: displayText,
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            caretLocation: caretLocation,
            activeTokenIndices: activeTokenIndices,
            precomputedTokens: tokens,
            colorScheme: .resolved(from: textView.effectiveAppearance),
            configuration: configuration,
            blockRenderHeightCache: blockRenderHeightCache
        )
        for (range, attrs) in ranges {
            for (key, value) in attrs {
                textView.textStorage?.addAttribute(key, value: value, range: range)
            }
        }
        textView.textStorage?.endEditing()

        textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraph,
            theme: configuration.theme
        )

        if let tlm = textView.textLayoutManager {
            if invalidateLayout {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
            tlm.ensureLayout(for: tlm.documentRange)
        }

        // Reconcile wide-table overlays after layout settles.
        if let nativeTextView = textView as? NativeTextView {
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
    }

    func restyleTextView(
        _ textView: NSTextView,
        paragraphCandidates: [NSRange],
        tokens: [MarkdownToken]? = nil
    ) {
        let (baseFont, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )

        TextStylingService.restyle(
            textView: textView,
            layoutBridge: layoutBridge,
            paragraphCandidates: paragraphCandidates,
            baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            caretLocation: textView.isEditable ? textView.selectedRange().location : -1,
            activeTokenIndices: activeTokenIndices,
            wikiLinkIDProvider: { [weak self] range in
                self?.wikiLinkID(for: range)
            },
            precomputedTokens: tokens,
            colorScheme: .resolved(from: textView.effectiveAppearance),
            configuration: configuration,
            blockRenderHeightCache: blockRenderHeightCache
        )
        // Reconcile wide-table overlays after layout settles.
        if let nativeTextView = textView as? NativeTextView {
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
    }

    func parsedDocument(for text: String) -> ParsedDocument {
        if cachedParsedText == text, let cachedParsedDocument {
            return cachedParsedDocument
        }

        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        var codeTokens: [MarkdownToken] = []
        var latexTokens: [MarkdownToken] = []
        var blockLatexTokens: [MarkdownToken] = []
        var wikiLinkTokens: [MarkdownToken] = []
        var imageEmbedTokens: [MarkdownToken] = []

        codeTokens.reserveCapacity(tokens.count / 2)
        latexTokens.reserveCapacity(tokens.count / 4)
        blockLatexTokens.reserveCapacity(tokens.count / 4)
        wikiLinkTokens.reserveCapacity(tokens.count / 4)

        for token in tokens {
            switch token.kind {
            case .codeBlock, .inlineCode:
                codeTokens.append(token)
            case .inlineLatex:
                latexTokens.append(token)
            case .blockLatex:
                blockLatexTokens.append(token)
            case .wikiLink:
                wikiLinkTokens.append(token)
            case .imageEmbed:
                imageEmbedTokens.append(token)
            default:
                break
            }
        }

        let parsed = ParsedDocument(
            tokens: tokens,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            blockLatexTokens: blockLatexTokens,
            wikiLinkTokens: wikiLinkTokens,
            imageEmbedTokens: imageEmbedTokens
        )
        cachedParsedText = text
        cachedParsedDocument = parsed
        return parsed
    }

    func paragraphRanges(
        in text: NSString,
        intersecting editedRange: NSRange
    ) -> [NSRange] {
        guard text.length > 0 else { return [] }
        guard editedRange.location != NSNotFound else { return [] }

        var start = editedRange.location
        let end = min(NSMaxRange(editedRange), text.length)
        if start >= text.length {
            start = max(0, text.length - 1)
        }
        if end <= start {
            return [text.paragraphRange(for: NSRange(location: start, length: 0))]
        }

        var ranges: [NSRange] = []
        var cursor = start
        while cursor < end {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            ranges.append(paragraph)
            let next = NSMaxRange(paragraph)
            if next <= cursor { break }
            cursor = next
        }
        return ranges
    }

    func tokenRestyleParagraphs(
        in text: NSString,
        tokens: [MarkdownToken],
        currentActiveTokenIndices: Set<Int>,
        previousActiveTokenIndices: Set<Int>
    ) -> [NSRange] {
        var paragraphs: [NSRange] = []
        let indicesToStyle = currentActiveTokenIndices.union(previousActiveTokenIndices)

        for idx in indicesToStyle where idx >= 0 && idx < tokens.count {
            let token = tokens[idx]
            paragraphs.append(text.paragraphRange(for: token.range))

            if token.kind == .codeBlock || token.kind == .blockLatex {
                for markerRange in token.markerRanges {
                    paragraphs.append(text.paragraphRange(for: markerRange))
                }
            }
        }

        return paragraphs
    }

    func restyleParagraphs(_ paragraphs: [NSRange], in textView: NSTextView) {
        let parsed = parsedDocument(for: textView.string)
        let tokens = parsed.tokens
        let nsText = textView.string as NSString
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(),
            tokens: tokens,
            in: nsText,
            suppressed: !textView.isEditable,
            markerVisibility: configuration.markers.visibility
        )
        restyleTextView(textView, paragraphCandidates: paragraphs, tokens: tokens)
    }

    /// Insert an arbitrary literal markdown string at the current caret, verbatim.
    ///
    /// A thin caret-relative façade over `applyInlineReplacement`: it resolves the target
    /// range itself (the current selection when a caret has been established — which
    /// survives focus loss — else the end of the document as the final fallback) and hands
    /// off to the shared insertion path with `isImageEmbedMode: true` so the fragment is
    /// spliced in untransformed. This is the macOS backing for `pendingInlineInsertion`.
    func applyInlineInsertion(_ markdown: String, to textView: NSTextView) {
        let documentLength = (textView.string as NSString).length
        let caret = textView.selectedRange()
        let establishedCaret = (textView as? NativeTextView)?.didEstablishCaret ?? false
        let target: NSRange
        if establishedCaret,
           caret.location != NSNotFound,
           caret.location + caret.length <= documentLength {
            target = caret
        } else {
            target = NSRange(location: documentLength, length: 0)
        }
        let request = InlineReplacementRequest(
            documentId: documentId ?? "",
            selection: WikiLinkSelection(displayRange: target, storageRange: nil, placeholder: ""),
            storageFragment: markdown,
            isImageEmbedMode: true
        )
        let before = textView.string
        applyInlineReplacement(request, to: textView)
        // Only correct the caret when the splice actually happened. `applyInlineReplacement`
        // bails at `shouldChangeText` (inserting nothing) on a read-only view; without this
        // guard the override below would jump the selection to end-of-document on a refused
        // insert. iOS guards `isEditable` in `applyUndoableEdit` for the same reason. Compare
        // content, not length: replacing a selection with an equal-length fragment is a real
        // edit that a length check would miss.
        guard textView.string != before else { return }
        // `applyInlineReplacement` derives the post-insert caret from the wiki-DISPLAY length
        // of the fragment (`caretRangeAfterReplacing` → `makeDisplayState`, which strips `|id`
        // from any `[[Name|id]]`). For a verbatim insert that would land the caret INSIDE the
        // run. Re-place it at the true inserted length so the caret sits just past the run,
        // matching iOS. A no-op for markdown without wiki syntax (the common case), where the
        // display length already equals the verbatim length.
        let end = min(target.location + (markdown as NSString).length,
                      (textView.string as NSString).length)
        if textView.selectedRange() != NSRange(location: end, length: 0) {
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    /// Apply `request` unless it repeats the last-applied request id (dedup across a
    /// duplicate `updateNSView` pass before the binding resets). Returns whether it
    /// inserted. Drives the wrapper's `pendingInlineInsertion` handling.
    @discardableResult
    func applyInsertionIfNew(_ request: InlineInsertionRequest, to textView: NSTextView) -> Bool {
        guard lastAppliedInsertionID != request.id else { return false }
        lastAppliedInsertionID = request.id
        applyInlineInsertion(request.markdown, to: textView)
        return true
    }

    /// Clear the insertion dedup id when the binding goes nil, so a later request carrying
    /// the same markdown (but a new id) is not mistaken for the one just applied.
    func resetInsertionDedup() { lastAppliedInsertionID = nil }

    func applyInlineReplacement(_ request: InlineReplacementRequest, to textView: NSTextView) {
        lastAppliedInlineReplacementID = request.id

        let currentText = textView.string as NSString
        let range = request.selection.displayRange
        guard range.location != NSNotFound,
              range.location + range.length <= currentText.length else {
            return
        }

        let replacementDisplay: String
        let linkID: String?
        if request.isImageEmbedMode {
            replacementDisplay = request.storageFragment
            linkID = nil
        } else {
            let replacementInfo = WikiLinkService.displayFragmentAndID(from: request.storageFragment)
            replacementDisplay = replacementInfo.display
            linkID = replacementInfo.id
        }

        let undoActionName = request.isImageEmbedMode ? "Insert Image Embed" : "Insert Link"
        textView.breakUndoCoalescing()

        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }

        guard textView.shouldChangeText(in: range, replacementString: replacementDisplay) else {
            return
        }

        textView.textStorage?.replaceCharacters(in: range, with: replacementDisplay)

        if let linkID, !linkID.isEmpty {
            let contentLength = max(0, (replacementDisplay as NSString).length - 4)
            if contentLength > 0 {
                let contentRange = NSRange(location: range.location + 2, length: contentLength)
                textView.textStorage?.addAttribute(.wikiLinkID, value: linkID, range: contentRange)
            }
        }

        textView.didChangeText()
        textView.undoManager?.setActionName(undoActionName)
        textView.breakUndoCoalescing()

        let caretRange = WikiLinkService.caretRangeAfterReplacing(
            displayRange: range,
            with: request.storageFragment
        )
        let documentLength = (textView.string as NSString).length
        let clampedCaret = NSRange(location: min(max(caretRange.location, 0), documentLength), length: 0)

        if let bottomTextView = textView as? NativeTextView {
            bottomTextView.suppressAutoRevealOnce = true
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(clampedCaret)
    }
}

#endif
