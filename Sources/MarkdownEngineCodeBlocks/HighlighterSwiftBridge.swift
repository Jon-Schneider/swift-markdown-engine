//
//  HighlighterSwiftBridge.swift
//  MarkdownEngineCodeBlocks
//
//  Ready-made SyntaxHighlighter conformance backed by HighlighterSwift.
//

import Foundation
import Highlighter
import MarkdownEngine
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension Notification.Name {
    /// Posted by ``HighlighterSwiftBridge`` after the macOS appearance flips and themes are re-applied; the engine subscribes via ``SyntaxHighlighter/appearanceDidChangeNotification`` to invalidate cached attributes.
    public static let markdownEngineHighlighterDidChangeAppearance =
        Notification.Name("MarkdownEngineHighlighterDidChangeAppearance")
}

/// Drop-in ``SyntaxHighlighter`` backed by HighlighterSwift.
///
/// Defaults match the Nodes app's look: opaque light/dark code-block
/// backgrounds and an `SF Mono → Menlo → system monospace` font chain.
///
/// **Appearance source differs by platform.** On macOS the bridge reads the
/// window/app effective appearance (and, when `autoSwitchAppearance` is `true`,
/// observes `AppleInterfaceThemeChangedNotification`, posting
/// ``Notification/Name/markdownEngineHighlighterDidChangeAppearance``). On iOS
/// there is no `NSApp`; the bridge instead honors the `colorScheme` the engine
/// passes to `backgroundColor(for:)` / `highlight(code:language:colorScheme:)`,
/// and the iOS view re-renders code blocks on a trait change.
public final class HighlighterSwiftBridge: SyntaxHighlighter, @unchecked Sendable {
    private let highlighter: Highlighter?
    private let lightTheme: String
    private let darkTheme: String
    private let autoSwitchAppearance: Bool
    private let lightBackground: PlatformColor
    private let darkBackground: PlatformColor
    private let preferredFontNames: [String]
    private var currentTheme: String = ""

    // HighlighterSwift's JavaScriptCore bridge is expensive — cache by (theme, language, code).
    private let highlightCache = NSCache<NSString, NSAttributedString>()
    private let failedCache = NSCache<NSString, NSNumber>()
    private var unsupportedLanguages: Set<String> = []

    /// Default opaque light-mode code-block background (`calibratedWhite 0.95` on
    /// macOS, the UIKit equivalent on iOS).
    public static var defaultLightBackground: PlatformColor {
        #if os(macOS)
        return NSColor(calibratedWhite: 0.95, alpha: 1.0)
        #else
        return PlatformColor(white: 0.95, alpha: 1.0)
        #endif
    }
    /// Default opaque dark-mode code-block background.
    public static var defaultDarkBackground: PlatformColor {
        #if os(macOS)
        return NSColor(calibratedWhite: 0.13, alpha: 1.0)
        #else
        return PlatformColor(white: 0.13, alpha: 1.0)
        #endif
    }

    /// - Parameters:
    ///   - lightTheme: HighlighterSwift theme name applied in light mode.
    ///   - darkTheme: HighlighterSwift theme name applied in dark mode.
    ///   - autoSwitchAppearance: When `true`, follow the light/dark appearance
    ///     (macOS: observed system appearance; iOS: the engine-supplied scheme).
    ///     Set to `false` to pin to `lightTheme`.
    ///   - lightBackground: Code-block background in light mode. Pass `nil`
    ///     to use HighlighterSwift's CSS-theme background (transparent) instead.
    ///   - darkBackground: Code-block background in dark mode. Pass `nil`
    ///     to use HighlighterSwift's CSS-theme background instead.
    ///   - preferredFontNames: PostScript font names tried in order before
    ///     falling back to the system monospace font.
    public init(
        lightTheme: String = "atom-one-light",
        darkTheme: String = "atom-one-dark",
        autoSwitchAppearance: Bool = true,
        lightBackground: PlatformColor? = HighlighterSwiftBridge.defaultLightBackground,
        darkBackground: PlatformColor? = HighlighterSwiftBridge.defaultDarkBackground,
        preferredFontNames: [String] = ["SF Mono", "Menlo"]
    ) {
        self.highlighter = Highlighter()
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
        self.autoSwitchAppearance = autoSwitchAppearance
        self.lightBackground = lightBackground ?? .clear
        self.darkBackground = darkBackground ?? .clear
        self.preferredFontNames = preferredFontNames
        highlightCache.countLimit = 256
        highlightCache.totalCostLimit = 2_000_000
        failedCache.countLimit = 256
        failedCache.totalCostLimit = 2_000_000

        #if os(macOS)
        applyAppearanceTheme()
        if autoSwitchAppearance {
            DistributedNotificationCenter.default.addObserver(
                forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.applyAppearanceTheme()
                NotificationCenter.default.post(
                    name: .markdownEngineHighlighterDidChangeAppearance,
                    object: nil
                )
            }
        }
        #else
        // iOS: the active theme is selected per call from the engine-supplied scheme.
        applyTheme(lightTheme)
        #endif
    }

