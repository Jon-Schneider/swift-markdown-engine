#if os(macOS)
import AppKit
import Testing
@testable import MarkdownEngine

@Suite("macOS emoji picker trigger")
struct MacOSEmojiPickerTriggerTests {

    @Test("A colon triggers the picker when it follows a space")
    func triggerAfterSpace() {
        #expect(NativeTextView.isEmojiPickerTriggerPosition(
            in: "Say ", selectionRange: NSRange(location: 4, length: 0)
        ))
    }

    @Test("A colon triggers the picker at the start of a document or line")
    func triggerAtStartOfLine() {
        #expect(NativeTextView.isEmojiPickerTriggerPosition(
            in: "", selectionRange: NSRange(location: 0, length: 0)
        ))
        #expect(NativeTextView.isEmojiPickerTriggerPosition(
            in: "First line\n", selectionRange: NSRange(location: 11, length: 0)
        ))
    }

    @Test("A colon does not trigger the picker without a preceding space")
    func noTriggerWithoutPrecedingSpace() {
        #expect(!NativeTextView.isEmojiPickerTriggerPosition(
            in: "emoji", selectionRange: NSRange(location: 5, length: 0)
        ))
    }

    @Test("The insertion point uses UTF-16 offsets")
    func triggerAfterSpaceFollowingEmoji() {
        #expect(NativeTextView.isEmojiPickerTriggerPosition(
            in: "😀 ", selectionRange: NSRange(location: 3, length: 0)
        ))
    }

    @Test("The committed trigger colon is available for emoji replacement")
    func committedColonReplacementRange() {
        #expect(NativeTextView.emojiPickerReplacementRange(in: "Hello :", at: 6) ==
            NSRange(location: 6, length: 1))
        #expect(NativeTextView.emojiPickerReplacementRange(in: "Hello !", at: 6) == nil)
    }

    @MainActor
    @Test("Character Viewer insertion replaces its pending colon without selecting it")
    func characterViewerInsertionReplacesPendingColon() {
        let view = NativeTextView(frame: .zero)
        view.string = "Hello :"
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.pendingEmojiPickerTriggerRange = NSRange(location: 6, length: 1)

        view.insertText("😀", replacementRange: view.selectedRange())

        #expect(view.string == "Hello 😀")
        #expect(view.selectedRange() == NSRange(location: 8, length: 0))
    }
}
#endif
