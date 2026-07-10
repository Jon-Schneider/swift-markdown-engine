//
//  PendingAttachmentTests.swift
//  MarkdownEngineTests
//
//  Tests for the async attachment disposition (`AttachmentDisposition.pending`): the marker
//  value type, the `AttachmentResolver` lifecycle, selection preservation, and the macOS
//  coordinator's resolve/cancel/timeout/teardown behavior. The value/resolver/selection suites
//  are cross-platform; the coordinator suite is headless AppKit (macOS only).
//

import Foundation
import Testing
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import MarkdownEngine

// MARK: - Value types, resolver, selection (cross-platform)

@MainActor
@Suite("Pending attachment — marker, resolver, selection")
struct PendingAttachmentValueTests {

    private func imageItem(_ name: String = "photo.png") -> DroppedItem {
        DroppedItem(data: nil, fileURL: nil, suggestedName: name, isImage: true, type: nil)
    }

    // A test double for the engine host the resolver calls back into.
    @MainActor
    final class SpyHost: PendingAttachmentHost {
        var resolved: [(id: UUID, reference: String)] = []
        var cancelled: [UUID] = []
        var resolveReturn = true
        func resolvePendingMarker(_ id: UUID, with reference: String) -> Bool {
            resolved.append((id, reference)); return resolveReturn
        }
        func cancelPendingMarker(_ id: UUID) { cancelled.append(id) }
    }

    // MARK: marker

    @Test(".pending passes through normalization untouched (it is a live handle, not a value)")
    func pendingNotNormalizedAway() {
        if case .pending = AttachmentDisposition.pending(AttachmentResolver()).normalized {} else {
            Issue.record(".pending must survive normalization")
        }
    }

    @Test("marker(uuid:alt:) round-trips through isPendingURL to the same UUID")
    func markerRoundTrips() {
        let uuid = UUID()
        let markdown = PendingAttachmentMarker.markdown(uuid: uuid, alt: "photo.png")
        #expect(markdown == "![photo.png](x-mde-pending:\(uuid.uuidString))")
        #expect(PendingAttachmentMarker.isPendingURL("x-mde-pending:\(uuid.uuidString)") == uuid)
    }

    @Test("marker(uuid:alt:) sanitizes a link-breaking filename so it still tokenizes")
    func markerSanitizesAlt() {
        let uuid = UUID()
        let markdown = PendingAttachmentMarker.markdown(uuid: uuid, alt: "a]b[c`d.png")
        #expect(markdown == "![abcd.png](x-mde-pending:\(uuid.uuidString))")
    }

    @Test("isPendingURL rejects a non-UUID suffix and a non-pending scheme")
    func isPendingURLRejectsInvalid() {
        #expect(PendingAttachmentMarker.isPendingURL("x-mde-pending:not-a-uuid") == nil)
        #expect(PendingAttachmentMarker.isPendingURL("https://example.com/x.png") == nil)
    }

    @Test("strip removes valid markers (one and many) but leaves real images + invalid lookalikes")
    func stripBehavior() {
        let a = UUID(), b = UUID()
        let source = "x ![f](x-mde-pending:\(a.uuidString)) y ![g](x-mde-pending:\(b.uuidString)) z"
        #expect(PendingAttachmentMarker.strip(from: source) == "x  y  z")

        let real = "![cat](https://e.com/c.png)"
        #expect(PendingAttachmentMarker.strip(from: real) == real)

        let lookalike = "![x](x-mde-pending:not-a-uuid)"
        #expect(PendingAttachmentMarker.strip(from: lookalike) == lookalike)
    }

    // MARK: resolver

    @Test("insert forwards to the host once; a second call no-ops and returns false")
    func resolverInsertCallOnce() {
        let host = SpyHost()
        let resolver = AttachmentResolver()
        let id = UUID()
        resolver.arm(host: host, id: id)

        #expect(resolver.insert(reference: "store://1") == true)
        #expect(resolver.insert(reference: "store://2") == false)
        #expect(host.resolved.map(\.reference) == ["store://1"])
    }

