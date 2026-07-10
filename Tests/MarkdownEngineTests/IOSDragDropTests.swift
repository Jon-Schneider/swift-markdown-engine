//
//  IOSDragDropTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for the iOS drop interception. The editor keeps `UITextView`'s built-in drop
//  interaction (so intra-view text MOVE + drop-caret survive) and substitutes per-item content
//  via `UITextPasteDelegate`, so a dropped image/file can't land as an `NSTextAttachment` /
//  attributed text (the U+FFFC corruption). These tests drive the pure routing/materialization
//  seams the transform is built from, assert the delegates are actually wired, and cover the
//  paste-disposition migration. UITextPasteItem has no public initializer, so the transform
//  itself is exercised through those seams rather than a synthetic paste item.
//
//  UIKit-runtime behaviors → iOS simulator only; compiles out on the macOS host.
//
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import UniformTypeIdentifiers
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("iOS drop interception & paste disposition")
struct IOSDragDropTests {

    private func makeLaidOutView(_ markdown: String, isEditable: Bool = true) -> MarkdownUITextView {
        let view = MarkdownUITextView(configuration: .default, isEditable: isEditable)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        if #available(iOS 17.0, *) { view.traitOverrides.preferredContentSizeCategory = .large }
        view.render(markdown: markdown)
        view.layoutIfNeeded()
        view.establishCaretForTesting()
        return view
    }

