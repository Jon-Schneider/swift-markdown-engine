//
//  MarkdownStyler+Tables.swift
//  MarkdownEngine
//
//  GFM tables. The block is rendered to a single PlatformImage and emitted via
//  the same collapsedSource path block-LaTeX uses, so the source stays
//  in sync with the document but the user only sees the rendered grid
//  when the caret is outside the table.
//
//  Cross-platform: the grid is composited via UIGraphicsImageRenderer (iOS) or a
//  flipped NSImage (macOS); both draw in the same top-down coordinate space.
//

import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension MarkdownStyler {

    enum TableAlignment {
        case left
        case center
        case right
    }

    struct ParsedTable {
        let header: [String]
        let alignments: [TableAlignment]
        let rows: [[String]]
    }

    static func styleTables(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        // Per-content occurrence counter so identical tables get distinct sourceIDs.
        var occurrenceByContentHash: [Int: Int] = [:]
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .table {
            // Tokenizer already drops tables overlapping fenced code, so no re-check here.
            attrs.append((token.range, [.spellingState: 0]))

            let source = ctx.nsText.substring(with: token.range)
            guard let parsed = parseTableSource(source) else { continue }

            // Advance occurrence index even for active tables so inactive duplicates stay stable.
            let contentHash = stableTableContentHash(for: source)
            let occurrenceIndex = occurrenceByContentHash[contentHash, default: 0]
            occurrenceByContentHash[contentHash] = occurrenceIndex + 1

            let isActive = ctx.activeTokenIndices.contains(idx)
            if isActive {
                // Caret inside the table — show editable source, pipes muted like other syntax.
                let muted = ctx.configuration.theme.mutedText
                let body = ctx.configuration.theme.bodyText
                attrs.append((token.range, [.foregroundColor: body, .font: ctx.baseFont]))
                // Mute each `|` so the structure stays legible while editing.
                let end = NSMaxRange(token.range)
                var i = token.range.location
                while i < end {
                    if ctx.nsText.character(at: i) == 0x7C {   // '|'
                        attrs.append((NSRange(location: i, length: 1), [.foregroundColor: muted]))
                    }
                    i += 1
                }
                // Reveal-height reservation (plan 1.1 follow-up): a NARROW table's
                // revealed pipe-source is shorter than the rendered grid, so without
                // this the block collapses and the content below jumps on caret
                // entry/exit. Reserve the grid's last-rendered height across the source
                // rows, using the same half-line spacing the render branch emits so the
                // footprint matches exactly (one non-wrapping line per row). The
                // width-aware lookup reserves ONLY while the table is narrow at the
                // CURRENT container width — a wide table (rendered width > container) is
                // rejected here, so its wrapping source isn't force-floored. A miss
                // (wide, never rendered, or source edited since) → natural reflow, never
                // a re-render purely to measure.
                if let reserved = ctx.blockRenderHeightCache?.height(
                       forSource: source, fontSize: ctx.baseFont.pointSize,
                       maxContentWidth: effectiveContainerWidth(for: ctx)
                   ),
                   let paraRange = token.standaloneParagraphRange(in: ctx.nsText) {
                    let spacing = ctx.baseDefaultLineHeight * 0.5
                    reserveRevealedBlockHeight(
                        reserved, paraRange: paraRange,
                        spacingBefore: spacing, spacingAfter: spacing,
                        ctx: ctx, attrs: &attrs
                    )
                }
                continue
            }

            // Render the grid under the scheme threaded in from the view adapter —
            // no `effectiveAppearance`/`NSApp` probing in shared styling logic.
            // (Collapses to light/dark; `renderTable` resolves the real colors.
            // See iOS-Support-Plan.md Phase 0.)
            let image = renderTable(
                parsed,
                baseFont: ctx.baseFont,
                theme: ctx.configuration.theme,
                codeBackgroundColor: ctx.codeBackgroundColor,
                latex: ctx.services.latex,
                colorScheme: ctx.colorScheme
            )
            let imageBounds = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
            // Wide tables → scrollable mode (a scroll-view overlay owns the visual and
            // provides horizontal scrolling: `WideTableOverlay` (NSScrollView) on macOS,
            // `MarkdownTableScrollView` (UIScrollView) on iOS); narrow → collapsed.
            let containerWidth = effectiveContainerWidth(for: ctx)
            let isWide = image.size.width > containerWidth + 0.5
            // Cache the rendered grid height + its intrinsic width for the reveal-height
            // reservation (above). The width lets the reveal branch decide narrow-vs-wide
            // at the CURRENT container width (reserve only while narrow), so a
            // resize/rotation that turns this table wide stops reserving even though the
            // macOS width-change restyle won't re-render a narrow table. Keyed by source +
            // base font size (same source + base font → same render). Wide-table
            // reservation (its source wraps + a scroller strip) is a tracked follow-up.
            ctx.blockRenderHeightCache?.store(
                height: image.size.height, forSource: source,
                fontSize: ctx.baseFont.pointSize, contentWidth: image.size.width
            )
            let computedSourceID = stableTableSourceID(
                for: source,
                occurrenceIndex: occurrenceIndex
            )
            let mode: RenderedStandaloneBlockMode = isWide
                ? .collapsedSourceScrollable(
                    markerTexts: [],
                    displayWidth: containerWidth,
                    sourceID: computedSourceID
                )
                : .collapsedSource(markerTexts: [])
            _ = appendRenderedStandaloneBlock(
                for: token,
                rawContent: source,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacingBefore: ctx.baseDefaultLineHeight * 0.5,
                paragraphSpacing: ctx.baseDefaultLineHeight * 0.5,
                alignment: .left,
                mode: mode,
                ctx: ctx,
                attrs: &attrs
            )
        }
        return attrs
    }

    // MARK: - Parsing

    static func parseTableSource(_ source: String) -> ParsedTable? {
        let rawLines = source.components(separatedBy: CharacterSet.newlines)
        let lines = rawLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }

        let header = parseTableRow(lines[0])
        let alignments = parseTableAlignments(lines[1])
        guard !header.isEmpty, !alignments.isEmpty else { return nil }

        let columnCount = max(header.count, alignments.count)
        let bodyLines = Array(lines.dropFirst(2))

        func pad<T>(_ array: [T], to count: Int, with fill: T) -> [T] {
            if array.count == count { return array }
            if array.count > count { return Array(array.prefix(count)) }
            return array + Array(repeating: fill, count: count - array.count)
        }

        let paddedHeader = pad(header, to: columnCount, with: "")
        let paddedAlign = pad(alignments, to: columnCount, with: .left)
        let rows = bodyLines.map { pad(parseTableRow($0), to: columnCount, with: "") }

        return ParsedTable(header: paddedHeader, alignments: paddedAlign, rows: rows)
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func parseTableAlignments(_ line: String) -> [TableAlignment] {
        let cells = parseTableRow(line)
        return cells.map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let leading = trimmed.hasPrefix(":")
            let trailing = trimmed.hasSuffix(":")
            switch (leading, trailing) {
            case (true, true): return .center
            case (false, true): return .right
            default: return .left
            }
        }
    }

    // MARK: - Inline-formatted cell strings

    /// Raw cell → `NSAttributedString`: inline markdown applied, markers stripped, LaTeX as attachments.
    static func formattedCellString(
        _ raw: String,
        baseFont: PlatformFont,
        header: Bool,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: PlatformColor,
        latex: any LatexRenderer,
        colorScheme: MarkdownColorScheme
    ) -> NSAttributedString {
        let descriptor = baseFont.fontDescriptor
        let pointSize = baseFont.pointSize
        let codeFont = PlatformFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        let startFont = header
            ? (PlatformFont(descriptor: descriptor.withSymbolicTraitsCompat(.boldTrait), size: pointSize) ?? baseFont)
            : baseFont
        let out = NSMutableAttributedString()
        appendInlineCell(
            InlineParser.parse(raw), in: raw as NSString, into: out,
            font: startFont, baseDescriptor: descriptor, pointSize: pointSize,
            codeFont: codeFont, theme: theme, codeBackgroundColor: codeBackgroundColor, latex: latex,
            colorScheme: colorScheme
        )
        return out
    }

    /// Compose `current`'s bold/italic traits with `kind` so nested emphasis stacks (italic+bold).
    private static func composeEmphasis(
        _ current: PlatformFont, _ kind: EmphasisKind,
        baseDescriptor: PlatformFontDescriptor, pointSize: CGFloat
    ) -> PlatformFont {
        let boldItalic: PlatformFontDescriptor.SymbolicTraits = [.boldTrait, .italicTrait]
        var traits = current.fontDescriptor.symbolicTraits.intersection(boldItalic)
        switch kind {
        case .bold: traits.insert(.boldTrait)
        case .italic: traits.insert(.italicTrait)
        case .boldItalic: traits.formUnion(boldItalic)
        }
        return PlatformFont(descriptor: baseDescriptor.withSymbolicTraitsCompat(traits), size: pointSize) ?? current
    }

    /// Walk the inline AST into marker-stripped runs; LaTeX as attachments, links/embeds emitted raw.
    private static func appendInlineCell(
        _ nodes: [InlineNode],
        in ns: NSString,
        into out: NSMutableAttributedString,
        font: PlatformFont,
        baseDescriptor: PlatformFontDescriptor,
        pointSize: CGFloat,
        codeFont: PlatformFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: PlatformColor,
        latex: any LatexRenderer,
        colorScheme: MarkdownColorScheme
    ) {
        func recurse(_ children: [InlineNode], _ f: PlatformFont) {
            appendInlineCell(children, in: ns, into: out, font: f, baseDescriptor: baseDescriptor,
                             pointSize: pointSize, codeFont: codeFont, theme: theme,
                             codeBackgroundColor: codeBackgroundColor, latex: latex,
                             colorScheme: colorScheme)
        }
        func appendPlain(_ range: NSRange, _ f: PlatformFont) {
            out.append(NSAttributedString(string: ns.substring(with: range),
                                          attributes: [.font: f, .foregroundColor: theme.bodyText]))
        }
        for node in nodes {
            switch node {
            case .text(let r):
                appendPlain(r, font)
            case .escape(_, let character, _):
                appendPlain(character, font)
            case .emphasis(let kind, _, _, let children):
                recurse(children, composeEmphasis(font, kind, baseDescriptor: baseDescriptor, pointSize: pointSize))
            case .strikethrough(_, _, let children):
                let start = out.length
                recurse(children, font)
                if out.length > start {
                    out.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: theme.bodyText
                    ], range: NSRange(location: start, length: out.length - start))
                }
            case .code(_, let content):
                out.append(NSAttributedString(string: ns.substring(with: content), attributes: [
                    .font: codeFont, .backgroundColor: codeBackgroundColor, .foregroundColor: theme.bodyText
                ]))
            case .inlineLatex(let range, let content, _):
                if let entry = latex.render(latex: ns.substring(with: content), fontSize: pointSize, theme: theme, colorScheme: colorScheme) {
                    let attachment = NSTextAttachment()
                    attachment.image = entry.image
                    attachment.bounds = CGRect(x: 0, y: entry.baselineOffset,
                                               width: entry.size.width, height: entry.size.height)
                    out.append(NSAttributedString(attachment: attachment))
                } else {
                    appendPlain(range, font)   // renderer unavailable → keep raw `$…$`
                }
            case .link(let range, _, _, _, _),
                 .image(let range, _, _, _),
                 .wikiLink(let range, _, _, _),
                 .imageEmbed(let range, _, _):
                appendPlain(range, font)
            }
        }
    }

    // MARK: - Rendering

    private static func renderTable(
        _ table: ParsedTable,
        baseFont: PlatformFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: PlatformColor,
        latex: any LatexRenderer,
        colorScheme: MarkdownColorScheme
    ) -> PlatformImage {
        let columnCount = table.alignments.count
        let cellHPadding: CGFloat = 12
        let cellVPadding: CGFloat = 6
        let borderWidth: CGFloat = 1
        // Resolve the dynamic muted color for the active scheme *before* `.withAlphaComponent()`,
        // which would otherwise freeze a dynamic color at whatever appearance is current.
        func mutedColor(alpha: CGFloat) -> PlatformColor {
#if canImport(UIKit)
            let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
            return theme.mutedText.resolvedColor(with: traits).withAlphaComponent(alpha)
#else
            var resolved: NSColor = theme.mutedText
            colorScheme.appKitAppearance.performAsCurrentDrawingAppearance {
                resolved = theme.mutedText.usingColorSpace(.sRGB) ?? theme.mutedText
            }
            return resolved.withAlphaComponent(alpha)
#endif
        }
        let borderColor = mutedColor(alpha: 0.5)
        let baseLineHeight: CGFloat = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
        let minColumnContentWidth: CGFloat = 16

        // Pre-format every cell so width measurement and drawing share one NSAttributedString.
        let headerCells = table.header.map {
            formattedCellString(
                $0, baseFont: baseFont, header: true, theme: theme,
                codeBackgroundColor: codeBackgroundColor, latex: latex,
                colorScheme: colorScheme
            )
        }
        let bodyCells = table.rows.map { row in
            row.map {
                formattedCellString(
                    $0, baseFont: baseFont, header: false, theme: theme,
                    codeBackgroundColor: codeBackgroundColor, latex: latex,
                    colorScheme: colorScheme
                )
            }
        }

        var columnWidths = [CGFloat](repeating: minColumnContentWidth, count: columnCount)
        var maxCellHeight: CGFloat = baseLineHeight
        func considerCell(_ cell: NSAttributedString, col: Int) {
            let size = cell.size()
            columnWidths[col] = max(columnWidths[col], ceil(size.width))
            maxCellHeight = max(maxCellHeight, ceil(size.height))
        }
        for (i, cell) in headerCells.enumerated() where i < columnCount {
            considerCell(cell, col: i)
        }
        for row in bodyCells {
            for (i, cell) in row.enumerated() where i < columnCount {
                considerCell(cell, col: i)
            }
        }

        let lineHeight = max(baseLineHeight, maxCellHeight)
        let rowCount = 1 + table.rows.count // header + body rows
        let totalWidth = columnWidths.reduce(0, +)
            + CGFloat(columnCount) * 2 * cellHPadding
            + CGFloat(columnCount + 1) * borderWidth
        let rowHeight = lineHeight + 2 * cellVPadding
        let totalHeight = CGFloat(rowCount) * rowHeight + CGFloat(rowCount + 1) * borderWidth

        let size = CGSize(width: totalWidth, height: totalHeight)

        // Pre-compute layout offsets (top-down coords; drawing runs flipped).
        var columnLeft = [CGFloat](repeating: 0, count: columnCount + 1)
        columnLeft[0] = borderWidth
        for i in 0..<columnCount {
            columnLeft[i + 1] = columnLeft[i] + columnWidths[i] + 2 * cellHPadding + borderWidth
        }
        var rowTop = [CGFloat](repeating: 0, count: rowCount + 1)
        rowTop[0] = borderWidth
        for i in 0..<rowCount {
            rowTop[i + 1] = rowTop[i] + rowHeight + borderWidth
        }

        let alignments = table.alignments
        let headerFill = mutedColor(alpha: 0.08)

        // Top-down drawing space on both platforms (flipped NSImage / UIGraphicsImageRenderer);
        // a manual transform mirror would flip glyphs too.
        return renderFlippedPlatformImage(size: size) {
            // Header row fill
            headerFill.setFill()
            PlatformBezierPath(rect: CGRect(
                x: borderWidth,
                y: borderWidth,
                width: size.width - 2 * borderWidth,
                height: rowHeight
            )).fill()

            // Outer border
            borderColor.setStroke()
            let outer = PlatformBezierPath(rect: CGRect(
                x: borderWidth / 2,
                y: borderWidth / 2,
                width: size.width - borderWidth,
                height: size.height - borderWidth
            ))
            outer.lineWidth = borderWidth
            outer.stroke()

            // Internal separators
            let separators = PlatformBezierPath()
            separators.lineWidth = borderWidth
            for i in 1..<columnCount {
                let x = columnLeft[i] - borderWidth / 2
                separators.move(to: CGPoint(x: x, y: 0))
                separators.addLineCompat(to: CGPoint(x: x, y: size.height))
            }
            for i in 1..<rowCount {
                let y = rowTop[i] - borderWidth / 2
                separators.move(to: CGPoint(x: 0, y: y))
                separators.addLineCompat(to: CGPoint(x: size.width, y: y))
            }
            separators.stroke()

            func drawCell(_ s: NSAttributedString, col: Int, row: Int) {
                guard col < columnCount else { return }
                let cellLeft = columnLeft[col] + cellHPadding
                let cellRight = columnLeft[col + 1] - borderWidth - cellHPadding
                let availableWidth = cellRight - cellLeft
                // Align via NSParagraphStyle in the content rect so the text engine handles clipping.
                let paragraph = NSMutableParagraphStyle()
                switch alignments[col] {
                case .left:   paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right:  paragraph.alignment = .right
                }
                paragraph.lineBreakMode = .byClipping
                let aligned = NSMutableAttributedString(attributedString: s)
                aligned.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: aligned.length)
                )
                let cellInnerTop = rowTop[row] + max(0, (rowHeight - lineHeight) / 2)
                let drawRect = CGRect(
                    x: cellLeft,
                    y: cellInnerTop,
                    width: availableWidth,
                    height: lineHeight
                )
                aligned.draw(with: drawRect, options: [.usesLineFragmentOrigin], context: nil)
            }

            for (col, cell) in headerCells.enumerated() {
                drawCell(cell, col: col, row: 0)
            }
            for (rowIdx, row) in bodyCells.enumerated() {
                for (col, cell) in row.enumerated() {
                    drawCell(cell, col: col, row: rowIdx + 1)
                }
            }
        }
    }

    // MARK: - Scrollable table helpers

    /// Container width with fallback chain for "styler runs before layout" case.
    static func effectiveContainerWidth(for ctx: StylingContext) -> CGFloat {
        if let container = ctx.layoutBridge?.firstTextContainer {
            let raw = container.size.width
            if raw.isFinite, raw > 0, raw < 100_000 { return raw }
#if os(macOS)
            // AppKit-only fallback: `NSTextContainer.textView` doesn't exist on UIKit.
            if let textView = container.textView {
                let inset = textView.textContainerInset
                let usable = textView.bounds.width - inset.width * 2
                if usable.isFinite, usable > 0 { return usable }
                let frameUsable = textView.frame.width - inset.width * 2
                if frameUsable.isFinite, frameUsable > 0 { return frameUsable }
            }
#endif
        }
        return 500
    }

    /// Content-only hash; intentionally collides for identical tables — disambiguated by occurrence index.
    static func stableTableContentHash(for source: String) -> Int {
        var hasher = Hasher()
        hasher.combine("table-overlay-v1")
        hasher.combine(source)
        return hasher.finalize()
    }

    /// Per-instance ID = (content, nth-occurrence); stable across re-styles so scroll offsets persist.
    static func stableTableSourceID(for source: String, occurrenceIndex: Int) -> Int {
        var hasher = Hasher()
        hasher.combine("table-overlay-v2")
        hasher.combine(source)
        hasher.combine(occurrenceIndex)
        return hasher.finalize()
    }
}
