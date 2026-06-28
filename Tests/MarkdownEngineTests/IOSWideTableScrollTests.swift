//
//  IOSWideTableScrollTests.swift
//  MarkdownEngineTests
//
//  Verify-test for plan item 2.3 — wide-table horizontal scroll on iOS. The
//  overlay (`MarkdownTableScrollView`, a `UIScrollView`) is already implemented;
//  this proves the acceptance against the live view: a wider-than-viewport table
//  gets an overlay whose content is wider than its frame (so it scrolls sideways),
//  while a table that fits gets none.
//
//  UIKit-runtime behavior (TextKit-2 layout + overlay reconciliation), so this is
//  `#if canImport(UIKit)` and runs only on the iOS simulator
//  (`xcodebuild test -scheme MarkdownEngine-Package -destination 'platform=iOS Simulator,…'`).
//  It compiles out on the macOS host.
//
// Not `targetEnvironment(macCatalyst)`: `canImport(UIKit)` is also true on Catalyst,
// but `UIWindow(frame:)` here crashes Catalyst xctest ("NSApplication has not been
// created yet"). These suites are for the iOS simulator only.
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("iOS wide-table horizontal scroll (2.3)")
struct IOSWideTableScrollTests {

    /// 8 columns of 6-digit cells — far wider than a phone-width viewport. The
    /// surrounding Intro/Outro paragraphs are load-bearing, but NOT because the
    /// styler needs paragraph boundaries (a lone-table document styles fine). They
    /// keep the *default caret* (location 0 after `render`) OUTSIDE the table token,
    /// so `styleTables` sees the table as INACTIVE and emits the rendered,
    /// `.collapsedSourceScrollable` overlay. A table that is the entire document
    /// would put the caret inside it → ACTIVE → editable-source branch → no overlay
    /// (by design: caret-in-block reveals source). So this also pins the realistic
    /// "table among prose" case rather than a degenerate single-table doc.
    private let wideTable = """
    Intro paragraph before the table.

    | AAAAAA | BBBBBB | CCCCCC | DDDDDD | EEEEEE | FFFFFF | GGGGGG | HHHHHH |
    |--------|--------|--------|--------|--------|--------|--------|--------|
    | 111111 | 222222 | 333333 | 444444 | 555555 | 666666 | 777777 | 888888 |
    | 121212 | 343434 | 565656 | 787878 | 909090 | 010101 | 232323 | 454545 |

    Outro paragraph after the table.
    """

    /// Host the view in a real key window so TextKit-2 runs an actual layout pass
    /// (a window-less `UITextView` never sizes its text container, so the table
    /// would style against the 500pt fallback width and skip the overlay). The
    /// returned window must be retained by the caller for the view to stay laid out.
    private func makeHostedView(width: CGFloat, _ markdown: String) -> (window: UIWindow, view: MarkdownUITextView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 700))
        let view = MarkdownUITextView(configuration: .default)
        view.frame = window.bounds
        // Pin Dynamic Type: the wide/narrow threshold compares the rendered table
        // width against the container width, and `scaledFontSize()` scales off the
        // content-size category — an accessibility-sized simulator could otherwise
        // flip the decision. `.large` is the system default.
        if #available(iOS 17.0, *) { view.traitOverrides.preferredContentSizeCategory = .large }
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()            // establish the real container width
        view.render(markdown: markdown)
        view.layoutIfNeeded()
        // Re-style now that text is laid out at the final container width, so the
        // `.scrollableBlock*` attributes reflect this viewport.
        view.restyleNowForTesting()
        // Reconcile synchronously (the test can't spin the coalesced runloop tick).
        view.performTableScrollOverlayUpdate()
        return (window, view)
    }

    @Test("A wider-than-viewport table gets a horizontally-scrollable overlay")
    func wideTableCreatesScrollableOverlay() throws {
        let (window, view) = makeHostedView(width: 320, wideTable)   // narrow viewport
        _ = window
        #expect(!view.tableScrollOverlays.isEmpty, "a wide table should get a scroll overlay")
        let overlay = try #require(view.tableScrollOverlays.values.first)
        // The overlay's content (the full table image) is wider than its on-screen
        // frame — that is exactly what makes it scroll sideways.
        #expect(overlay.contentSize.width > overlay.bounds.width)
        #expect(overlay.bounds.width > 0)
    }

    @Test("A narrow table that fits the viewport gets no scroll overlay")
    func narrowTableNoOverlay() {
        // Wrap in prose so the default caret (offset 0) lands OUTSIDE the table →
        // the table is the INACTIVE, *rendered* token. Without this the lone table
        // would be active (editable source, never an overlay) and the assertion
        // would pass vacuously — it must fail if a fitting table wrongly overlays.
        let narrow = """
        Intro paragraph.

        | A | B |
        |---|---|
        | 1 | 2 |

        Outro paragraph.
        """
        let (window, view) = makeHostedView(width: 600, narrow)   // roomy viewport
        _ = window
        #expect(view.tableScrollOverlays.isEmpty, "a table that fits needs no overlay")
    }

    @Test("Loading a document without the wide table tears its overlay down")
    func overlayRemovedOnDocumentChange() {
        let (window, view) = makeHostedView(width: 320, wideTable)
        _ = window
        #expect(!view.tableScrollOverlays.isEmpty)
        // Re-render plain text: the reconcile should drop every overlay.
        view.render(markdown: "just a paragraph, no tables here")
        view.layoutIfNeeded()
        view.restyleNowForTesting()
        view.performTableScrollOverlayUpdate()
        #expect(view.tableScrollOverlays.isEmpty)
    }
}
#endif
