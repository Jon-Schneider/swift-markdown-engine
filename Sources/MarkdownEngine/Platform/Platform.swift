//
//  Platform.swift
//  MarkdownEngine
//
//  Cross-platform type aliases that let the shared styling/rendering core name
//  one set of types regardless of UI framework. On macOS each alias *is* the
//  AppKit type (so this layer is a no-op refactor for the existing macOS path);
//  on iOS it resolves to the UIKit twin. See iOS-Support-Plan.md (Phase 0).
//
//  NOTE: this declares the vocabulary only. Where AppKit and UIKit APIs
//  genuinely diverge (e.g. `NSBezierPath.line(to:)` vs `UIBezierPath.addLine(to:)`,
//  or system-color names), the call-site shims live next to the code that needs
//  them and are added as each subsystem is actually ported to iOS — not
//  speculatively here, so the macOS build carries no untested iOS code.
//

#if canImport(UIKit)
import UIKit

public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformImage = UIImage
public typealias PlatformBezierPath = UIBezierPath
public typealias PlatformFontDescriptor = UIFontDescriptor
#else
import AppKit

public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformImage = NSImage
public typealias PlatformBezierPath = NSBezierPath
public typealias PlatformFontDescriptor = NSFontDescriptor
#endif

// MARK: - Cross-platform system colors
//
// AppKit and UIKit spell the dynamic system label/link colors differently
// (`labelColor` vs `label`). These helpers resolve to the right one so shared
// code — including the public `MarkdownEditorTheme` default arguments, which are
// inlined at the embedder's call site and must compile on both platforms — can
// name a single symbol. Each returns the same dynamic catalog color the macOS
// engine used, so the macOS palette is unchanged.
extension PlatformColor {
    /// Primary label color (`labelColor` on AppKit, `label` on UIKit).
    public static var platformLabel: PlatformColor {
        #if canImport(UIKit)
        return .label
        #else
        return .labelColor
        #endif
    }

    /// Secondary label color (`secondaryLabelColor` / `secondaryLabel`).
    public static var platformSecondaryLabel: PlatformColor {
        #if canImport(UIKit)
        return .secondaryLabel
        #else
        return .secondaryLabelColor
        #endif
    }

    /// Tertiary label color (`tertiaryLabelColor` / `tertiaryLabel`).
    public static var platformTertiaryLabel: PlatformColor {
        #if canImport(UIKit)
        return .tertiaryLabel
        #else
        return .tertiaryLabelColor
        #endif
    }

    /// Hyperlink color (`linkColor` on AppKit, `link` on UIKit).
    public static var platformLink: PlatformColor {
        #if canImport(UIKit)
        return .link
        #else
        return .linkColor
        #endif
    }
}

/// The light/dark appearance the styling pipeline should resolve colors under.
///
/// The shared styling core takes this as an explicit input instead of probing
/// the environment (`NSApp.effectiveAppearance` / `traitCollection`), so the
/// styling *logic* is platform-independent and testable. The view-adapter
/// boundary supplies the value: on macOS from the text view's
/// `effectiveAppearance`; on iOS (Phase 2) from `traitCollection` / the SwiftUI
/// environment.
public enum MarkdownColorScheme: Sendable {
    case light
    case dark
}

#if os(macOS)
extension MarkdownColorScheme {
    /// Resolve the scheme from an AppKit appearance, matching the engine's
    /// historical dark-mode test (`bestMatch` against `.darkAqua` / `.aqua`).
    static func resolved(from appearance: NSAppearance) -> MarkdownColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// The AppKit appearance corresponding to this scheme — used by the macOS
    /// table image renderer, which resolves dynamic colors under a concrete
    /// `NSAppearance`. Falls back to the current drawing appearance if the named
    /// appearance can't be constructed.
    var appKitAppearance: NSAppearance {
        let name: NSAppearance.Name = (self == .dark) ? .darkAqua : .aqua
        return NSAppearance(named: name) ?? NSAppearance.currentDrawing()
    }
}
#endif

#if canImport(UIKit)
extension MarkdownColorScheme {
    /// Resolve the scheme from a UIKit trait collection (mirror of the macOS
    /// `NSAppearance` resolver). The view-adapter boundary supplies this on iOS.
    static func resolved(from traits: UITraitCollection) -> MarkdownColorScheme {
        traits.userInterfaceStyle == .dark ? .dark : .light
    }
}

extension NSAttributedString.Key {
    /// AppKit defines `.spellingState` (NSSpellChecker); UIKit does not. The shared
    /// styler marks spelling-disabled ranges with it. Provide an inert iOS twin (same
    /// raw value) so that code compiles cross-platform; the read-only iOS view does no
    /// spell checking, so the attribute is simply unused there.
    static let spellingState = NSAttributedString.Key("NSSpellingState")
}
#endif

// MARK: - Cross-platform font descriptor traits
//
// AppKit spells the bold/italic symbolic traits `.bold`/`.italic`; UIKit spells
// them `.traitBold`/`.traitItalic`, and `withSymbolicTraits(_:)` returns an
// optional on UIKit but not on AppKit. These twins let shared styling code name
// one symbol.
extension PlatformFontDescriptor.SymbolicTraits {
    static var boldTrait: PlatformFontDescriptor.SymbolicTraits {
        #if canImport(UIKit)
        return .traitBold
        #else
        return .bold
        #endif
    }
    static var italicTrait: PlatformFontDescriptor.SymbolicTraits {
        #if canImport(UIKit)
        return .traitItalic
        #else
        return .italic
        #endif
    }
}

extension PlatformFontDescriptor {
    /// Non-optional across platforms (UIKit's `withSymbolicTraits` is optional —
    /// fall back to `self` when the trait combination can't be represented).
    func withSymbolicTraitsCompat(_ traits: PlatformFontDescriptor.SymbolicTraits) -> PlatformFontDescriptor {
        #if canImport(UIKit)
        return withSymbolicTraits(traits) ?? self
        #else
        return withSymbolicTraits(traits)
        #endif
    }
}

#if os(macOS)
extension NSValue {
    /// UIKit names the rect-valued `NSValue` APIs `init(cgRect:)` / `cgRectValue`;
    /// AppKit names them `init(rect:)` / `rectValue` (`NSRect == CGRect`). Provide
    /// the UIKit-spelled twins on macOS so shared code (styler + layout fragment)
    /// can box/read rects with one spelling on both platforms.
    convenience init(cgRect: CGRect) { self.init(rect: cgRect) }
    var cgRectValue: CGRect { rectValue }
}
#endif
