//
//  PendingAttachment.swift
//  MarkdownEngine
//
//  Support for the async attachment disposition (`AttachmentDisposition.pending`). A host
//  that stages dropped bytes asynchronously returns `.pending(resolver)`; the engine inserts
//  a visible loading placeholder at the exact drop caret and hands the host an
//  ``AttachmentResolver`` to call when staging finishes.
//
//  The placeholder is a real image-syntax marker `![name](x-mde-pending:<UUID>)` in the buffer.
//  Because the engine re-derives all styling from the buffer string on every restyle and has no
//  offset-across-edits tracker, a real-text marker TRACKS ITSELF across intervening edits and
//  RE-RENDERS itself each restyle — no separate anchor infrastructure. The marker is stripped at
//  the single emit chokepoint (like the wiki-link `|id`), so the host's `onTextChange` / text
//  binding never sees a half-baked placeholder. On resolve/cancel the engine locates the marker
//  by re-tokenizing (the `.imageLink` token whose URL is the pending scheme + UUID) and replaces
//  or deletes it through the undoable path.
//
//  Known limitation (undo): the placeholder insert and its resolution are two independent undoable
//  edits, so undoing a RESOLVED attachment reverts the reference back into a placeholder marker
//  whose resolver has already fired — it renders as a stuck "Uploading…" chip until the user
//  deletes it or redoes. Purely visual: the marker is stripped at the emit chokepoint, so the host
//  never sees it and there is no data loss. Coalescing the two edits across the async boundary (or
//  teaching the styler which markers are orphaned) is disproportionate to a rare, host-invisible,
//  user-recoverable glitch, so it is left as documented behavior.
//

import Foundation

/// Engine-side sink the ``AttachmentResolver`` calls back into. Implemented by the macOS
/// coordinator and the iOS text view. A named protocol (not a closure struct) so the resolver
/// holds a `weak` reference and cannot keep a torn-down editor alive.
@MainActor
protocol PendingAttachmentHost: AnyObject {
    /// Replace the pending marker for `id` with `reference` (wrapped as Markdown) at its
    /// original drop point, preserving the user's live selection. Returns whether a marker was
    /// found (false if it was already gone — undone mid-flight, timed out, or torn down).
    @discardableResult
    func resolvePendingMarker(_ id: UUID, with reference: String) -> Bool
    /// Remove the pending marker for `id` if it still exists; no-op otherwise.
    func cancelPendingMarker(_ id: UUID)
}

/// A one-shot handle the host uses to resolve an async (`.pending`) drop once its staging
/// completes. Construct a blank instance and return it as `.pending(resolver)`; the engine arms
/// it with the drop's identity. Then, from your staging `Task`, call exactly one of
/// ``insert(reference:)`` / ``cancel()``.
///
/// `@MainActor`, call-once, and idempotent: a second call, or a call after the placeholder is
/// already gone (undo / timeout / editor teardown), is a safe no-op.
@MainActor
public final class AttachmentResolver {
    private weak var host: PendingAttachmentHost?
    private var id: UUID?
    private var didResolve = false

    /// Buffers an `insert`/`cancel` that arrives before the engine arms the resolver — the
    /// unusual case of a host calling back synchronously from inside its `onDropAttachment`
    /// closure, before the engine has inserted the marker. Flushed by ``arm(host:id:)``.
    private enum EarlyCall { case insert(String); case cancel }
    private var earlyCall: EarlyCall?

    public init() {}

    /// Wire the resolver to its engine host and drop identity. Called synchronously by the engine
    /// right after the host returns `.pending`. Flushes any call that arrived before arming.
    func arm(host: PendingAttachmentHost, id: UUID) {
        self.host = host
        self.id = id
        switch earlyCall {
        case .insert(let reference):
            earlyCall = nil
            _ = host.resolvePendingMarker(id, with: reference)
        case .cancel:
            earlyCall = nil
            host.cancelPendingMarker(id)
        case nil:
            break
        }
    }

    /// Splice `reference` at the original drop point. Returns whether a marker was actually
    /// replaced — `false` means the placeholder was already gone, so the host learns its staged
    /// bytes are now unreferenced. Call-once; later calls no-op and return `false`.
    @discardableResult
    public func insert(reference: String) -> Bool {
        guard !didResolve else { return false }
        didResolve = true
        guard let host, let id else {
            earlyCall = .insert(reference)  // not armed yet; flushed by arm()
            return true
        }
        return host.resolvePendingMarker(id, with: reference)
    }

    /// Remove the placeholder without inserting anything. Call-once, no-op-safe.
    public func cancel() {
        guard !didResolve else { return }
        didResolve = true
        guard let host, let id else {
            earlyCall = .cancel
            return
        }
        host.cancelPendingMarker(id)
    }
}

/// One in-flight async drop: the host's resolver, the item to wrap on resolve, and a backstop
/// timeout that auto-cancels a placeholder the host never resolves. Shared by both platforms'
/// pending-attachment hosts.
struct PendingAttachmentEntry {
    let resolver: AttachmentResolver
    let item: DroppedItem
    var timeout: DispatchWorkItem?
}

