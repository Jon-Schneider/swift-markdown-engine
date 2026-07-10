#if os(macOS)
//
//  NativeTextView+DragDrop.swift
//  MarkdownEngine
//
//  A rich `NSTextView` registers for image/file/RTF(D) drag types by default and performs
//  its own "insert as `NSTextAttachment` / RTFD / file-path text" drop — which corrupts the
//  editor's plain-Markdown source (a U+FFFC object-replacement char or a stray path
//  round-trips to storage). We can't win this with a host-level SwiftUI `.onDrop`: AppKit
//  routes a drop to the deepest view registered for the type, and the text view is
//  frontmost. So the interception must live ON the text view.
//
//  Guard shape is a DENYLIST-OF-KNOWN-GOOD, not an allowlist of known-bad flavors: we
//  intercept EVERY external drop and never let `super` run for one (an allowlist missed
//  RTFD/attributed-text and file-promise drags, which still corrupt). The only drops left
//  to `super` are intra-view text moves (`draggingSource === self`) — those carry no
//  attachments and rely on the native move + drop-caret behavior.
//
//  Intercepted drops resolve to, in order: file/image items → `onDropAttachment`; else the
//  pasteboard's PLAIN-string flavor (U+FFFC stripped) — never the attributed/RTFD version;
//  else nothing (e.g. an unresolved file promise is swallowed — safe, never corrupting).
//

import AppKit
import UniformTypeIdentifiers

extension NativeTextView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        shouldInterceptDrop(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        shouldInterceptDrop(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        shouldInterceptDrop(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard shouldInterceptDrop(sender) else {
            return super.performDragOperation(sender)
        }
        let pasteboard = sender.draggingPasteboard
        let location = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))

        let items = Self.droppedItems(from: pasteboard)
        if !items.isEmpty {
            insertDroppedItems(items, at: location)
            return true
        }

        // Non-attachment drop (plain text, or rich text like RTFD/RTF/HTML): insert ONLY
        // the plain-string flavor with any object-replacement chars stripped — never the
        // attributed/RTFD version, which is what would carry a U+FFFC into the source.
        if let plain = pasteboard.string(forType: .string).map(Self.strippingObjectReplacements),
           !plain.isEmpty {
            setSelectedRange(NSRange(location: location, length: 0))
            insertText(plain, replacementRange: NSRange(location: location, length: 0))
        }
        // Anything else (e.g. a file promise with no readable bytes on the pasteboard yet)
        // is swallowed. Returning true tells AppKit we consumed the drop, so `super` never
        // runs its corrupting default. Never corruption, at worst a no-op.
        return true
    }

    /// Intercept every external drop onto an editable view; leave only intra-view text moves
    /// to `super`. This is the load-bearing guarantee — an external drop can NEVER reach the
    /// native rich-drop handler that would splice attachments/RTFD/paths into the source.
    private func shouldInterceptDrop(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        if let source = sender.draggingSource as? NSView, source === self { return false }
        return true
    }

    /// Insert the host's reference for each dropped item at `location`, advancing past each
    /// insertion. With no `onDropAttachment` the drop is swallowed (nothing inserted) so the
    /// source is never corrupted. Internal so tests can exercise it without a drag session.
    func insertDroppedItems(_ items: [DroppedItem], at location: Int) {
        guard let onDropAttachment else { return }
        var caret = min(max(location, 0), (string as NSString).length)
        for item in items {
            switch onDropAttachment(item).normalized {
            case .insert(let reference):
                caret = insertDroppedMarkdown(item.markdown(forReference: reference),
                                              isImage: item.isImage, at: caret)
            case .pending(let resolver):
                // Async staging: splice a visible loading placeholder at the true drop caret now,
                // and hand the resolver to the coordinator so the host can resolve it in place when
                // its `Task` finishes. Marker is image-syntax so it gets its own padded line; the
                // resolved reference wraps correctly for files too (`[name](ref)`).
                let uuid = UUID()
                let marker = PendingAttachmentMarker.markdown(uuid: uuid, alt: item.suggestedName)
                caret = insertDroppedMarkdown(marker, isImage: true, at: caret)
                (delegate as? NativeTextViewCoordinator)?
                    .registerPendingAttachment(resolver, for: item, id: uuid)
            case .consumed, .declined:
                continue
            }
        }
    }

    /// Splice `markdown` at `location` via the same `insertText` path as paste (so it is
    /// undoable, restyles, and emits `onTextChange`). Image embeds are padded to sit on
    /// their own line, mirroring `insertBlockEmbed`. Returns the caret after the insertion.
    private func insertDroppedMarkdown(_ markdown: String, isImage: Bool, at location: Int) -> Int {
        let selection = NSRange(location: location, length: 0)
        setSelectedRange(selection)
        var text = markdown
        if isImage {
            let ns = string as NSString
            var prefix = ""
            var suffix = ""
            if location > 0, ns.character(at: location - 1) != 0x0A { prefix = "\n" }
            if location < ns.length, ns.character(at: location) != 0x0A { suffix = "\n" }
            text = prefix + markdown + suffix
        }
        insertText(text, replacementRange: selection)
        return location + (text as NSString).length
    }

    /// Build `DroppedItem`s from a drag pasteboard: one per dropped file URL, else the
    /// in-memory image bytes when the source dragged an image without a file (e.g. a web
    /// page). Static so it needs no view state — and so tests can drive it with a pasteboard.
    static func droppedItems(from pasteboard: NSPasteboard) -> [DroppedItem] {
        let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLOptions) as? [URL] ?? []
        let fileItems = urls.filter(\.isFileURL).map(droppedItem(forFileURL:))
        if !fileItems.isEmpty { return fileItems }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [DroppedItem(data: png, fileURL: nil, suggestedName: "image",
                                isImage: true, type: .png)]
        }
        return []
    }

    /// Strip U+FFFC (object-replacement) chars — the corruption signature an RTFD/attributed
    /// drop would otherwise leave behind — from text about to be inserted as plain Markdown.
    static func strippingObjectReplacements(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private static func droppedItem(forFileURL url: URL) -> DroppedItem {
        let type = UTType(filenameExtension: url.pathExtension)
        let isImage = type?.conforms(to: .image) ?? false
        return DroppedItem(data: preReadData(of: url), fileURL: url,
                           suggestedName: url.lastPathComponent, isImage: isImage, type: type)
    }

    /// Read a dropped file's bytes eagerly, but only when it fits the main-thread pre-read
    /// guard; larger files come back `nil` so the host reads them off the main thread from
    /// `fileURL`. Not memory-mapped: the file isn't ours, and a later SIGBUS in the host from
    /// a truncated/ejected mapping is worse than reading ≤20 MB up front.
    private static func preReadData(of url: URL) -> Data? {
        // Fail CLOSED on an unresolvable size (`nil` — special/virtual files, some network or
        // synthesized volumes). Treating `nil` as "small enough" would fall through to an
        // unbounded whole-file `Data(contentsOf:)` on the main thread, and those bytes would
        // already be in `DroppedItem.data` before the host could intervene. A `nil` size
        // instead leaves `data == nil` + `fileURL` set, so the host does its own bounded,
        // off-main read. Mirrors the iOS `materialize` guard.
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= AttachmentDropLimits.maxPreReadBytes else { return nil }
        return try? Data(contentsOf: url)
    }
}

#endif
