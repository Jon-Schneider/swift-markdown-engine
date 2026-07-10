//
//  MacOSDragDropTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for the macOS drag-drop interception — `NativeTextView.insertDroppedItems(_:at:)`,
//  the backing for `NativeTextViewWrapper(onDropAttachment:)`. A rich `NSTextView` would splice a
//  dropped image/file in as an `NSTextAttachment` / file path, corrupting the Markdown source; the
//  interception instead routes each item to the host hook. Insertion must:
//    1. wrap an image reference as a block `![](ref)` on its own line at the drop point,
//    2. wrap a file reference as an inline `[name](ref)`,
//    3. insert NOTHING for `.consumed` / `.declined`, and never corrupt the source,
//    4. insert NOTHING (neutralized native drop) when no host hook is set.
//
//  Headless AppKit — macOS only.
//

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("macOS drag-drop interception (insertDroppedItems)")
struct MacOSDragDropTests {

    private func makeTextView(_ content: String) -> NativeTextView {
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.isEditable = true
        view.string = content
        view.establishCaretForTesting()
        return view
    }

    private func imageItem() -> DroppedItem {
        DroppedItem(data: Data([0x1]), fileURL: nil, suggestedName: "image", isImage: true, type: .png)
    }

    private func fileItem() -> DroppedItem {
        DroppedItem(data: nil, fileURL: URL(fileURLWithPath: "/tmp/report.pdf"),
                    suggestedName: "report.pdf", isImage: false, type: .pdf)
    }

    @Test("An image drop inserts a block ![](ref) on its own line at the drop point")
    func imageDropInsertsBlockEmbed() {
        let view = makeTextView("abc")
        view.onDropAttachment = { _ in .insert("store://img") }

        view.insertDroppedItems([imageItem()], at: 3)   // end of "abc"

        // Drop lands after "abc" (no trailing newline in source) → a leading newline is added.
        #expect(view.string == "abc\n![](store://img)")
    }

    @Test("An image dropped between two lines is padded to sit alone")
    func imageDropPadsBothSides() {
        let view = makeTextView("abc")
        view.onDropAttachment = { _ in .insert("store://img") }

        view.insertDroppedItems([imageItem()], at: 1)   // between "a" and "bc"

        #expect(view.string == "a\n![](store://img)\nbc")
    }

    @Test("A file drop inserts an inline [name](ref) at the drop point")
    func fileDropInsertsNamedLink() {
        let view = makeTextView("see  here")
        view.onDropAttachment = { _ in .insert("store://pdf") }

        view.insertDroppedItems([fileItem()], at: 4)   // between the two spaces

        #expect(view.string == "see [report.pdf](store://pdf) here")
    }

    @Test(".consumed inserts nothing (host is staging asynchronously)")
    func consumedInsertsNothing() {
        let view = makeTextView("abc")
        view.onDropAttachment = { _ in .consumed }

        view.insertDroppedItems([imageItem()], at: 3)

        #expect(view.string == "abc", "a consumed drop must leave the source untouched")
    }

    @Test(".declined inserts nothing")
    func declinedInsertsNothing() {
        let view = makeTextView("abc")
        view.onDropAttachment = { _ in .declined }

        view.insertDroppedItems([fileItem()], at: 3)

        #expect(view.string == "abc")
    }

    @Test("An empty reference is treated as consumed — no empty ![]() is spliced")
    func emptyReferenceInsertsNothing() {
        let view = makeTextView("abc")
        view.onDropAttachment = { _ in .insert("") }

        view.insertDroppedItems([imageItem()], at: 3)

        #expect(view.string == "abc")
    }

    @Test("With no host hook, the drop is neutralized — nothing is inserted, source uncorrupted")
    func noHookNeutralizesDrop() {
        let view = makeTextView("abc")
        // onDropAttachment left nil.
        view.insertDroppedItems([imageItem()], at: 3)

        #expect(view.string == "abc", "without a hook the native drop is swallowed, not inserted")
    }

