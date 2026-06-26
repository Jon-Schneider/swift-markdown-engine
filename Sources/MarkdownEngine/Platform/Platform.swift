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
