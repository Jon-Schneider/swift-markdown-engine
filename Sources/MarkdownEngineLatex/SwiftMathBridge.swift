//
//  SwiftMathBridge.swift
//  MarkdownEngineLatex
//
//  Ready-made LatexRenderer conformance backed by SwiftMath.
//

import Foundation
import SwiftMath
import MarkdownEngine
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A drop-in ``LatexRenderer`` backed by [SwiftMath].
///
/// Renders both block (`$$ … $$`) and inline (`$ … $`) LaTeX strings into
/// `PlatformImage`s using the Latin Modern math font. Results are cached per
/// (latex, font size, scheme, theme color fingerprint).
///
/// Light/dark is taken from the host window's effective appearance on macOS, and
/// from the engine-supplied `colorScheme` on iOS (there is no `NSApp` to probe).
///
/// [SwiftMath]: https://github.com/mgriebling/SwiftMath
public final class SwiftMathBridge: LatexRenderer, @unchecked Sendable {
    private struct CacheKey: Hashable {
        let latex: String
        let fontSize: CGFloat
        let isDarkMode: Bool
        let lightColorRGB: UInt32
        let darkColorRGB: UInt32
    }

    private struct CacheEntry {
        let image: PlatformImage
        let size: CGSize
        let baselineOffset: CGFloat
    }

    private let singleLetterPaddingBottom: CGFloat
    private var cache: [CacheKey: CacheEntry] = [:]
    private let cacheLock = NSLock()

    /// - Parameter singleLetterPaddingBottom: Extra bottom padding (in
    ///   points) added to single-letter formulas to prevent visual
    ///   clipping; matches the engine's
    ///   ``MarkdownEditorConfiguration/blockLatex/singleLetterPaddingBottom``
    ///   default. Override to match a customized configuration.
    public init(singleLetterPaddingBottom: CGFloat = 1.0) {
        self.singleLetterPaddingBottom = singleLetterPaddingBottom
    }

    /// Clears the rendered-image cache. Call after appearance flips if
    /// the host code doesn't re-render formulas automatically.
    public func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - LatexRenderer

    public func render(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme,
        colorScheme: MarkdownColorScheme
    ) -> LatexRenderResult? {
        let normalizedLatex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLatex.isEmpty else { return nil }

        #if os(macOS)
        // macOS keeps its window-appearance source (matches the engine's scheme,
        // which is derived from the same effectiveAppearance).
        let appearance = NSApp.keyWindow?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #else
        let isDarkMode = colorScheme == .dark
        #endif

        let textColor = isDarkMode ? theme.latexDarkModeText : theme.latexLightModeText
        let key = CacheKey(
            latex: normalizedLatex,
            fontSize: fontSize,
            isDarkMode: isDarkMode,
            lightColorRGB: Self.colorFingerprint(theme.latexLightModeText),
            darkColorRGB: Self.colorFingerprint(theme.latexDarkModeText)
        )

        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return LatexRenderResult(
                image: cached.image,
                size: cached.size,
                baselineOffset: cached.baselineOffset
            )
        }
        cacheLock.unlock()

        guard let entry = renderLatex(normalizedLatex, fontSize: fontSize, textColor: textColor) else {
            return nil
        }

        cacheLock.lock()
        cache[key] = entry
        cacheLock.unlock()

