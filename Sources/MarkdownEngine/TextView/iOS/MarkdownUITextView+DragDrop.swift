//
//  MarkdownUITextView+DragDrop.swift
//  MarkdownEngine
//
//  `UITextView`'s default drop inserts images/files as `NSTextAttachment`/attributed text,
//  which corrupts the editor's plain-Markdown source (a U+FFFC or file path round-trips to
//  storage). We take over the *content* of each dropped item — without removing the built-in
//  drop interaction, so intra-view text moves keep their native MOVE + drop-caret behavior:
//
//    - `UITextPasteDelegate.transform` substitutes content per item. It runs for pastes too,
//      so we only act while a live drop session is in flight (`isHandlingDrop`), leaving
//      ⌘V / `onPasteImage` to `paste(_:)`.
//    - `UITextDropDelegate` scopes that flag to drop sessions and records whether the drag is
//      local (an in-app move) vs. external.
//
//  Per-item routing (`dropPlan`):
//    - image / file  → `onDropAttachment` (a Markdown reference, or nothing if declined / no
//      hook — never an attachment).
//    - text, local   → default result → native MOVE (our own plain text, no attachments).
//    - text, external→ forced plain string, U+FFFC-stripped (a rich-text drag can't corrupt).
//
//  UIKit performs the actual insertion at the drop caret, so there is no async race against
//  the user's live selection (a bug the old custom-interaction approach had).
//
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

extension MarkdownUITextView: UITextDropDelegate, UITextPasteDelegate {

    /// How a single dropped item should be handled. Pure/testable — derived only from the
    /// item provider's advertised types and whether the drag is local.
    enum DropPlan: Equatable {
        /// Native default result — used for a local text move (preserves MOVE semantics).
        case moveDefault
        /// External text → force a plain string (strip attachments) rather than the default,
        /// which for a rich-text drag could insert an `NSTextAttachment`.
        case plainText
        /// A web URL (`public.url`, not a file) that doesn't load as a string — insert its
        /// absolute string as text rather than dropping it or mistaking it for a file.
        case urlText
        /// An attachment to route through `onDropAttachment`.
        case attachment(isImage: Bool, typeID: String, suggestedName: String)
        /// Nothing insertable — insert nothing.
        case skip
    }

    // MARK: - UITextDropDelegate (scopes the transform to drops; records local vs. external)

