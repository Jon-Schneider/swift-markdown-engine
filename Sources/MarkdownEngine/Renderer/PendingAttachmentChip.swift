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
        let fontSize: CGFloat
        let width: Int
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
    private static let verticalPadding: CGFloat = 6
    private static let symbolGap: CGFloat = 6

    /// A chip image sized to fit within `maxWidth`. Colors are passed in resolved (from the
    /// editor theme) so the renderer stays free-function/testable and the cache key can capture
    /// them. Cached by content + size + colors.
    static func render(
        alt: String,
        baseFont: PlatformFont,
        textColor: PlatformColor,
        fillColor: PlatformColor,
        borderColor: PlatformColor,
        maxWidth: CGFloat
    ) -> PlatformImage {
        let labelFont = PlatformFont.systemFont(ofSize: max(baseFont.pointSize * 0.9, 11))
        let key = Key(
            alt: alt,
            fontSize: labelFont.pointSize,
            width: Int(maxWidth.rounded()),
            text: textColor.description,
            fill: fillColor.description,
            border: borderColor.description
        )
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        let image = draw(alt: alt, labelFont: labelFont, textColor: textColor,
                         fillColor: fillColor, borderColor: borderColor, maxWidth: maxWidth)
        lock.lock()
        if cache.count >= cacheCap { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        lock.unlock()
        return image
    }

    private static func draw(
        alt: String,
        labelFont: PlatformFont,
        textColor: PlatformColor,
        fillColor: PlatformColor,
        borderColor: PlatformColor,
        maxWidth: CGFloat
    ) -> PlatformImage {
        let labelString = alt.isEmpty ? "Uploading…" : "Uploading “\(alt)”…"

        let symbolSide = ceil(labelFont.pointSize)
        let symbol = tintedSymbolImage(named: "arrow.up.circle",
                                       pointSize: labelFont.pointSize, tint: textColor)
        let symbolWidth = symbol != nil ? symbolSide + symbolGap : 0

        let contentHeight = ceil(labelFont.ascender - labelFont.descender)
        let chipHeight = contentHeight + verticalPadding * 2

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: textColor]
        let measured = (labelString as NSString).size(withAttributes: labelAttrs).width

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
                let symbolY = (chipHeight - symbolSide) / 2
                symbol.draw(in: CGRect(x: horizontalPadding, y: symbolY, width: symbolSide, height: symbolSide))
                textX += symbolWidth
            }
            let labelString2 = NSAttributedString(
                string: labelString,
                attributes: [.font: labelFont, .foregroundColor: textColor, .paragraphStyle: paragraph]
            )
            labelString2.draw(in: CGRect(x: textX, y: verticalPadding, width: labelWidth, height: contentHeight))
        }
    }
}