    @Test("cancel after insert no-ops (call-once)")
    func resolverCancelAfterInsert() {
        let host = SpyHost()
        let resolver = AttachmentResolver()
        let id = UUID()
        resolver.arm(host: host, id: id)
        _ = resolver.insert(reference: "store://1")
        resolver.cancel()
        #expect(host.cancelled.isEmpty)
    }

    @Test("insert before arming is buffered and flushed on arm")
    func resolverBuffersBeforeArm() {
        let host = SpyHost()
        let resolver = AttachmentResolver()
        // Host calls back synchronously before the engine arms the resolver.
        #expect(resolver.insert(reference: "store://early") == true)   // optimistic while unarmed
        #expect(host.resolved.isEmpty)                                 // nothing forwarded yet

        let id = UUID()
        resolver.arm(host: host, id: id)                               // flush
        #expect(host.resolved.map(\.reference) == ["store://early"])
    }

    @Test("insert returns false when the host reports the marker is gone")
    func resolverInsertFalseWhenMarkerGone() {
        let host = SpyHost()
        host.resolveReturn = false                                     // marker already removed
        let resolver = AttachmentResolver()
        resolver.arm(host: host, id: UUID())
        #expect(resolver.insert(reference: "store://x") == false)
    }

    @Test("insert(reference: \"\") is treated as cancel, not an empty ![]()")
    func resolverEmptyInsertCancels() {
        let host = SpyHost()
        let resolver = AttachmentResolver()
        resolver.arm(host: host, id: UUID())
        #expect(resolver.insert(reference: "") == false)
        #expect(host.resolved.isEmpty, "an empty reference must not be forwarded as an insert")
        #expect(host.cancelled.count == 1, "an empty reference cancels the placeholder")
    }

    // MARK: selection preservation

    @Test("a resolve edit BEFORE the caret shifts the caret by the length delta")
    func selectionShiftsWhenEditBefore() {
        // marker [3,20) replaced by 10 chars → delta = -10; caret at 30 → 20.
        let result = PendingAttachmentMarker.adjustedSelection(NSRange(location: 30, length: 0),
                                              editRange: NSRange(location: 3, length: 20),
                                              replacementLength: 10, maxLength: 100)
        #expect(result == NSRange(location: 20, length: 0))
    }

    @Test("a resolve edit AFTER the caret leaves the caret untouched")
    func selectionUnchangedWhenEditAfter() {
        let result = PendingAttachmentMarker.adjustedSelection(NSRange(location: 2, length: 0),
                                              editRange: NSRange(location: 10, length: 20),
                                              replacementLength: 5, maxLength: 100)
        #expect(result == NSRange(location: 2, length: 0))
    }

    @Test("a resolve edit OVERLAPPING the caret parks it just past the replacement")
    func selectionCollapsesWhenEditOverlaps() {
        // caret inside the marker [5,20); replaced by 8 chars → caret at 5+8 = 13.
        let result = PendingAttachmentMarker.adjustedSelection(NSRange(location: 9, length: 0),
                                              editRange: NSRange(location: 5, length: 20),
                                              replacementLength: 8, maxLength: 200)
        #expect(result == NSRange(location: 13, length: 0))
    }
}

#if os(macOS)

// MARK: - macOS coordinator resolve/cancel/timeout/teardown + rendering

/// Image provider that always returns `nil`. On the NORMAL image path a `nil` provider yields no
/// `.latexImage` anchor (it falls back to dimmed markers), so a rendered chip proves the pending
/// branch short-circuited BEFORE the provider — the provider is never consulted for a pending URL.
private struct NilImageProvider: EmbeddedImageProvider {
    func image(for reference: EmbeddedImageRequest) -> PlatformImage? { nil }
    func fingerprint() -> AnyHashable { 1 }
}

/// A mutable reference the SwiftUI text binding writes through, so a test can observe what the
/// engine emits to the host.
private final class TextBox { var value: String; init(_ value: String) { self.value = value } }

