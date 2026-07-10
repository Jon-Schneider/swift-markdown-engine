//
//  AttachmentDrop.swift
//  MarkdownEngine
//
//  Cross-platform types for the attachment paste/drop hooks. The editor's text is a
//  plain-Markdown `String`, so a native rich drop (image/file → `NSTextAttachment` /
//  file-path text) would corrupt the source. Both platforms intercept those drops and
//  route them to a host closure that returns one of these dispositions; the engine
//  inserts a Markdown reference through the same undoable path as `onPasteImage`.
//

import Foundation
import UniformTypeIdentifiers

/// What the engine should do with a pasted or dropped attachment, returned by the host
/// from `onPasteImage` / `onDropAttachment`.
///
/// This replaces the older `String?` return, whose `nil` conflated two genuinely
/// different intents — "I handled it, insert nothing" vs. "I decline, do your default" —
/// the exact ambiguity behind the drop-corruption and paste double-insert bugs. Making
/// the three outcomes explicit lets a host stage bytes asynchronously (`.consumed`)
/// without the engine falling through to a second insertion.
public enum AttachmentDisposition {
    /// The host produced a storage reference; the engine inserts it, wrapping as
    /// `![](ref)` for an image or `[name](ref)` for another file, through the undoable
    /// edit path. An empty reference collapses to ``consumed`` (see ``normalized``).
    case insert(String)
    /// The host has taken ownership (e.g. it is staging the bytes asynchronously and
    /// will insert a reference itself later). The engine inserts nothing AND does not
    /// fall back to its default handling — the intent a synchronous `nil` could not
    /// express, and the fix for the "browser Copy Image double-inserts" paste gap.
    case consumed
    /// The host declines this item. The engine runs its default behavior: for paste,
    /// the normal text/URL paste; for drop, nothing (the native rich drop stays
    /// neutralized, so the source string can never be corrupted).
    case declined
    /// The host will stage the bytes asynchronously and resolve LATER, but wants the
    /// engine to remember the exact drop point in the meantime. The engine inserts a
    /// visible loading placeholder at the drop caret (never emitted to the host) and,
    /// when the host's staging `Task` finishes, calls ``AttachmentResolver/insert(reference:)``
    /// (splice the reference at the original drop point) or ``AttachmentResolver/cancel()``
    /// (remove the placeholder). Unlike ``consumed`` + the `pendingInlineInsertion` binding,
    /// the reference lands where the file was dropped regardless of intervening edits or
    /// selection changes — the fix for async-staged drops replacing the live selection.
    ///
    /// The host constructs a blank ``AttachmentResolver()`` and returns it here; the engine
    /// arms it. Drop-only — on paste (which has no caret geometry to remember) `.pending`
    /// is treated as ``consumed``.
    case pending(AttachmentResolver)

    /// Collapses `.insert("")` to ``consumed`` so an accidental empty reference can't
    /// splice an empty `![]()` into the document. `.pending` is intentionally left
    /// untouched — it is a live handle, not a value to fold away.
    var normalized: AttachmentDisposition {
        if case .insert(let ref) = self, ref.isEmpty { return .consumed }
        return self
    }
}

/// A single item dropped onto the editor, handed to `onDropAttachment`. The host
/// persists/stages it and returns an ``AttachmentDisposition``. The engine never learns
/// the host's storage scheme — it only wraps the returned reference as Markdown.
public struct DroppedItem {
    /// The item's bytes, pre-read for convenience (mirrors `onPasteImage(Data)`). `nil`
    /// when the source offered only a file URL, or when the file exceeded the engine's
    /// main-thread pre-read guard — in that case read it yourself from ``fileURL``,
    /// applying your own size cap / streaming.
    public let data: Data?
    /// A file URL for the dropped item when the source provided one (Finder / Files
    /// drops). Use it for the large-file or security-scoped case where you'd rather read
    /// the bytes yourself than take the pre-read ``data``. `nil` for in-memory drops
    /// (e.g. an image dragged out of a web page).
    public let fileURL: URL?
    /// A filename suitable for a `[name](ref)` link when the item is not an image.
    public let suggestedName: String
    /// Whether the item's ``type`` conforms to `public.image`. The engine wraps an
    /// inserted reference as `![](ref)` when `true`, `[suggestedName](ref)` otherwise.
    public let isImage: Bool
    /// The item's uniform type, when the source identified one.
    public let type: UTType?

    public init(data: Data?, fileURL: URL?, suggestedName: String, isImage: Bool, type: UTType?) {
        self.data = data
        self.fileURL = fileURL
        self.suggestedName = suggestedName
        self.isImage = isImage
        self.type = type
    }

    /// Wrap a host-returned storage `reference` as the Markdown the engine inserts:
    /// an image embed for an image, else a link using ``suggestedName`` (falling back to
    /// the reference itself when the name is empty). The label is sanitized so a filename
    /// containing Markdown-significant characters (e.g. `budget]2026.pdf`) can't truncate the
    /// link or prevent it from parsing.
    func markdown(forReference reference: String) -> String {
        if isImage { return "![](\(reference))" }
        let name = Self.sanitizedLinkLabel(suggestedName.isEmpty ? reference : suggestedName)
        return "[\(name)](\(reference))"
    }

    /// Normalize a filename into a safe Markdown link label. Two hazards, both of which stop the
    /// label from parsing as a link:
    ///   - `]` closes the label, and `` ` `` / `\` / `$` / `[` start an inline span (code /
    ///     escape / LaTeX / wiki / image) that the parser "claims" — and it rejects any link
    ///     candidate overlapping a claimed span, so *escaping* wouldn't help. These are stripped.
    ///   - a newline inside the label is rejected outright by the inline scanner. These are
    ///     collapsed to a space.
    /// The label is display text, so the small loss is acceptable. (Emphasis chars like `*` `_`
    /// `~` are safe inside a label — they become link-text children — so they are left intact.)
    static func sanitizedLinkLabel(_ label: String) -> String {
        let breaking: Set<Character> = ["[", "]", "`", "\\", "$"]
        var result = ""
        for character in label {
            if character.isNewline {
                result.append(" ")
            } else if !breaking.contains(character) {
                result.append(character)
            }
        }
        return result
    }
}

enum AttachmentDropLimits {
    /// Max bytes the engine pre-reads from a dropped file into ``DroppedItem/data`` on
    /// the main thread. Larger files arrive with `data == nil` and only a `fileURL`, so a
    /// multi-GB drop can't stall the UI. Hosts that need the bytes read them from the URL
    /// off the main thread.
    static let maxPreReadBytes = 20 * 1024 * 1024
}