        return LatexRenderResult(
            image: entry.image,
            size: entry.size,
            baselineOffset: entry.baselineOffset
        )
    }

    // MARK: - Private

    /// Fold a `PlatformColor` to a 24-bit fingerprint that's good enough to
    /// bust the cache when the theme changes the LaTeX text color.
    private static func colorFingerprint(_ color: PlatformColor) -> UInt32 {
        var rc: CGFloat = 0, gc: CGFloat = 0, bc: CGFloat = 0
        #if os(macOS)
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        rc = rgb.redComponent; gc = rgb.greenComponent; bc = rgb.blueComponent
        #else
        var ac: CGFloat = 0
        guard color.getRed(&rc, green: &gc, blue: &bc, alpha: &ac) else { return 0 }
        #endif
        let r = UInt32(max(0, min(255, Int(rc * 255))))
        let g = UInt32(max(0, min(255, Int(gc * 255))))
        let b = UInt32(max(0, min(255, Int(bc * 255))))
        return (r << 16) | (g << 8) | b
    }

    private func renderLatex(_ latex: String, fontSize: CGFloat, textColor: PlatformColor) -> CacheEntry? {
        let mathLabel = MTMathUILabel()
        mathLabel.latex = latex
        mathLabel.fontSize = fontSize
        mathLabel.textColor = textColor
        mathLabel.textAlignment = .left
        mathLabel.labelMode = .text

        // Latin Modern Math gives the cleanest LaTeX glyphs at typical sizes.
        if let mathFont = MTFontManager().font(withName: "latinmodern-math", size: fontSize) {
            mathLabel.font = mathFont
        }

        forceLayout(mathLabel)

        guard let displayList = mathLabel.displayList else { return nil }

        // SwiftMath skips unsupported glyphs (e.g. emoji/raw Greek), which can yield
        // zero-sized output. Bail instead of trying to render a 0x0 image.
        let exactWidth = displayList.width
        let exactHeight = displayList.ascent + displayList.descent
        guard exactWidth > 0, exactHeight > 0 else { return nil }

        let isSimpleSingleLetter = latex.range(of: #"^[A-Za-z]{1,3}$"#, options: .regularExpression) != nil
        let paddingBottom: CGFloat = isSimpleSingleLetter ? singleLetterPaddingBottom : 0
        let canvasHeight = exactHeight + paddingBottom

        // `displayList.width` is the advance width, which excludes the right-side ink
        // overhang of slanted glyphs (V, Y, P, F, …) — cropping to it clips them.
        // Render with right slack, then crop to the measured ink edge.
        let rightSlack = ceil(fontSize)
        let probeWidth = ceil(exactWidth) + rightSlack

        guard let probeCG = renderProbeCGImage(mathLabel, size: CGSize(width: probeWidth, height: canvasHeight)) else {
            return nil
        }

        let inkRight = Self.inkRightEdge(probeCG, widthInPoints: probeWidth) ?? exactWidth
        let finalWidth = max(ceil(exactWidth), ceil(inkRight))
        let finalSize = CGSize(width: finalWidth, height: canvasHeight)

        // Crop to the measured width (full height kept); points→pixels via the probe,
        // so this is correct at any backing scale.
        let pxPerPoint = CGFloat(probeCG.width) / probeWidth
        let cropPx = min(probeCG.width, Int((finalWidth * pxPerPoint).rounded()))
        guard cropPx > 0,
              let croppedCG = probeCG.cropping(to: CGRect(x: 0, y: 0, width: cropPx, height: probeCG.height)) else {
            return nil
        }

        let image = makeImage(from: croppedCG, pointSize: finalSize, pxPerPoint: pxPerPoint)
        return CacheEntry(
            image: image,
            size: finalSize,
            baselineOffset: displayList.descent
        )
    }

    // MARK: - Platform rendering

    private func forceLayout(_ label: MTMathUILabel) {
        #if canImport(UIKit)
        label.setNeedsLayout()
        label.layoutIfNeeded()
        #else
        label.layoutSubtreeIfNeeded()
        #endif
    }

    /// Render `label` into a CGImage at `size` (points) and the platform's backing scale.
    private func renderProbeCGImage(_ label: MTMathUILabel, size: CGSize) -> CGImage? {
        label.frame = CGRect(origin: .zero, size: size)
        forceLayout(label)
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            label.layer.render(in: ctx.cgContext)
        }
        return image.cgImage
        #else
        // `bitmapImageRepForCachingDisplay` + `cacheDisplay(in:to:)` is the
        // documented way to snapshot an NSView that isn't in a window.
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: rep)
        return rep.cgImage
        #endif
    }

    private func makeImage(from cgImage: CGImage, pointSize: CGSize, pxPerPoint: CGFloat) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage, scale: max(1, pxPerPoint), orientation: .up)
        #else
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
        #endif
    }

    /// Right-most x (in points) containing non-transparent ink, or `nil` if empty —
    /// lets us crop a formula to its true ink width instead of the advance width.
    private static func inkRightEdge(_ image: CGImage, widthInPoints: CGFloat) -> CGFloat? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0, widthInPoints > 0 else { return nil }

        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &data, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Scan each row from the right, stopping once we pass the running max.
        var maxX = -1
        for y in 0..<h {
            let row = y * bytesPerRow
            var x = w - 1
            while x > maxX {
                if data[row + x * 4 + 3] > 10 { maxX = x; break }
                x -= 1
            }
        }
        guard maxX >= 0 else { return nil }

        // +1: pixel `maxX` spans [maxX, maxX+1). Convert to points.
        return (CGFloat(maxX) + 1) * widthInPoints / CGFloat(w)
    }
}