@MainActor
@Suite("Pending attachment — macOS coordinator")
struct MacOSPendingAttachmentTests {

    private func makeCoordinator() -> NativeTextViewCoordinator {
        NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
    }

    private func makeTextView(_ content: String) -> NativeTextView {
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.isEditable = true
        view.string = content
        view.establishCaretForTesting()
        return view
    }

    private func imageItem() -> DroppedItem {
        DroppedItem(data: nil, fileURL: nil, suggestedName: "img", isImage: true, type: nil)
    }

    /// Splice a pending marker at `location` and register a resolver for it, returning the pieces.
    /// Bypasses the drag UI so the coordinator logic is tested in isolation.
    private func stageMarker(
        in view: NativeTextView, coordinator: NativeTextViewCoordinator,
        at location: Int, timeout: TimeInterval = PendingAttachmentMarker.defaultTimeout
    ) -> (resolver: AttachmentResolver, uuid: UUID) {
        coordinator.textView = view
        let uuid = UUID()
        let marker = PendingAttachmentMarker.markdown(uuid: uuid, alt: "img")
        view.setSelectedRange(NSRange(location: location, length: 0))
        view.insertText(marker, replacementRange: NSRange(location: location, length: 0))
        let resolver = AttachmentResolver()
        coordinator.registerPendingAttachment(resolver, for: imageItem(), id: uuid, timeout: timeout)
        return (resolver, uuid)
    }

    private func makeCoordinator(box: TextBox) -> NativeTextViewCoordinator {
        NativeTextViewCoordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
    }

    @Test("a .pending drop splices a loading-placeholder marker at the drop point")
    func pendingDropInsertsMarker() {
        let view = makeTextView("abc")
        view.onDropAttachment = { _ in .pending(AttachmentResolver()) }
        view.insertDroppedItems([imageItem()], at: 3)
        #expect(view.string.contains("](x-mde-pending:"), "the drop must leave a pending marker")
    }

    @Test("a mid-paragraph .pending drop inserts BARE — it strips back to exactly the pre-drop text")
    func pendingDropIsBareNoPaddingLeak() {
        let view = makeTextView("hello world")
        view.onDropAttachment = { _ in .pending(AttachmentResolver()) }
        view.insertDroppedItems([imageItem()], at: 5)   // after "hello", mid-paragraph
        #expect(view.string.contains("](x-mde-pending:"))
        // The emit chokepoint strips only the marker; any engine-added block padding would leak a
        // spurious newline to the host. Bare insertion must strip back to the exact pre-drop text.
        #expect(PendingAttachmentMarker.strip(from: view.string) == "hello world")
    }

    @Test("a real macOS .pending drop makes NO host-visible change until the reference resolves")
    func pendingDropSuppressesEmitUntilResolve() async throws {
        let box = TextBox("hello world")
        let coordinator = makeCoordinator(box: box)
        let view = makeTextView("hello world")
        coordinator.textView = view
        view.delegate = coordinator

        let resolver = AttachmentResolver()
        view.onDropAttachment = { _ in .pending(resolver) }
        view.insertDroppedItems([imageItem()], at: 5)
        try await Task.sleep(for: .milliseconds(80))     // let any async binding write run
        #expect(box.value == "hello world", "the placeholder must never reach the host binding")

        _ = resolver.insert(reference: "store://z")
        try await Task.sleep(for: .milliseconds(80))
        // Resolve emits the real reference — the image block-padded onto its own line.
        #expect(box.value == "hello\n![](store://z)\n world", "resolve emits the real reference")
        #expect(!box.value.contains("x-mde-pending"))
    }

    @Test("resolve replaces exactly the marker with the reference at its original location")
    func resolveReplacesMarker() {
        let coordinator = makeCoordinator()
        let view = makeTextView("abc")
        let (resolver, _) = stageMarker(in: view, coordinator: coordinator, at: 3)

        #expect(resolver.insert(reference: "store://final") == true)
        // The resolved IMAGE is block-padded onto its own line (matching a synchronous image drop)
        // so it embeds rather than rendering as a dimmed inline link.
        #expect(view.string == "abc\n![](store://final)")
    }

