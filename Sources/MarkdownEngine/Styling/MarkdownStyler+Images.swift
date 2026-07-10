//
//  MarkdownStyler+Images.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Image embed (`![[...]]`) styling and layout.
//

import Foundation

extension MarkdownStyler {

    // MARK: Markdown Image Links ![alt](url)

    /// Style standalone `![alt](url)` paragraphs by routing the URL through
    /// the embedder's `EmbeddedImageProvider` (URL goes into the request's
    /// `name` field — providers that don't speak URLs simply return `nil`,
    /// at which point we fall back to dimming the markdown source).
    static func styleImageLinks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .imageLink {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            // The URL lives between markerRanges[2] ('(') and markerRanges[3] (')').
            guard token.markerRanges.count >= 4 else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }
            let openParen = token.markerRanges[2]
            let closeParen = token.markerRanges[3]
            let urlStart = NSMaxRange(openParen)
            let urlLength = closeParen.location - urlStart
            guard urlLength > 0 else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }
            let urlRange = NSRange(location: urlStart, length: urlLength)
            let url = ctx.nsText.substring(with: urlRange)

            // Pending async-drop placeholder (`![name](x-mde-pending:UUID)`): render a loading chip
            // WITHOUT consulting the image provider. Rendered INLINE (like inline `$LaTeX$`), NOT as
            // a standalone block: the marker is inserted bare so the emit chokepoint strips it back
            // to the exact pre-drop text, so it is not alone on its paragraph and the standalone
            // renderer would decline it — leaking the raw `x-mde-pending:UUID` URL as visible text.
            // The whole `![name](url)` source is collapsed onto a single anchor char carrying the
            // chip; the rest is zero-widthed. (The resolved image is block-padded on resolve so it
            // embeds normally.) The chip is sized to the line height so it fits inline WHEN the line
            // has other text. Known limitation: if the marker is alone on an otherwise-empty line the
            // whole line collapses to the 0.1pt marker font, so the chip can overflow into the
            // neighboring lines — the same behavior inline `$LaTeX$` alone on a line has.
            if PendingAttachmentMarker.isPendingURL(url) != nil {
                let altStart = NSMaxRange(token.markerRanges[0])
                let altLength = max(token.markerRanges[1].location - altStart, 0)
                let alt = altLength > 0
                    ? ctx.nsText.substring(with: NSRange(location: altStart, length: altLength))
                    : ""
                let pendingConfig = ctx.configuration.imageEmbed
                let containerWidth: CGFloat = {
                    if let tc = ctx.layoutBridge?.firstTextContainer {
                        let w = tc.size.width - tc.lineFragmentPadding * 2
                        if w > 0 && w < pendingConfig.unreasonableMaxWidth { return w }
                    }
                    return pendingConfig.fallbackMaxWidth
                }()
                let chip = PendingAttachmentChip.render(
                    alt: alt,
                    baseFont: ctx.baseFont,
                    mutedText: ctx.configuration.theme.mutedText,   // resolved per-scheme inside render
                    fillColor: ctx.codeBackgroundColor,
                    colorScheme: ctx.colorScheme,
                    maxWidth: min(containerWidth, 260)   // compact — it sits inline within a line
                )
                // Center the chip on the line's cap-height midline (see the inline-draw geometry in
                // `MarkdownTextLayoutFragment.drawLatexImages`, where `bounds.origin.y` is the descent).
                let descent = (chip.size.height - ctx.baseFont.capHeight) / 2
                let chipBounds = CGRect(x: 0, y: descent, width: chip.size.width, height: chip.size.height)
                let anchorRange = NSRange(location: token.range.location, length: 1)
                let anchorChar = ctx.nsText.substring(with: anchorRange)
                attrs.append((anchorRange, [
                    .latexImage: chip,
                    .latexBounds: NSValue(cgRect: chipBounds),
                    .foregroundColor: PlatformColor.clear,
                    .font: ctx.latexMarkerFont,
                    .kern: chip.size.width - HeadingHelpers.textWidth(anchorChar, font: ctx.latexMarkerFont)
                ]))
                if token.range.length > 1 {
                    let restRange = NSRange(location: token.range.location + 1, length: token.range.length - 1)
                    let restText = ctx.nsText.substring(with: restRange)
                    attrs.append((restRange, [
                        .foregroundColor: PlatformColor.clear,
                        .font: ctx.latexMarkerFont,
                        .kern: -HeadingHelpers.textWidth(restText, font: ctx.latexMarkerFont)
                    ]))
                }
                continue
            }

            // Seamless treats an image as one atomic, always-rendered unit, so it
            // must never flip to the "active" dual display (rendered image + dimmed
            // raw `![alt](url)` source). Seamless DOES mark some blocks active now (the
            // block-LaTeX reveal hole, plan 1.2), so this gate is what keeps images out
            // of that set — it force-collapses images regardless of `activeTokenIndices`
            // (also covering stale caches / revealAll→seamless transitions).
            let forceCollapsed = ctx.configuration.markers.visibility == .seamless
            let isActive = ctx.activeTokenIndices.contains(idx) && !forceCollapsed

            let request = EmbeddedImageRequest(reference: url)
            guard let image = ctx.services.images.image(for: request) else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }

            let imageEmbedConfig = ctx.configuration.imageEmbed
            let maxWidth: CGFloat = {
                if let tc = ctx.layoutBridge?.firstTextContainer {
                    let w = tc.size.width - tc.lineFragmentPadding * 2
                    if w > 0 && w < imageEmbedConfig.unreasonableMaxWidth { return w }
                }
                return imageEmbedConfig.fallbackMaxWidth
            }()

            let minWidth = imageEmbedConfig.minimumWidth
            let imageSize = image.size
            let targetWidth = min(max(imageSize.width, minWidth), maxWidth)
            let scale = imageSize.width > 0 ? targetWidth / imageSize.width : 1
            let displayWidth = imageSize.width * scale
            let displayHeight = imageSize.height * scale
            let imageBounds = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)

            let rawContent = ctx.nsText.substring(with: token.range)
            let rendered: Bool
            if isActive {
                rendered = appendRenderedStandaloneBlock(
                    for: token,
                    rawContent: rawContent,
                    image: image,
                    imageBounds: imageBounds,
                    paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                    paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                    alignment: .left,
                    mode: .visibleSource(imageGap: imageEmbedConfig.imageGap),
                    imageEmbedRoundable: true,
                    ctx: ctx,
                    attrs: &attrs
                )
            } else {
                rendered = appendRenderedStandaloneBlock(
                    for: token,
                    rawContent: rawContent,
                    image: image,
                    imageBounds: imageBounds,
                    paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                    paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                    alignment: .left,
                    mode: .collapsedSource(markerTexts: ["![", "]", "(", ")"]),
                    imageEmbedRoundable: true,
                    ctx: ctx,
                    attrs: &attrs
                )
                if rendered {
                    // The standalone helper hides the alt text + the four
                    // markers, but the URL between '(' and ')' is its own
                    // range and stays visible unless we collapse it too.
                    let urlText = ctx.nsText.substring(with: urlRange)
                    attrs.append((urlRange, [
                        .foregroundColor: PlatformColor.clear,
                        .font: ctx.latexMarkerFont,
                        .kern: -HeadingHelpers.textWidth(urlText, font: ctx.latexMarkerFont)
                    ]))
                }
            }
            if !rendered {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }

    // MARK: Image Embeds ![[Name]]

    static func styleImageEmbeds(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .imageEmbed {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            let isActive = ctx.activeTokenIndices.contains(idx)
            let rawContent = ctx.nsText.substring(with: token.contentRange)
            guard let reference = ImageEmbedReference(content: rawContent) else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }

            if let image = EmbeddedImageCache.shared.image(for: reference, services: ctx.services) {
                let imageEmbedConfig = ctx.configuration.imageEmbed
                // Determine max width from text container
                let maxWidth: CGFloat = {
                    if let tc = ctx.layoutBridge?.firstTextContainer {
                        let w = tc.size.width - tc.lineFragmentPadding * 2
                        if w > 0 && w < imageEmbedConfig.unreasonableMaxWidth { return w }
                    }
                    return imageEmbedConfig.fallbackMaxWidth
                }()

                let minWidth = imageEmbedConfig.minimumWidth
                let imageSize = image.size
                let targetWidth: CGFloat
                if let rw = reference.requestedWidth, rw > 0 {
                    targetWidth = min(max(rw, minWidth), maxWidth)
                } else {
                    targetWidth = min(imageSize.width, maxWidth)
                }
                let scale = targetWidth / imageSize.width
                let displayWidth = imageSize.width * scale
                let displayHeight = imageSize.height * scale
                let imageBounds = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
                let rendered: Bool
                if isActive {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .visibleSource(imageGap: imageEmbedConfig.imageGap),
                        imageEmbedRoundable: true,
                        ctx: ctx,
                        attrs: &attrs
                    )
                } else {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .collapsedSource(markerTexts: ["![[", "]]"]),
                        imageEmbedRoundable: true,
                        ctx: ctx,
                        attrs: &attrs
                    )
                }
                if !rendered {
                    appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                }
            } else {
                // Image not found — show syntax with marker coloring (like broken link)
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }
}