    /// Drops the internal highlight cache. Call after manual theme changes the bridge can't observe.
    public func clearCache() {
        highlightCache.removeAllObjects()
        failedCache.removeAllObjects()
    }

    private func applyTheme(_ themeName: String) {
        guard let highlighter, currentTheme != themeName else { return }
        currentTheme = themeName
        highlighter.setTheme(themeName)
        highlightCache.removeAllObjects()
        failedCache.removeAllObjects()
    }

    private func themeName(for colorScheme: MarkdownColorScheme) -> String {
        guard autoSwitchAppearance else { return lightTheme }
        return colorScheme == .dark ? darkTheme : lightTheme
    }

    private func resolvedBackground(for colorScheme: MarkdownColorScheme) -> PlatformColor {
        guard autoSwitchAppearance else { return lightBackground }
        return colorScheme == .dark ? darkBackground : lightBackground
    }

    #if os(macOS)
    private func applyAppearanceTheme() {
        applyTheme(isDarkAppearance() ? darkTheme : lightTheme)
    }

    private func isDarkAppearance() -> Bool {
        guard autoSwitchAppearance else { return false }
        let appearance = NSApp.keyWindow?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    #endif

    // MARK: - SyntaxHighlighter

    public var appearanceDidChangeNotification: Notification.Name? {
        #if os(macOS)
        return autoSwitchAppearance ? .markdownEngineHighlighterDidChangeAppearance : nil
        #else
        // iOS re-renders code blocks when the view's trait collection flips, which
        // re-calls highlight(...) with the new scheme — no global notification needed.
        return nil
        #endif
    }

    public func codeFont(size: CGFloat) -> PlatformFont {
        for name in preferredFontNames {
            if let font = PlatformFont(name: name, size: size) {
                return font
            }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public func backgroundColor(for colorScheme: MarkdownColorScheme) -> PlatformColor {
        #if os(macOS)
        // macOS keeps its window-appearance source (the engine's scheme is derived
        // from the same effectiveAppearance, so the result matches).
        return isDarkAppearance() ? darkBackground : lightBackground
        #else
        return resolvedBackground(for: colorScheme)
        #endif
    }

    public func highlight(code: String, language: String?, colorScheme: MarkdownColorScheme) -> NSAttributedString? {
        #if os(macOS)
        applyAppearanceTheme()
        #else
        applyTheme(themeName(for: colorScheme))
        #endif
        guard let highlighter else { return nil }

        let normalized = language?.lowercased().trimmingCharacters(in: .whitespaces)
        let langKey = (normalized?.isEmpty == false) ? normalized! : "auto"
        let cacheKey = "\(currentTheme)|\(langKey)|\(code)" as NSString

        if let cached = highlightCache.object(forKey: cacheKey) {
            return cached
        }
        if failedCache.object(forKey: cacheKey) != nil {
            return nil
        }

        let explicit = normalized.flatMap { $0.isEmpty ? nil : $0 }
        let skipExplicit = explicit.map { unsupportedLanguages.contains($0) } ?? false

        var highlighted: NSAttributedString?
        if let lang = explicit, !skipExplicit {
            highlighted = highlighter.highlight(code, as: lang)
            if highlighted == nil {
                // Unknown language — remember and fall back to auto-detect.
                unsupportedLanguages.insert(lang)
                highlighted = highlighter.highlight(code)
            }
        } else {
            highlighted = highlighter.highlight(code)
        }

        // Immutable copy so the cached entry can't be mutated by callers.
        let result = highlighted.map { NSAttributedString(attributedString: $0) }
        if let result {
            highlightCache.setObject(result, forKey: cacheKey, cost: code.utf16.count)
            failedCache.removeObject(forKey: cacheKey)
            return result
        }
        failedCache.setObject(NSNumber(value: true), forKey: cacheKey, cost: code.utf16.count)
        return nil
    }
}