/// The visible-but-not-emitted placeholder marker for an in-flight async drop. Single source of
/// truth for the URL scheme so the styler (renders the chip), the emit transform (strips it), and
/// the locate/resolve paths all agree.
enum PendingAttachmentMarker {
    /// URL scheme that tags an image link as a pending placeholder. Deliberately obscure so a
    /// hand-typed collision is astronomically unlikely, and further guarded by requiring a valid
    /// UUID suffix (see ``isPendingURL(_:)``).
    static let scheme = "x-mde-pending:"

    /// Default backstop timeout before an unresolved placeholder is auto-cancelled. Generous so a
    /// legitimately slow large-file upload isn't killed; the primary cleanup path is an explicit
    /// ``AttachmentResolver/cancel()`` (or editor teardown).
    static let defaultTimeout: TimeInterval = 300

    /// Build the placeholder Markdown inserted at the drop caret. The alt text is sanitized with
    /// the same rules as a link label so an odd filename can't break the link or the chip render.
    static func markdown(uuid: UUID, alt: String) -> String {
        "![\(DroppedItem.sanitizedLinkLabel(alt))](\(scheme)\(uuid.uuidString))"
    }

    /// Returns the marker's UUID iff `url` is the pending scheme followed by a valid UUID. A
    /// non-UUID suffix (e.g. a user who literally typed the scheme) is rejected, so it renders and
    /// emits as ordinary text rather than becoming a permanent invisible chip.
    static func isPendingURL(_ url: String) -> UUID? {
        guard url.hasPrefix(scheme) else { return nil }
        return UUID(uuidString: String(url.dropFirst(scheme.count)))
    }

    /// Matches `![alt](x-mde-pending:<hex-ish>)`. Alt is sanitized (no `]`/newline) and the
    /// scheme+UUID contains no `)`, so these classes can't over-match past the real marker bounds.
    /// Precompiled once — `strip` runs at the emit chokepoint on every text change while a marker is
    /// present, so per-call compilation would allocate on the hot path (the repo's other regexes are
    /// all hoisted `static let` for the same reason). Force-try: the pattern is a compile-time constant.
    private static let markerRegex: NSRegularExpression = {
        let escapedScheme = NSRegularExpression.escapedPattern(for: scheme)
        return try! NSRegularExpression(pattern: "!\\[[^\\]\\n]*\\]\\(\(escapedScheme)([0-9A-Fa-f-]+)\\)")
    }()

    /// Remove every `![alt](x-mde-pending:<valid-uuid>)` from `storage`. Used at both emit
    /// chokepoints so a placeholder never reaches the host, and handles concurrent drops (all
    /// unresolved markers) uniformly. Coincidental invalid-UUID lookalikes are left intact.
    static func strip(from storage: String) -> String {
        guard storage.contains(scheme) else { return storage }
        let ns = storage as NSString
        let matches = markerRegex.matches(in: storage, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return storage }
        let result = NSMutableString(string: storage)
        // Delete in reverse so earlier match ranges stay valid as we mutate.
        for match in matches.reversed() {
            let uuidRange = match.range(at: 1)
            guard uuidRange.location != NSNotFound,
                  UUID(uuidString: ns.substring(with: uuidRange)) != nil else { continue }
            result.deleteCharacters(in: match.range)
        }
        return result as String
    }

    /// Wrap a resolved IMAGE reference so it lands on its own line — matching a synchronous image
    /// drop (`insertDroppedMarkdown`), so a mid-paragraph resolved image embeds instead of rendering
    /// as a dimmed inline link. A newline is added before/after only when the adjacent character
    /// isn't already one. Non-images (inline `[name](ref)` links) are returned unchanged. `range` is
    /// the marker range being replaced within `text`. This padding is applied AT RESOLVE, whose emit
    /// is a genuine host-visible change — unlike the bare, emit-suppressed pending placeholder.
    static func blockPaddedReplacement(_ markdown: String, isImage: Bool, in text: NSString, at range: NSRange) -> String {
        guard isImage else { return markdown }
        var prefix = ""
        var suffix = ""
        if range.location > 0, text.character(at: range.location - 1) != 0x0A { prefix = "\n" }
        let after = NSMaxRange(range)
        if after < text.length, text.character(at: after) != 0x0A { suffix = "\n" }
        return prefix + markdown + suffix
    }

    /// Shift `selection` to stay put relative to the user's intent after replacing `editRange` with
    /// `replacementLength` characters: unchanged if the edit is after it, shifted by the length delta
    /// if the edit is before it, collapsed just past the edit if it overlapped (the caret was inside
    /// the placeholder). Shared so macOS and iOS resolve selections identically. This is the crux of
    /// the async-drop fix — resolution must NOT yank the caret to the drop point.
    static func adjustedSelection(_ selection: NSRange, editRange: NSRange, replacementLength: Int, maxLength: Int) -> NSRange {
        guard selection.location != NSNotFound else { return NSRange(location: maxLength, length: 0) }
        let delta = replacementLength - editRange.length
        var location = selection.location
        var length = selection.length
        if NSMaxRange(editRange) <= selection.location {
            location += delta                                    // edit fully before selection
        } else if editRange.location >= NSMaxRange(selection) {
            // edit fully after selection: leave it untouched
        } else {
            location = editRange.location + replacementLength     // overlap: park just past the edit
            length = 0
        }
        location = min(max(location, 0), maxLength)
        length = min(max(length, 0), maxLength - location)
        return NSRange(location: location, length: length)
    }
}