    @Test("The host receives the dropped item's metadata")
    func hookReceivesItemMetadata() {
        let view = makeTextView("")
        var received: DroppedItem?
        view.onDropAttachment = { item in received = item; return .consumed }

        view.insertDroppedItems([fileItem()], at: 0)

        #expect(received?.suggestedName == "report.pdf")
        #expect(received?.isImage == false)
        #expect(received?.fileURL?.lastPathComponent == "report.pdf")
    }

    // MARK: - Pasteboard reading (the interception's flavor decisions)

    @Test("A file-URL pasteboard yields a DroppedItem with URL + image classification")
    func droppedItemsReadsFileURL() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("pic-\(UUID().uuidString).png")
        try Data([0x1, 0x2]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("md-drop-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])

        let items = NativeTextView.droppedItems(from: pasteboard)
        #expect(items.count == 1)
        #expect(items.first?.isImage == true)
        #expect(items.first?.fileURL?.lastPathComponent == url.lastPathComponent)
        #expect(items.first?.data == Data([0x1, 0x2]))
    }

    @Test("A rich-text (RTFD-with-attachment) drag yields NO attachment items, and its plain flavor has no U+FFFC")
    func rtfdDragCarriesNoCorruption() throws {
        // Build an attributed string with an embedded image attachment (U+FFFC in its string)
        // and put its RTFD + plain-text flavors on a pasteboard — exactly a rich-text drag from
        // Notes/TextEdit. This is the bypass the allowlist version missed.
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 4, height: 4))
        let attributed = NSMutableAttributedString(string: "before ")
        attributed.append(NSAttributedString(attachment: attachment))
        attributed.append(NSAttributedString(string: " after"))
        #expect(attributed.string.contains("\u{FFFC}"), "the attributed string must contain the object-replacement char")

        let rtfd = try #require(attributed.rtfd(from: NSRange(location: 0, length: attributed.length),
                                                documentAttributes: [:]))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("md-rtfd-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(rtfd, forType: .rtfd)
        pasteboard.setString(attributed.string, forType: .string)

        // The interception treats this as a non-attachment drop (no file/image item)...
        #expect(NativeTextView.droppedItems(from: pasteboard).isEmpty)
        // ...and the plain-string flavor it would insert has the U+FFFC stripped.
        let plain = try #require(pasteboard.string(forType: .string))
        #expect(NativeTextView.strippingObjectReplacements(plain) == "before  after")
        #expect(!NativeTextView.strippingObjectReplacements(plain).contains("\u{FFFC}"))
    }

    // MARK: - Paste disposition (macOS paste path)

    private func imagePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("md-paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        // A real 4×4 bitmap (an empty NSImage has no pixels → no encodable PNG).
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0),
           let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        return pasteboard
    }

    @Test("Paste .insert wraps the bare reference as ![](ref) — NOT verbatim")
    func pasteInsertWrapsReference() {
        let view = makeTextView("")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.onPasteImage = { _ in .insert("store://p") }

        let handled = view.handleImagePaste(from: imagePasteboard())

        #expect(handled == true)
        #expect(view.string == "![](store://p)", "the engine wraps the reference; it must not insert it verbatim")
    }

    @Test("Paste .consumed reports handled and inserts nothing (no fall-through)")
    func pasteConsumedHandledNoInsert() {
        let view = makeTextView("keep")
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.onPasteImage = { _ in .consumed }

        let handled = view.handleImagePaste(from: imagePasteboard())

        #expect(handled == true)
        #expect(view.string == "keep")
    }

    @Test("Paste .declined reports NOT handled so the caller falls through to text paste")
    func pasteDeclinedNotHandled() {
        let view = makeTextView("keep")
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.onPasteImage = { _ in .declined }

        let handled = view.handleImagePaste(from: imagePasteboard())

        #expect(handled == false)
        #expect(view.string == "keep")
    }

    @Test("No image on the pasteboard → handleImagePaste declines so text paste runs")
    func pasteNoImageDeclines() {
        let view = makeTextView("keep")
        var hookCalled = false
        view.onPasteImage = { _ in hookCalled = true; return .insert("x") }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("md-text-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)

        let handled = view.handleImagePaste(from: pasteboard)

        #expect(handled == false)
        #expect(hookCalled == false, "the image hook must not fire for a text-only pasteboard")
    }
}

#endif