    @Test("a resolved FILE stays inline (no block padding — unlike an image)")
    func resolvedFileIsInline() {
        let coordinator = makeCoordinator()
        let view = makeTextView("abc")
        coordinator.textView = view
        let uuid = UUID()
        let marker = PendingAttachmentMarker.markdown(uuid: uuid, alt: "report.pdf")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertText(marker, replacementRange: NSRange(location: 3, length: 0))
        let resolver = AttachmentResolver()
        let file = DroppedItem(data: nil, fileURL: nil, suggestedName: "report.pdf", isImage: false, type: nil)
        coordinator.registerPendingAttachment(resolver, for: file, id: uuid)

        _ = resolver.insert(reference: "store://f")
        #expect(view.string == "abc[report.pdf](store://f)", "a file link stays inline")
    }

    @Test("resolve preserves the user's caret when it was moved before the marker")
    func resolvePreservesCaret() {
        let coordinator = makeCoordinator()
        let view = makeTextView("abc")
        let (resolver, _) = stageMarker(in: view, coordinator: coordinator, at: 3)

        view.setSelectedRange(NSRange(location: 1, length: 0))    // user clicks into "abc"
        _ = resolver.insert(reference: "store://x")
        #expect(view.selectedRange() == NSRange(location: 1, length: 0),
                "the caret must not be yanked to the resolved attachment")
    }

    @Test("resolve tracks the marker across an intervening edit before it")
    func resolveTracksAcrossEdit() {
        let coordinator = makeCoordinator()
        let view = makeTextView("abc")
        let (resolver, _) = stageMarker(in: view, coordinator: coordinator, at: 3)

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("XY", replacementRange: NSRange(location: 0, length: 0))   // shifts marker
        _ = resolver.insert(reference: "store://x")
        #expect(view.string == "XYabc\n![](store://x)")
    }

    @Test("cancel removes the marker from the buffer")
    func cancelRemovesMarker() {
        let coordinator = makeCoordinator()
        let view = makeTextView("abc")
        let (resolver, _) = stageMarker(in: view, coordinator: coordinator, at: 3)

        resolver.cancel()
        #expect(!view.string.contains("x-mde-pending"))
        #expect(view.string == "abc")
    }

    @Test("cancel after a real mid-paragraph drop restores the EXACT pre-drop text (no residue)")
    func cancelRestoresExactText() {
        let coordinator = makeCoordinator()
        let view = makeTextView("hello world")
        coordinator.textView = view
        view.delegate = coordinator
        let resolver = AttachmentResolver()
        view.onDropAttachment = { _ in .pending(resolver) }
        view.insertDroppedItems([imageItem()], at: 5)

        resolver.cancel()
        #expect(view.string == "hello world", "cancel must leave no stray newline from the placeholder")
    }

    @Test("insert returns false (no-op) once the marker was removed — undo mid-flight")
    func insertFalseAfterMarkerGone() {
        let coordinator = makeCoordinator()
        let view = makeTextView("abc")
        let (resolver, _) = stageMarker(in: view, coordinator: coordinator, at: 3)

        view.string = "abc"                                       // user undid the placeholder
        #expect(resolver.insert(reference: "store://x") == false)
        #expect(view.string == "abc")
    }

    @Test("the backstop timeout removes an unresolved marker; a later insert no-ops")
    func timeoutRemovesMarker() async throws {
        let coordinator = makeCoordinator()
        let view = makeTextView("abc")
        let (resolver, _) = stageMarker(in: view, coordinator: coordinator, at: 3, timeout: 0.05)

        try await Task.sleep(for: .milliseconds(250))
        #expect(!view.string.contains("x-mde-pending"), "the timeout must remove the stale marker")
        #expect(resolver.insert(reference: "late") == false)
    }

    @Test("a multi-item drop with a synchronous resolve lands later items at the right offset")
    func multiItemDropSynchronousResolve() {
        let coordinator = makeCoordinator()
        let view = makeTextView("")
        coordinator.textView = view
        view.delegate = coordinator

        var calls = 0
        view.onDropAttachment = { _ in
            calls += 1
            if calls == 1 {
                let r = AttachmentResolver()
                r.insert(reference: "store://1")   // resolve synchronously inside the hook (buffered)
                return .pending(r)
            }
            return .insert("store://2")
        }
        view.insertDroppedItems([imageItem(), imageItem()], at: 0)

        // Item 1's marker resolves in place to a block-padded image; item 2 must land AFTER it, not at
        // the stale (much longer) marker-end offset. Without the caret recompute this misplaces/fails.
        #expect(view.string == "![](store://1)\n![](store://2)")
    }

    @Test("resolving on a read-only view retains the entry so the backstop timeout can still clean up")
    func resolveOnReadOnlyRetainsForTimeout() async throws {
        let coordinator = makeCoordinator()
        let view = makeTextView("abc")
        let (resolver, _) = stageMarker(in: view, coordinator: coordinator, at: 3, timeout: 0.1)

        view.isEditable = false
        #expect(resolver.insert(reference: "store://x") == false, "a read-only resolve can't apply")
        #expect(view.string.contains("x-mde-pending"),
                "the entry must NOT be consumed while the marker is still stuck (no strand)")

        view.isEditable = true
        try await Task.sleep(for: .milliseconds(300))   // retained timeout fires; now editable → cleans up
        #expect(!view.string.contains("x-mde-pending"), "the retained timeout removes the chip once editable")
    }

    @Test("teardown cancels pending resolvers so a later resolve no-ops")
    func teardownCancelsPending() {
        let coordinator = makeCoordinator()
        let view = makeTextView("abc")
        let (resolver, _) = stageMarker(in: view, coordinator: coordinator, at: 3)

        coordinator.cancelAllPendingAttachments()
        #expect(resolver.insert(reference: "store://x") == false)
    }

    @Test("concurrent drops resolve independently")
    func concurrentDropsResolveIndependently() {
        let coordinator = makeCoordinator()
        let view = makeTextView("ab")
        let first = stageMarker(in: view, coordinator: coordinator, at: 2)
        // Second marker after the first; stage it at end of the current buffer.
        let second = stageMarker(in: view, coordinator: coordinator, at: (view.string as NSString).length)

        #expect(first.resolver.insert(reference: "store://1") == true)
        #expect(second.resolver.insert(reference: "store://2") == true)
        // Each resolves independently to its own reference; no pending markers remain.
        #expect(view.string.contains("![](store://1)"))
        #expect(view.string.contains("![](store://2)"))
        #expect(!view.string.contains("x-mde-pending"))
    }

    // MARK: rendering

    @Test("a pending marker renders a chip via .latexImage WITHOUT consulting the image provider")
    func pendingMarkerRendersChipWithoutProvider() {
        let uuid = UUID()
        let text = PendingAttachmentMarker.markdown(uuid: uuid, alt: "photo.png")
        let attrs = MarkdownStyler.styleAttributes(
            text: text, fontName: NSFont.systemFont(ofSize: 14).fontName, fontSize: 14,
            caretLocation: 0, activeTokenIndices: [],
            colorScheme: .light,
            configuration: MarkdownEditorConfiguration(services: MarkdownEditorServices(images: NilImageProvider()))
        )
        // A nil-returning provider gives the normal image path NO `.latexImage`; a chip here proves
        // the pending branch short-circuited before the provider was ever consulted.
        let hasChip = attrs.contains { $0.attributes[.latexImage] != nil }
        #expect(hasChip, "the pending marker must render a loading chip on a .latexImage anchor")
    }

    @Test("a MID-PARAGRAPH pending marker still renders a chip and hides its raw URL (inline)")
    func pendingChipRendersInlineMidParagraph() {
        // The regression from bare insertion: a non-standalone marker fell to the standalone renderer,
        // which declined it and left the raw `x-mde-pending:UUID` URL visible. Inline rendering fixes it.
        let uuid = UUID()
        let marker = PendingAttachmentMarker.markdown(uuid: uuid, alt: "photo.png")
        let text = "hello \(marker) world"
        let attrs = MarkdownStyler.styleAttributes(
            text: text, fontName: NSFont.systemFont(ofSize: 14).fontName, fontSize: 14,
            caretLocation: 0, activeTokenIndices: [],
            colorScheme: .light,
            configuration: MarkdownEditorConfiguration(services: MarkdownEditorServices(images: NilImageProvider()))
        )
        #expect(attrs.contains { $0.attributes[.latexImage] != nil },
                "a mid-paragraph pending marker must still render a chip")
        // The URL substring must be collapsed to clear (not shown as raw text).
        let urlRange = (text as NSString).range(of: "x-mde-pending:\(uuid.uuidString)")
        let urlVisible = attrs.contains { styled in
            NSIntersectionRange(styled.range, urlRange).length > 0
                && (styled.attributes[.foregroundColor] as? PlatformColor) != PlatformColor.clear
                && styled.attributes[.latexImage] == nil
        }
        #expect(!urlVisible, "the raw pending URL must be hidden, not rendered as visible text")
    }

    @Test("the chip resolves its dynamic color per scheme — light and dark rasters differ")
    func chipResolvesColorPerScheme() {
        // Fixed fill isolates the muted text/border color: a difference proves `mutedText` (a dynamic
        // catalog color) is resolved for the target scheme, not frozen at the ambient appearance.
        let font = NSFont.systemFont(ofSize: 14)
        let light = PendingAttachmentChip.render(
            alt: "x", baseFont: font, mutedText: .secondaryLabelColor,
            fillColor: .white, colorScheme: .light, maxWidth: 200
        )
        let dark = PendingAttachmentChip.render(
            alt: "x", baseFont: font, mutedText: .secondaryLabelColor,
            fillColor: .white, colorScheme: .dark, maxWidth: 200
        )
        #expect(light.tiffRepresentation != dark.tiffRepresentation,
                "the muted color must resolve differently in light vs dark")
    }

    @Test("chips for different base fonts don't collide in the cache (height tracks the base font)")
    func chipCacheKeyIncludesBaseFont() {
        // base 10 and 11 both floor labelFont to 9pt; without baseFontSize in the key they'd share a
        // cache entry and the second would get the first's wrong-height raster.
        let a = PendingAttachmentChip.render(
            alt: "x", baseFont: .systemFont(ofSize: 10), mutedText: .secondaryLabelColor,
            fillColor: .white, colorScheme: .light, maxWidth: 200
        )
        let b = PendingAttachmentChip.render(
            alt: "x", baseFont: .systemFont(ofSize: 11), mutedText: .secondaryLabelColor,
            fillColor: .white, colorScheme: .light, maxWidth: 200
        )
        #expect(a.size.height != b.size.height, "chip height must track the base font, not collide")
    }
}

