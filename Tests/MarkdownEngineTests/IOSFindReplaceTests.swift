//
//  IOSFindReplaceTests.swift
//  MarkdownEngineTests
//
//  Plan item 2.2 — find/replace on iOS via the system `UIFindInteraction`
//  (iOS 16+), landed as M with documented limitations (the plan's downgrade path).
//
//  The plan feared `UITextView`'s built-in find would mis-land highlights because
//  it searches a longer *source* string. For SINGLE visible tokens that fear is
//  unfounded here: the iOS `textStorage` holds DISPLAY text and seamless markers
//  render zero-width *in place*, so a one-word match highlights the rendered glyphs
//  correctly (verified live: "editable" highlights on the word, not the `**`; and
//  Replace rewrites `**editable**`→`**EDITED**`, markers preserved + restyled bold
//  + written back via `textViewDidChange`).
//
//  KNOWN LIMITATIONS (the markers are still real characters in the search haystack;
//  the system substring search can't see across them, and UITextView's
//  `performTextSearch` is not `open` so it can't be overridden to fix this without
//  a bespoke `UIFindInteraction` + custom `UITextSearching` — deferred):
//   - a query SPANNING a hidden marker finds nothing (e.g. "editable view" across
//     `**editable** view`; "See Page" across `See [[Page]]`);
//   - a query INSIDE a hidden run (inline-link `](url)` tail, image/LaTeX source)
//     matches a zero-width position → invisible highlight.
//  These tests pin BOTH the working single-token behavior and the known gaps.
//
//  iOS-simulator only (UIKit runtime); compiles out on the macOS host and is gated
//  off Mac Catalyst.
//
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("iOS find/replace (2.2)")
struct IOSFindReplaceTests {

    private func makeHostedView(_ markdown: String) -> (window: UIWindow, view: MarkdownUITextView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let view = MarkdownUITextView(configuration: .default)
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.render(markdown: markdown)
        view.layoutIfNeeded()
        return (window, view)
    }

    @Test("The system find interaction is enabled")
    func findInteractionEnabled() {
        let view = MarkdownUITextView(configuration: .default)
        #expect(view.isFindInteractionEnabled)
        #expect(view.findInteraction != nil)
    }

    @Test("presentFind has a navigator to present and does not crash")
    func presentFindSmoke() {
        let (window, view) = makeHostedView("# Title\n\nSome **bold** text to find.")
        _ = window
        // `findInteraction` is the object `presentFind` drives; its presence is the
        // unit-testable guarantee. (Actual navigator presentation + first-responder
        // takeover needs a real app responder chain — `becomeFirstResponder` returns
        // false under headless xctest — and was verified live in the simulator.)
        #expect(view.findInteraction != nil)
        view.presentFind(showingReplace: true)   // must not crash
    }

    @Test("A wiki-link drops its id from the haystack but keeps its brackets")
    func wikiLinkSearchHaystack() {
        // `makeDisplayState` rewrites `[[Name|id]]` → `[[Name]]`: the id leaves the
        // buffer (so it can't be mis-found), but the `[[ ]]` brackets REMAIN (hidden
        // zero-width). So the visible name is findable as a single token, while a
        // phrase crossing a bracket is not (see the limitation test below).
        let (window, view) = makeHostedView("See [[Page Name|id-12345]] for details.")
        _ = window
        #expect(view.text.contains("Page Name"))          // id dropped
        #expect(!view.text.contains("id-12345"))
        #expect(view.text.contains("[[Page Name]]"))       // brackets remain (not `Name`)
    }

    @Test("A single visible word is contiguous in the haystack, so find matches it")
    func singleWordIsSearchable() {
        // `**editable**` keeps its markers in the buffer (rendered zero-width), but
        // the visible word "editable" is contiguous in `text`, so a find for it
        // matches exactly the rendered glyphs (markers sit at zero width beside it).
        let (window, view) = makeHostedView("An **editable** Markdown view.")
        _ = window
        let match = (view.text as NSString).range(of: "editable")
        #expect(match.location != NSNotFound)
        #expect(match.length == 8)   // whole word, not split by the markers
    }

    @Test("KNOWN LIMITATION: a phrase spanning a hidden marker is not in the haystack")
    func phraseAcrossMarkerIsNotFound() {
        // The system substring search sees the raw buffer, where the marker chars sit
        // between the words — so the visible phrase isn't a substring and find yields
        // zero results. Pins the documented downgrade gap; a future custom
        // UITextSearching over marker-stripped text would make these match.
        let (window, view) = makeHostedView("An **editable** view. See [[Page Name]] too.")
        _ = window
        #expect(view.text.range(of: "editable view") == nil)   // across `**`
        #expect(view.text.range(of: "See Page Name") == nil)   // across `[[`
    }

    @Test("A replace on the visible word preserves surrounding markers and writes back")
    func replacePreservesMarkersAndWritesBack() throws {
        // Replaces the visible word via `UITextInput.replace` (the find UI replaces
        // via `UITextSearching.replace`, which funnels through the same text mutation
        // but is not literally this call). Proves the engine's edit pipeline runs on
        // such a replacement: markers preserved + host write-back via the delegate.
        let (window, view) = makeHostedView("An **editable** view.")
        _ = window
        var lastWriteBack: String?
        view.onTextChange = { lastWriteBack = $0 }

        let ns = view.text as NSString
        let wordRange = ns.range(of: "editable")
        let start = try #require(view.position(from: view.beginningOfDocument, offset: wordRange.location))
        let end = try #require(view.position(from: start, offset: wordRange.length))
        let uiRange = try #require(view.textRange(from: start, to: end))
        view.replace(uiRange, withText: "EDITED")

        // Markers preserved around the replacement (only the visible word changed).
        #expect(view.text == "An **EDITED** view.")
        // Host write-back fired with the new text (storage == display here, no wiki-links).
        #expect(lastWriteBack == "An **EDITED** view.")
    }
}
#endif