    private func imageProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = "photo"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(Data([0x1, 0x2]), nil)
            return nil
        }
        return provider
    }

    private func pdfProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = "report"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { completion in
            completion(Data([0x25, 0x50]), nil)
            return nil
        }
        return provider
    }

    private func imageItem() -> DroppedItem {
        DroppedItem(data: Data([0x1]), fileURL: nil, suggestedName: "image", isImage: true, type: .png)
    }

    // MARK: - Delegate wiring (the built-in interaction must stay, transform must be ours)

    @Test("The built-in drop interaction is retained and our paste/drop delegates are wired")
    func delegatesWired() {
        let view = makeLaidOutView("x")
        #expect(view.textDropInteraction != nil, "the built-in interaction must NOT be removed (preserves move)")
        #expect(view.textDropDelegate === view)
        #expect(view.pasteDelegate === view)
    }

    // MARK: - dropPlan routing

    @Test("An image item routes to an image attachment")
    func imageRoutesToAttachment() {
        let view = makeLaidOutView("x")
        #expect(view.dropPlan(for: imageProvider(), isLocal: false)
                == .attachment(isImage: true, typeID: UTType.png.identifier, suggestedName: "photo"))
    }

    @Test("A non-image file routes to a file attachment")
    func fileRoutesToAttachment() {
        let view = makeLaidOutView("x")
        #expect(view.dropPlan(for: pdfProvider(), isLocal: false)
                == .attachment(isImage: false, typeID: UTType.pdf.identifier, suggestedName: "report"))
    }

    @Test("A local text drag keeps the native move; external text is forced to plain")
    func textRoutingDependsOnLocality() {
        let view = makeLaidOutView("x")
        let text = NSItemProvider(object: "hello" as NSString)
        #expect(view.dropPlan(for: text, isLocal: true) == .moveDefault,
                "a local drag must keep MOVE semantics")
        #expect(view.dropPlan(for: text, isLocal: false) == .plainText,
                "external text is forced to plain so a rich drag can't insert an attachment")
    }

    @Test("Move eligibility is a plain-text-ONLY allowlist (rich/url/image providers are copies)")
    func moveEligibilityIsPlainTextAllowlist() {
        let view = makeLaidOutView("x")
        // Pure text → eligible for the native move.
        #expect(view.isPlainTextItem(NSItemProvider(object: "hello" as NSString)) == true)
        // A URL (even one that also vends a text rep) must be a copy, not a move — otherwise a
        // local URL drag from another view could delete its source.
        let urlWithText = NSItemProvider(object: NSURL(string: "https://example.com")!)
        urlWithText.registerObject("https://example.com" as NSString, visibility: .all)
        #expect(view.isPlainTextItem(urlWithText) == false, "a URL provider is a copy, not a move")
        // An image is an attachment, never a move.
        #expect(view.isPlainTextItem(imageProvider()) == false)
        // A RICH provider that ALSO vends NSString (Codex's case) must NOT be move-eligible —
        // `setDefaultResult` on it could insert an attachment. This is why a blacklist is unsafe.
        let rtfWithText = NSItemProvider()
        rtfWithText.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { completion in
            completion(Data([0x7B]), nil)
            return nil
        }
        rtfWithText.registerObject("styled" as NSString, visibility: .all)
        #expect(view.isPlainTextItem(rtfWithText) == false, "a rich (RTF) provider is a copy, not a move")
        // A PDF that also vends text — likewise a copy.
        #expect(view.isPlainTextItem(pdfProvider()) == false)
        // An UNRECOGNIZED custom UTI alongside NSString must NOT qualify: an unresolved
        // identifier can't be assumed plain text (it could be a rich custom representation).
        let customWithText = NSItemProvider()
        customWithText.registerDataRepresentation(forTypeIdentifier: "com.example.unknown.customtype",
                                                  visibility: .all) { completion in
            completion(Data([0x0]), nil)
            return nil
        }
        customWithText.registerObject("text rep" as NSString, visibility: .all)
        #expect(view.isPlainTextItem(customWithText) == false,
                "an unrecognized custom UTI must not be waved through as plain text")
    }

    @Test("A web-URL drop routes to text (not a file attachment, not discarded)")
    func urlRoutesToText() {
        let view = makeLaidOutView("x")
        let url = NSItemProvider(object: NSURL(string: "https://example.com/page")!)
        let plan = view.dropPlan(for: url, isLocal: false)
        // Depending on whether the URL provider also vends an NSString, it lands as either
        // .urlText or .plainText — both insert the URL as text. It must NOT be treated as a
        // file attachment or skipped (the bug Codex flagged: a bare public.url being lost).
        #expect(plan == .urlText || plan == .plainText,
                "a web URL must insert as text, got \(plan)")
    }

    // MARK: - dropResultString (disposition → inserted string)

    @Test("Disposition maps to the inserted string: insert wraps, everything else inserts nothing")
    func dispositionMapping() {
        let item = imageItem()
        #expect(MarkdownUITextView.dropResultString(for: .insert("store://p"), item: item) == "![](store://p)")
        #expect(MarkdownUITextView.dropResultString(for: .consumed, item: item) == nil)
        #expect(MarkdownUITextView.dropResultString(for: .declined, item: item) == nil)
        #expect(MarkdownUITextView.dropResultString(for: nil, item: item) == nil)
        #expect(MarkdownUITextView.dropResultString(for: .insert(""), item: item) == nil,
                "an empty reference must not insert an empty ![]()")
    }

    @Test("U+FFFC (object replacement) is stripped from plain text before insertion")
    func stripsObjectReplacement() {
        #expect(MarkdownUITextView.strippingObjectReplacements("a\u{FFFC}b\u{FFFC}") == "ab")
    }

    // MARK: - materialize (fileURL + size-guarded data)

    @Test("A small dropped file materializes with both bytes and a usable fileURL")
    func materializeSmallFile() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).png")
        try Data([0xA, 0xB, 0xC]).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let item = MarkdownUITextView.materialize(from: src, typeID: UTType.png.identifier,
                                                  isImage: true, suggestedName: "photo")
        #expect(item.data == Data([0xA, 0xB, 0xC]))
        #expect(item.fileURL != nil)
        #expect(item.isImage == true)
        #expect(item.suggestedName == "photo")
        if let url = item.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    @Test("A file over the pre-read guard materializes with a fileURL but nil data (no data loss)")
    func materializeLargeFileKeepsURL() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).bin")
        let big = Data(count: AttachmentDropLimits.maxPreReadBytes + 1024)
        try big.write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let item = MarkdownUITextView.materialize(from: src, typeID: UTType.data.identifier,
                                                  isImage: false, suggestedName: "big.bin")
        #expect(item.data == nil, "oversized files must not be pre-read into memory")
        #expect(item.fileURL != nil, "but the host must still get a URL to read off the main thread")
        if let url = item.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    @Test("A nil provider URL still yields an item (declining is the host's choice, not a crash)")
    func materializeNilURL() {
        let item = MarkdownUITextView.materialize(from: nil, typeID: UTType.png.identifier,
                                                  isImage: true, suggestedName: "x")
        #expect(item.data == nil)
        #expect(item.fileURL == nil)
    }

    // MARK: - Paste disposition (paste path is unchanged by the drop rework)

    @Test("Paste .insert embeds ![](ref) and reports handled")
    func pasteInsertEmbedsAndReportsHandled() {
        let view = makeLaidOutView("")
        view.selectedRange = NSRange(location: 0, length: 0)
        view.onPasteImage = { _ in .insert("store://p") }

        let handled = view.insertPastedImage(Data([0x1]))

        #expect(handled == true)
        #expect(view.text == "![](store://p)")
    }

    @Test("Paste .consumed reports handled but inserts nothing (no fall-through / double-insert)")
    func pasteConsumedReportsHandledInsertsNothing() {
        let view = makeLaidOutView("keep")
        view.selectedRange = NSRange(location: 4, length: 0)
        view.onPasteImage = { _ in .consumed }

        let handled = view.insertPastedImage(Data([0x1]))

        #expect(handled == true, "consumed must report handled so the caller does not text-paste")
        #expect(view.text == "keep")
    }

    @Test("Paste .declined reports NOT handled so the caller falls through to text paste")
    func pasteDeclinedReportsNotHandled() {
        let view = makeLaidOutView("keep")
        view.selectedRange = NSRange(location: 4, length: 0)
        view.onPasteImage = { _ in .declined }

        let handled = view.insertPastedImage(Data([0x1]))

        #expect(handled == false)
        #expect(view.text == "keep")
    }
}
#endif