#endif

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit

@MainActor
@Suite("Pending attachment — iOS view")
struct IOSPendingAttachmentTests {

    private func makeLaidOutView(_ markdown: String) -> MarkdownUITextView {
        let view = MarkdownUITextView(configuration: .default, isEditable: true)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        if #available(iOS 17.0, *) { view.traitOverrides.preferredContentSizeCategory = .large }
        view.render(markdown: markdown)
        view.layoutIfNeeded()
        view.establishCaretForTesting()
        return view
    }

    private func imageItem() -> DroppedItem {
        DroppedItem(data: nil, fileURL: nil, suggestedName: "img", isImage: true, type: nil)
    }

    /// Splice a pending marker at `location` and register a resolver for it (bypassing the drop UI,
    /// which needs a `UITextPasteItem` with no public init).
    private func stageMarker(in view: MarkdownUITextView, at location: Int) -> (resolver: AttachmentResolver, uuid: UUID) {
        let uuid = UUID()
        let marker = PendingAttachmentMarker.markdown(uuid: uuid, alt: "img")
        view.applyUndoableEdit(
            replacing: NSRange(location: location, length: 0), with: marker,
            finalSelection: NSRange(location: location + (marker as NSString).length, length: 0)
        )
        let resolver = AttachmentResolver()
        view.registerPendingAttachment(resolver, for: imageItem(), id: uuid)
        return (resolver, uuid)
    }

