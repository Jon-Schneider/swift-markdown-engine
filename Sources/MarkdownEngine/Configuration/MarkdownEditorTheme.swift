//
//  MarkdownEditorTheme.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Color palette for the Markdown editor engine.
//
//  All user-visible colors used by the engine are routed through this
//  struct. Defaults map to system colors so the editor adapts to light/
//  dark mode automatically. Embedders that want a custom palette (for
//  example, a sepia or high-contrast preset) can replace any subset of
//  the colors without touching engine source files.
//

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import Foundation

// MARK: - Theme

/// Color palette consumed by the Markdown editor engine.
///
/// Every color the engine puts on screen is read from this struct, so a
/// single override is enough to retheme the entire editor. The defaults
/// reproduce a system-native macOS look using `NSColor` dynamic system
/// colors, so light/dark-mode switching keeps working without extra code.
public struct MarkdownEditorTheme: Sendable {

    // MARK: Text colors

    /// Foreground color for plain body text and the typing caret.
    public var bodyText: PlatformColor
    /// Foreground color for de-emphasized text and most syntax markers.
    /// Defaults to `secondaryLabelColor` so it tracks the system style.
    public var mutedText: PlatformColor
    /// Foreground color for content the engine wants to deemphasize further
    /// than `mutedText` — for example, broken wiki-links.
    public var disabledText: PlatformColor
    /// Foreground color for ordered-list numbers (`1.`, `2.`, …). `nil` (the
    /// default) leaves them at ``bodyText``; set it to tint numbers the way
    /// Apple Notes does.
    public var orderedListNumberColor: PlatformColor?
    /// Foreground color for heading marker glyphs (`#`, `##`, …).
    public var headingMarker: PlatformColor
    /// Fill color for unordered-list bullet glyphs. `nil` (the default) falls
    /// back to ``bodyText`` so the bullet tracks body ink; set it to give
    /// bullets their own color (e.g. Apple Notes' muted gray dot).
    public var bulletColor: PlatformColor?
    /// Fill color for the vertical blockquote bar. `nil` (the default) falls
    /// back to ``mutedText`` at 50% alpha — the historical look; set it to
    /// pin the bar to a specific color/alpha.
    public var blockquoteBarColor: PlatformColor?
    /// Tint for a checked task checkbox. `nil` (the default) falls back to
    /// ``bodyText``. Apple Notes uses a warm yellow (`.systemYellow`).
    public var checkboxCheckedTint: PlatformColor?
    /// Tint for an unchecked task checkbox. `nil` (the default) falls back to
    /// ``mutedText``.
    public var checkboxUncheckedTint: PlatformColor?
    /// Foreground color applied to the text of a COMPLETED task item (in
    /// addition to the strikethrough). `nil` (the default) leaves the text at
    /// its normal color, matching historical behavior; set it to dim completed
    /// items the way Apple Notes does (e.g. ``mutedText``).
    public var completedTaskText: PlatformColor?

    // MARK: Links

    /// Foreground color for hyperlinks that resolve to an URL.
    public var link: PlatformColor
    /// Foreground color for incomplete `[text]` patterns (no URL yet).
    public var incompleteLink: PlatformColor

    // MARK: Find / search highlights

    /// Background color used to highlight all matches when the user is
    /// running an in-document search.
    ///
    /// The default is `.systemYellow` so embedders that don't customize
    /// this still get a sensible result. Apps with their own brand color
    /// (for example, the Nodes app uses its custom yellow) should override
    /// this to match their palette.
    public var findMatchHighlight: PlatformColor
    /// Background color used to highlight the currently-focused match
    /// during in-document search. Typically a stronger version of
    /// ``findMatchHighlight``.
    public var findCurrentMatchHighlight: PlatformColor

    // MARK: LaTeX rendering

    /// Foreground color used when rendering LaTeX formulas in light mode.
    public var latexLightModeText: PlatformColor
    /// Foreground color used when rendering LaTeX formulas in dark mode.
    public var latexDarkModeText: PlatformColor

    // MARK: Strikethrough / decoration

    /// Stroke color used for strikethrough decorations
    /// (e.g. completed task list items, horizontal rules).
    public var strikethroughColor: PlatformColor

    // MARK: Init

    public init(
        bodyText: PlatformColor = .platformLabel,
        mutedText: PlatformColor = .platformSecondaryLabel,
        disabledText: PlatformColor = .platformTertiaryLabel,
        orderedListNumberColor: PlatformColor? = nil,
        headingMarker: PlatformColor = .gray,
        bulletColor: PlatformColor? = nil,
        blockquoteBarColor: PlatformColor? = nil,
        checkboxCheckedTint: PlatformColor? = nil,
        checkboxUncheckedTint: PlatformColor? = nil,
        completedTaskText: PlatformColor? = nil,
        link: PlatformColor = .platformLink,
        incompleteLink: PlatformColor = .systemBlue,
        findMatchHighlight: PlatformColor = .systemYellow,
        findCurrentMatchHighlight: PlatformColor = .systemYellow,
        latexLightModeText: PlatformColor = .black,
        latexDarkModeText: PlatformColor = .white,
        strikethroughColor: PlatformColor = .platformLabel
    ) {
        self.bodyText = bodyText
        self.mutedText = mutedText
        self.disabledText = disabledText
        self.orderedListNumberColor = orderedListNumberColor
        self.headingMarker = headingMarker
        self.bulletColor = bulletColor
        self.blockquoteBarColor = blockquoteBarColor
        self.checkboxCheckedTint = checkboxCheckedTint
        self.checkboxUncheckedTint = checkboxUncheckedTint
        self.completedTaskText = completedTaskText
        self.link = link
        self.incompleteLink = incompleteLink
        self.findMatchHighlight = findMatchHighlight
        self.findCurrentMatchHighlight = findCurrentMatchHighlight
        self.latexLightModeText = latexLightModeText
        self.latexDarkModeText = latexDarkModeText
        self.strikethroughColor = strikethroughColor
    }

    // MARK: Resolved (derived) colors

    /// The effective bullet color: ``bulletColor`` when set, otherwise
    /// ``bodyText``. Renderers should read this rather than re-deriving the
    /// fallback, so the "all colors route through the theme" contract holds.
    public var resolvedBulletColor: PlatformColor {
        bulletColor ?? bodyText
    }

    /// The effective blockquote bar color: ``blockquoteBarColor`` when set,
    /// otherwise ``mutedText`` at 50% alpha (the historical derivation). This
    /// keeps the `0.5` factor in the theme — where colors are owned — instead
    /// of buried in the layout-fragment renderer.
    public var resolvedBlockquoteBarColor: PlatformColor {
        blockquoteBarColor ?? mutedText.withAlphaComponent(0.5)
    }

    /// Effective checked-checkbox tint: ``checkboxCheckedTint`` when set, else
    /// ``bodyText`` (the historical tint).
    public var resolvedCheckboxCheckedTint: PlatformColor {
        checkboxCheckedTint ?? bodyText
    }

    /// Effective unchecked-checkbox tint: ``checkboxUncheckedTint`` when set,
    /// else ``mutedText`` (the historical tint).
    public var resolvedCheckboxUncheckedTint: PlatformColor {
        checkboxUncheckedTint ?? mutedText
    }

    /// System-native palette built from `NSColor` dynamic system colors.
    ///
    /// Use this if you want the engine to look like a stock macOS
    /// `NSTextView`. It's also the default when no theme is supplied.
    public static let `default` = MarkdownEditorTheme()
}
