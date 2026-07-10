//
//  PendingAttachmentChip.swift
//  MarkdownEngine
//
//  Renders the static "loading" chip shown in place of an in-flight async drop
//  (`AttachmentDisposition.pending`). The chip is drawn as a `PlatformImage` and hung on the
//  pending marker's `.latexImage` anchor by the image styler — the same slot a resolved image
//  embed uses — so it reuses the existing collapsed-source layout and needs no new render surface.
//
//  Restyle runs on every keystroke / caret move, so the rendered image is CACHED; regenerating it
//  each pass would thrash layout height and CPU. MVP is static; an animated spinner would instead
//  ride the overlay-subview pattern (`WideTableOverlay` / `MarkdownTableScrollView`).
//

import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum PendingAttachmentChip {
    private struct Key: Hashable {
        let alt: String
        let baseFontSize: CGFloat   // drives chipHeight independently of labelFont (which floors at 9pt)
        let fontSize: CGFloat
        let width: Int
        let colorScheme: MarkdownColorScheme
        let text: String
        let fill: String
        let border: String
    }

    private static let lock = NSLock()
    private static var cache: [Key: PlatformImage] = [:]
    /// Hard cap so the process-lifetime cache can't grow without bound (a distinct entry per
    /// filename × width × colors during long upload sessions with window resizing). Chips are
    /// transient and cheap to re-render, so on overflow we simply drop the whole cache rather than
    /// track LRU order — a rare, coarse eviction that keeps the map small.
    private static let cacheCap = 64

    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 3
    private static let symbolGap: CGFloat = 6

    /// A chip image sized to the LINE HEIGHT of `baseFont` (so, rendered inline, it can't overflow
    /// the line and get clipped) and to fit within `maxWidth`. `mutedText` is the theme's (possibly
    /// DYNAMIC) foreground color; it is resolved to a concrete color for `colorScheme` BEFORE alpha
    /// and rasterization — otherwise a dynamic catalog color freezes at the ambient appearance and a
    /// light→dark flip shows the wrong colors. Cached by content + size + scheme.
    static func render(
        alt: String,
        baseFont: PlatformFont,
        mutedText: PlatformColor,
        fillColor: PlatformColor,
        colorScheme: MarkdownColorScheme,
        maxWidth: CGFloat
    ) -> PlatformImage {
        let textColor = resolve(mutedText, for: colorScheme)
        let borderColor = textColor.withAlphaComponent(0.3)
        let resolvedFill = resolve(fillColor, for: colorScheme)
        let chipHeight = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
        let labelFont = PlatformFont.systemFont(
            ofSize: max(min(baseFont.pointSize * 0.78, chipHeight - verticalPadding * 2), 9)
        )
        let key = Key(
            alt: alt,
            baseFontSize: baseFont.pointSize,
            fontSize: labelFont.pointSize,
            width: Int(maxWidth.rounded()),
            colorScheme: colorScheme,
            text: textColor.description,
            fill: resolvedFill.description,
            border: borderColor.description
        )
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        let image = draw(alt: alt, labelFont: labelFont, chipHeight: chipHeight,
                         textColor: textColor, fillColor: resolvedFill, borderColor: borderColor,
                         maxWidth: maxWidth)
        lock.lock()
        if cache.count >= cacheCap { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        lock.unlock()
        return image
    }

    /// Resolve a (possibly dynamic catalog) color to a concrete color for `scheme`, so the raster
    /// doesn't freeze at the ambient appearance. Mirrors `MarkdownStyler+Tables`' resolution.
    private static func resolve(_ color: PlatformColor, for scheme: MarkdownColorScheme) -> PlatformColor {
#if canImport(UIKit)
        return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
#else
        var resolved = color
        scheme.appKitAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
#endif
    }

    private static func draw(
        alt: String,
        labelFont: PlatformFont,
        chipHeight: CGFloat,
        textColor: PlatformColor,
        fillColor: PlatformColor,
        borderColor: PlatformColor,
        maxWidth: CGFloat
    ) -> PlatformImage {
        let labelString = alt.isEmpty ? "Uploading…" : "Uploading “\(alt)”…"

        // `max(0, …)` guards a pathologically tiny base font, where `chipHeight - padding` could go
        // negative and feed a negative-size CGRect to draw.
        let symbolSide = max(0, min(ceil(labelFont.pointSize), chipHeight - verticalPadding * 2))
        let symbol = tintedSymbolImage(named: "arrow.up.circle",
                                       pointSize: labelFont.pointSize, tint: textColor)
        let symbolWidth = symbol != nil ? symbolSide + symbolGap : 0

        let contentHeight = max(0, min(ceil(labelFont.ascender - labelFont.descender), chipHeight - verticalPadding * 2))

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let measured = (labelString as NSString).size(withAttributes: [.font: labelFont]).width

        let chrome = horizontalPadding * 2 + symbolWidth
        let chipWidth = min(ceil(chrome + measured), max(maxWidth, chrome + 24))
        let labelWidth = max(chipWidth - chrome, 0)

        return renderFlippedPlatformImage(size: CGSize(width: chipWidth, height: chipHeight)) {
            let borderInset: CGFloat = 0.5
            let rect = CGRect(x: borderInset, y: borderInset,
                              width: chipWidth - borderInset * 2, height: chipHeight - borderInset * 2)
            let path = platformRoundedRectPath(rect, cornerRadius: chipHeight / 4)
            fillColor.setFill()
            path.fill()
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            var textX = horizontalPadding
            if let symbol {
                symbol.draw(in: CGRect(x: horizontalPadding, y: (chipHeight - symbolSide) / 2,
                                       width: symbolSide, height: symbolSide))
                textX += symbolWidth
            }
            let attributed = NSAttributedString(
                string: labelString,
                attributes: [.font: labelFont, .foregroundColor: textColor, .paragraphStyle: paragraph]
            )
            attributed.draw(in: CGRect(x: textX, y: (chipHeight - contentHeight) / 2,
                                       width: labelWidth, height: contentHeight))
        }
    }
}