    /// Let iOS's deferred `arm` (one main-queue hop, so it lands after UIKit inserts the marker in
    /// production) run. Tests insert the marker synchronously, so a resolve is buffered until here.
    private func settle() async { try? await Task.sleep(for: .milliseconds(30)) }

    @Test("resolve replaces the marker with the reference at its original location")
    func resolveReplacesMarker() async {
        let view = makeLaidOutView("abc")
        let (resolver, _) = stageMarker(in: view, at: 3)
        #expect(resolver.insert(reference: "store://final") == true)
        await settle()
        #expect(view.text == "abc\n![](store://final)")   // resolved image block-padded onto its own line
    }

    @Test("resolve preserves the user's caret when it was moved before the marker")
    func resolvePreservesCaret() async {
        let view = makeLaidOutView("abc")
        let (resolver, _) = stageMarker(in: view, at: 3)
        view.selectedRange = NSRange(location: 1, length: 0)
        _ = resolver.insert(reference: "store://x")
        await settle()
        #expect(view.text == "abc\n![](store://x)", "the resolve must actually land")
        #expect(view.selectedRange == NSRange(location: 1, length: 0),
                "the caret must not be yanked to the resolved attachment")
    }

    @Test("cancel removes the marker")
    func cancelRemovesMarker() async {
        let view = makeLaidOutView("abc")
        let (resolver, _) = stageMarker(in: view, at: 3)
        resolver.cancel()
        await settle()
        #expect(!view.text.contains("x-mde-pending"))
        #expect(view.text == "abc")
    }

    @Test("the placeholder is never emitted to the host; the resolved reference is")
    func emitSuppressesPlaceholder() async {
        let view = makeLaidOutView("abc")
        var emitted: [String] = []
        view.onTextChange = { emitted.append($0) }

        let (resolver, _) = stageMarker(in: view, at: 3)
        await settle()
        #expect(emitted.allSatisfy { !$0.contains("x-mde-pending") },
                "the placeholder must never reach onTextChange")

        _ = resolver.insert(reference: "store://z")
        await settle()
        #expect(emitted.last == "abc\n![](store://z)")
        #expect(emitted.allSatisfy { !$0.contains("x-mde-pending") })
    }

    @Test("dropResultString maps .pending to nil (the pending path is handled in resolveAttachment)")
    func dropResultStringIgnoresPending() {
        #expect(MarkdownUITextView.dropResultString(for: .pending(AttachmentResolver()), item: imageItem()) == nil)
    }

    @Test("the chip resolves its dynamic color per scheme (iOS resolvedColor path)")
    func chipResolvesColorPerScheme() {
        // Fixed fill isolates the muted text/border: a difference proves `mutedText` resolves for the
        // target scheme via `resolvedColor(with:)` rather than freezing at the ambient appearance.
        let font = UIFont.systemFont(ofSize: 14)
        let light = PendingAttachmentChip.render(
            alt: "x", baseFont: font, mutedText: .secondaryLabel,
            fillColor: .white, colorScheme: .light, maxWidth: 200
        )
        let dark = PendingAttachmentChip.render(
            alt: "x", baseFont: font, mutedText: .secondaryLabel,
            fillColor: .white, colorScheme: .dark, maxWidth: 200
        )
        #expect(light.pngData() != dark.pngData(),
                "the muted color must resolve differently in light vs dark")
    }
}
#endif
