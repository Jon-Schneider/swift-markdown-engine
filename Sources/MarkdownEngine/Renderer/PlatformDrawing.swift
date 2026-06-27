//
//  PlatformDrawing.swift
//  MarkdownEngine
//
//  Call-site drawing shims for the places where AppKit and UIKit genuinely diverge,
//  used by the cross-platform `MarkdownTextLayoutFragment` draw helpers. `Platform.swift`
//  declares the type vocabulary; these are the behavioral shims it intentionally
//  defers to the subsystem that needs them.
//
//  Each shim reproduces the exact macOS behavior on macOS, so the fragment port is a
//  no-op refactor there; the iOS branch mirrors it with the UIKit equivalent (the
//  context/flip half is already validated by the Phase 0.5 + UITextView spikes).
//

import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Run `body` with a top-left / y-down drawing context current, so the fragment's
/// y-down geometry (`point.y + tb.origin.y`) draws upright on both platforms.
///
/// macOS: wrap the CGContext in a `flipped: true` `NSGraphicsContext` (the original
/// idiom). iOS: the `draw(at:in:)` context is already top-left, so just push it as
/// the current UIKit context (Path A from the spike).
func withFlippedDrawingContext(_ cg: CGContext, _ body: () -> Void) {
#if canImport(UIKit)
    UIGraphicsPushContext(cg)
    defer { UIGraphicsPopContext() }
    body()
#else
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    body()
#endif
}

/// Fill `outerRect` minus `cutouts` using the current fill color and the even-odd
/// rule — used to punch active text-selection rects out of the code-block background
/// so the system selection highlight stays visible. Caller sets the fill color first.
func fillEvenOdd(outerRect: CGRect, cutouts: [CGRect]) {
#if canImport(UIKit)
    let path = UIBezierPath(rect: outerRect)
    path.usesEvenOddFillRule = true
    for r in cutouts { path.append(UIBezierPath(rect: r)) }
    path.fill()
#else
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    path.appendRect(outerRect)
    for r in cutouts { path.appendRect(r) }
    path.fill()
#endif
}

extension PlatformColor {
    /// RGB components in a device/extended-RGB space, or nil if the color can't be
    /// converted. Used for the tolerance compare in `isCodeBlockBackgroundColor`.
    var rgbComponents: (red: CGFloat, green: CGFloat, blue: CGFloat)? {
#if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (r, g, b)
#else
        guard let c = usingColorSpace(.deviceRGB) else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent)
#endif
    }
}

/// A tinted SF Symbol image at the given point size, or nil if the symbol is missing.
/// The tint is applied explicitly (`.alwaysOriginal` on iOS, hierarchical on macOS)
/// so a template symbol doesn't inherit the surrounding context fill — the checkbox
/// tint caveat the spike flagged.
func tintedSymbolImage(named name: String, pointSize: CGFloat, tint: PlatformColor) -> PlatformImage? {
#if canImport(UIKit)
    let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    return UIImage(systemName: name)?
        .applyingSymbolConfiguration(config)?
        .withTintColor(tint, renderingMode: .alwaysOriginal)
#else
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let sizeConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: tint)
    let symbolConfig = sizeConfig.applying(colorConfig)
    return base.withSymbolConfiguration(symbolConfig) ?? base
#endif
}