    public func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                                  proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
        guard isEditable else { return UITextDropProposal(operation: .cancel) }
        isHandlingDrop = true
        // MOVE is correct ONLY for a local drag whose items are ALL text — that's the case we
        // resolve with the native default result (which deletes the source). `localDragSession`
        // means "from this app", not "text from this view": a local IMAGE/FILE/URL drag is
        // inserted as a copy (attachment / text), so proposing `.move` there would wrongly let
        // its source view delete the original. Gate on both conditions, and keep the transform's
        // text routing consistent by treating only this case as "local".
        let isLocalTextMove = drop.dropSession.localDragSession != nil
            && drop.dropSession.items.allSatisfy { isPlainTextItem($0.itemProvider) }
        currentDropIsLocal = isLocalTextMove
        let isMove = isLocalTextMove && drop.dropSession.allowsMoveOperation
        return UITextDropProposal(operation: isMove ? .move : .copy)
    }

    /// Whether a dropped item is plain text ONLY — the sole kind we resolve with the native
    /// default/move result (which deletes the source on `.move`). This is a POSITIVE allowlist,
    /// not a blacklist: EVERY advertised type must conform to `public.plain-text`. A blacklist
    /// can't be safe — a provider advertising a custom/rich type (RTF, PDF, a proprietary type)
    /// alongside an `NSString` rep would slip through, and `setDefaultResult()` on it could
    /// insert an `NSTextAttachment` (corruption) while `.move` deletes its source. Requiring
    /// plain-text-only means the default result provably carries no attachment. Anything richer
    /// (RTF/URL/file/image/custom) is inserted as a copy, never moved.
    func isPlainTextItem(_ provider: NSItemProvider) -> Bool {
        guard provider.canLoadObject(ofClass: NSString.self) else { return false }
        let identifiers = provider.registeredTypeIdentifiers
        guard !identifiers.isEmpty else { return false }
        let types = identifiers.compactMap(UTType.init)
        // Every advertised identifier must RESOLVE to a UTType and be plain text. An
        // unrecognized/custom UTI that `compactMap` would silently drop must not be waved
        // through — otherwise a custom rich representation alongside `public.plain-text` would
        // still qualify for `.move`, defeating the plain-text-only guarantee.
        guard types.count == identifiers.count else { return false }
        return types.allSatisfy { $0.conforms(to: .plainText) }
    }

    public func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                                  dropSessionDidEnd session: UIDropSession) {
        isHandlingDrop = false
        currentDropIsLocal = false
    }

    // MARK: - UITextPasteDelegate (substitutes per-item drop content)

    public func textPasteConfigurationSupporting(
        _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
        transform item: UITextPasteItem
    ) {
        // Not a drop (an ordinary paste) → keep default handling; `paste(_:)` / `onPasteImage`
        // remain authoritative for pastes.
        guard isHandlingDrop else { item.setDefaultResult(); return }

        switch dropPlan(for: item.itemProvider, isLocal: currentDropIsLocal) {
        case .moveDefault:
            item.setDefaultResult()
        case .plainText:
            item.itemProvider.loadObject(ofClass: NSString.self) { string, _ in
                let plain = Self.strippingObjectReplacements((string as? String) ?? "")
                DispatchQueue.main.async { item.setResult(string: plain) }
            }
        case .urlText:
            item.itemProvider.loadObject(ofClass: NSURL.self) { url, _ in
                let string = (url as? URL)?.absoluteString ?? ""
                DispatchQueue.main.async {
                    item.setResult(string: Self.strippingObjectReplacements(string))
                }
            }
        case .attachment(let isImage, let typeID, let suggestedName):
            guard onDropAttachment != nil else { item.setNoResult(); return }
            resolveAttachment(item.itemProvider, typeID: typeID, isImage: isImage,
                              suggestedName: suggestedName) { markdown in
                if let markdown { item.setResult(string: markdown) } else { item.setNoResult() }
            }
        case .skip:
            item.setNoResult()
        }
    }

    // MARK: - Routing (pure, testable)

    /// Decide how a dropped item is handled from its advertised types. Image types → attachment
    /// (image); a text item → move (local) or forced-plain (external); any other file type →
    /// attachment (file); nothing usable → skip.
    func dropPlan(for provider: NSItemProvider, isLocal: Bool) -> DropPlan {
        let suggestedName = provider.suggestedName ?? "file"
        if let imageType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) {
            return .attachment(isImage: true, typeID: imageType, suggestedName: suggestedName)
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            return isLocal ? .moveDefault : .plainText
        }
        // A web URL (public.url but NOT a file URL) that doesn't load as a string → text.
        // File drops advertise public.file-url (which conforms to public.url) and fall
        // through to the file-attachment branch below.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return .urlText
        }
        if let fileType = provider.registeredTypeIdentifiers.first {
            return .attachment(isImage: false, typeID: fileType, suggestedName: suggestedName)
        }
        return .skip
    }

    /// Strip U+FFFC (object-replacement) chars — the corruption signature a rich/attributed
    /// drop would leave — from text about to be inserted as plain Markdown.
    static func strippingObjectReplacements(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// Map a host disposition + item to the string the transform should insert (`nil` = insert
    /// nothing). `.insert(ref)` → wrapped Markdown; `.consumed`/`.declined`/`nil` → nothing.
    /// An empty reference normalizes to `.consumed`, so it inserts nothing (no empty `![]()`).
    static func dropResultString(for disposition: AttachmentDisposition?, item: DroppedItem) -> String? {
        guard case .insert(let reference) = disposition?.normalized else { return nil }
        return item.markdown(forReference: reference)
    }

    // MARK: - Attachment materialization

    /// Load a dropped attachment to a stable temp file, call `onDropAttachment` on the main
    /// thread, and yield the Markdown to insert (or `nil`). Uses `loadFileRepresentation` so a
    /// large drop streams to disk instead of a giant in-memory blob, and so `DroppedItem`
    /// always carries a usable `fileURL` (the pre-read `data` is populated only under the size
    /// guard). The completion is invoked on the main thread.
    private func resolveAttachment(_ provider: NSItemProvider, typeID: String, isImage: Bool,
                                   suggestedName: String, completion: @escaping (String?) -> Void) {
        provider.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] url, _ in
            let item = Self.materialize(from: url, typeID: typeID, isImage: isImage,
                                        suggestedName: suggestedName)
            DispatchQueue.main.async {
                guard let hook = self?.onDropAttachment else { completion(nil); return }
                completion(Self.dropResultString(for: hook(item), item: item))
            }
        }
    }

    /// Copy the provider's temporary file (valid only inside the load callback) to a temp URL
    /// the host can read later, and pre-read the bytes only when they fit the size guard.
    static func materialize(from providerURL: URL?, typeID: String, isImage: Bool,
                            suggestedName: String) -> DroppedItem {
        let type = UTType(typeID)
        guard let providerURL else {
            return DroppedItem(data: nil, fileURL: nil, suggestedName: suggestedName,
                               isImage: isImage, type: type)
        }
        let ext = providerURL.pathExtension.isEmpty
            ? (type?.preferredFilenameExtension ?? "")
            : providerURL.pathExtension
        var dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-drop-\(UUID().uuidString)")
        if !ext.isEmpty { dest.appendPathExtension(ext) }

        let copied = (try? FileManager.default.copyItem(at: providerURL, to: dest)) != nil
        let fileURL = copied ? dest : nil
        var data: Data?
        if let fileURL,
           let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           size <= AttachmentDropLimits.maxPreReadBytes {
            data = try? Data(contentsOf: fileURL)
        }
        return DroppedItem(data: data, fileURL: fileURL, suggestedName: suggestedName,
                           isImage: isImage, type: type)
    }
}
#endif
