//
//  MarkdownStyler+Latex.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Block ($$...$$) and inline ($...$) LaTeX formula rendering.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension MarkdownStyler {

    // MARK: Block LaTeX $$...$$

    static func styleBlockLatex(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let blockLatexTokens = ctx.tokens.enumerated().filter { $0.element.kind == .blockLatex }
        for (idx, token) in blockLatexTokens {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            let isActive = ctx.activeTokenIndices.contains(idx)
            let rawLatexContent = ctx.nsText.substring(with: token.contentRange)
            let latexContent = rawLatexContent.trimmingCharacters(in: .whitespacesAndNewlines)

            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))

            guard let paraRange = token.standaloneParagraphRange(in: ctx.nsText) else { continue }

            let latexFontSize = HeadingHelpers.latexFontSize(for: token, tokens: ctx.tokens, baseFont: ctx.baseFont)

            if isActive {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                // Reveal hole (plan 1.2): the raw source replaces the rendered formula, which is
                // usually a different height. Reserve the formula's last-rendered height (if cached)
                // so the block doesn't collapse and jump the content below on caret entry. A cache
                // miss (source edited since it rendered, or never rendered) → natural reflow.
                if let reserved = ctx.blockRenderHeightCache?.height(forSource: latexContent, fontSize: latexFontSize) {
                    reserveRevealedBlockHeight(
                        reserved, paraRange: paraRange,
                        spacingBefore: ctx.configuration.blockLatex.paragraphSpacingBefore,
                        spacingAfter: ctx.configuration.blockLatex.paragraphSpacing,
                        ctx: ctx, attrs: &attrs
                    )
                }
            } else if !latexContent.isEmpty,
                      let entry = ctx.services.latex.render(latex: latexContent, fontSize: latexFontSize, theme: ctx.configuration.theme, colorScheme: ctx.colorScheme) {
                // Cache the rendered footprint height so a later reveal can reserve it (above).
                ctx.blockRenderHeightCache?.store(height: entry.size.height, forSource: latexContent, fontSize: latexFontSize)
                _ = appendRenderedStandaloneBlock(
                    for: token,
                    rawContent: rawLatexContent,
                    image: entry.image,
                    imageBounds: CGRect(
                        x: 0,
                        y: entry.baselineOffset,
                        width: entry.size.width,
                        height: entry.size.height
                    ),
                    paragraphSpacingBefore: ctx.configuration.blockLatex.paragraphSpacingBefore,
                    paragraphSpacing: ctx.configuration.blockLatex.paragraphSpacing,
                    alignment: .center,
                    mode: .collapsedSource(markerTexts: ["$$", "$$"]),
                    ctx: ctx,
                    attrs: &attrs
                )
            } else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }

    /// Reserve `height` (a revealed block's last-rendered formula footprint) across the revealed
    /// source so the block stays at least as tall as the rendered formula and the content below
    /// doesn't jump on caret entry/exit. The height is distributed as a per-paragraph
    /// `minimumLineHeight` floor; the rendered block's vertical spacing is matched by placing
    /// `paragraphSpacingBefore` on only the FIRST paragraph and `paragraphSpacing` on only the LAST
    /// (mirroring the collapsed path, which spaces a single anchor paragraph) — so the total
    /// footprint equals the formula's, not multiplied by the source's paragraph count. A shorter
    /// source (e.g. one `$$…$$` line vs a tall fraction) pads up to the formula's height; a taller
    /// source keeps its natural height (no `maximumLineHeight`, so nothing is clipped).
    ///
    /// IMPORTANT: the floor is per *paragraph* but applies per laid-out (visual) line, so a logical
    /// line that WRAPS over-reserves (each wrapped visual line gets the full floor). Callers must
    /// therefore only reserve blocks whose revealed source does NOT wrap: block LaTeX (`$$…$$` lines
    /// fit) and NARROW tables (one short line per row) qualify; wide tables (long, wrapping pipe
    /// rows) are deliberately excluded by their caller — for them this would inflate the footprint.
    /// Also assumes a top-level standalone block: it builds a fresh paragraph style, discarding any
    /// inherited indentation (true for top-level LaTeX/tables; a nested block would lose it).
    ///
    /// Shared by the block-LaTeX (plan 1.2) and table (plan 1.1 follow-up) reveal paths — each
    /// passes its own `spacingBefore`/`spacingAfter` (block LaTeX uses its configured paragraph
    /// spacing; a table uses the half-line spacing its render branch emits), so the reserved
    /// footprint matches the rendered block's vertical extent on either path.
    static func reserveRevealedBlockHeight(
        _ height: CGFloat,
        paraRange: NSRange,
        spacingBefore: CGFloat,
        spacingAfter: CGFloat,
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) {
        var paragraphRanges: [NSRange] = []
        ctx.nsText.enumerateSubstrings(in: paraRange, options: .byParagraphs) { _, _, enclosingRange, _ in
            paragraphRanges.append(enclosingRange)
        }
        guard !paragraphRanges.isEmpty else { return }

        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        let perLineFloor = max(baseLineHeight, height / CGFloat(paragraphRanges.count))

        for (i, range) in paragraphRanges.enumerated() {
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = perLineFloor
            para.paragraphSpacingBefore = (i == 0) ? spacingBefore : 0
            para.paragraphSpacing = (i == paragraphRanges.count - 1) ? spacingAfter : 0
            attrs.append((range, [.paragraphStyle: para]))
        }
    }

    // MARK: Inline LaTeX $formula$

    static func styleInlineLatex(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        // Tables render their own cell contents (including `$…$`) into a single
        // image via `formattedCellString` + `collapsedSource`. If we also tag
        // the source-text `$x^2$` with a `.latexImage` attribute, the renderer
        // draws that tiny inline image on the collapsed 1pt source line under
        // the table — visible as a stray dot. Skip inline LaTeX inside a
        // table; the table image already covers it.
        let tableRanges = ctx.tokens.filter { $0.kind == .table }.map(\.range)
        // Quote lines mute their text via foregroundColor, which the LaTeX *image* ignores — render it in mutedText instead so it matches the grey.
        let blockquoteRanges = ctx.tokens.filter { $0.kind == .blockquote }.map(\.range)
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .inlineLatex {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            if tableRanges.contains(where: { tableRange in
                token.range.location >= tableRange.location
                    && NSMaxRange(token.range) <= NSMaxRange(tableRange)
            }) { continue }

            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))

            let isActive = ctx.activeTokenIndices.contains(idx)
            let latexContent = ctx.nsText.substring(with: token.contentRange)
            let latexFontSize = HeadingHelpers.latexFontSize(for: token, tokens: ctx.tokens, baseFont: ctx.baseFont)

            if isActive {
                for markerRange in token.markerRanges {
                    attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
                }
            } else {
                var renderTheme = ctx.configuration.theme
                if blockquoteRanges.contains(where: { NSLocationInRange(token.range.location, $0) }) {
                    renderTheme.latexLightModeText = renderTheme.mutedText
                    renderTheme.latexDarkModeText = renderTheme.mutedText
                }
                if let entry = ctx.services.latex.render(latex: latexContent, fontSize: latexFontSize, theme: renderTheme, colorScheme: ctx.colorScheme) {
                    let imageBounds = CGRect(x: 0, y: entry.baselineOffset, width: entry.size.width, height: entry.size.height)
                    let contentLength = token.contentRange.length
                    let tinyDollarWidth = HeadingHelpers.textWidth("$", font: ctx.latexMarkerFont)
                    let baseDollarWidth = HeadingHelpers.textWidth("$", font: ctx.baseFont)

                    if contentLength > 0 {
                        let firstCharRange = NSRange(location: token.contentRange.location, length: 1)
                        let firstChar = ctx.nsText.substring(with: firstCharRange)
                        attrs.append((firstCharRange, [
                            .latexImage: entry.image,
                            .latexBounds: NSValue(cgRect: imageBounds),
                            .foregroundColor: PlatformColor.clear,
                            .font: ctx.latexMarkerFont,
                            .kern: entry.size.width - HeadingHelpers.textWidth(firstChar, font: ctx.latexMarkerFont)
                        ]))

                        if contentLength > 1 {
                            let restRange = NSRange(location: token.contentRange.location + 1, length: contentLength - 1)
                            let restText = ctx.nsText.substring(with: restRange)
                            attrs.append((restRange, [
                                .foregroundColor: PlatformColor.clear,
                                .font: ctx.latexMarkerFont,
                                .kern: -HeadingHelpers.textWidth(restText, font: ctx.latexMarkerFont)
                            ]))
                        }
                    }

                    let openMarker = token.markerRanges[0]
                    attrs.append((openMarker, [
                        .font: ctx.latexMarkerFont,
                        .foregroundColor: PlatformColor.clear,
                        .kern: -tinyDollarWidth
                    ]))
                    let closeMarker = token.markerRanges[1]
                    attrs.append((closeMarker, [
                        .foregroundColor: PlatformColor.clear,
                        .kern: -baseDollarWidth
                    ]))
                } else {
                    for markerRange in token.markerRanges {
                        attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
                    }
                }
            }
        }
        return attrs
    }
}
