//
//  MacOSFocusBindingTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for Requirement E — host-drivable focus on macOS. The
//  `NativeTextViewWrapper(focus:)` binding lets a host focus/blur the editor programmatically
//  AND is written back to when the field gains/loses first responder. The critical property
//  (and the one an earlier draft got wrong): the write-back must key off the REAL first-
//  responder transition, not the NSText edit-session notifications — otherwise a click-to-focus
//  with no typing never reports, and a focus stolen back by the reconcile leaves the binding
//  stuck `true`, which then yanks first responder back on the next update.
//
//  So these tests drive a genuine `NSWindow.makeFirstResponder` round trip WITHOUT performing
//  any edit, and assert the reporter fires on the pure focus change. The `becomeFirstResponder`
//  / `resignFirstResponder` overrides in `NativeTextView` back this. Off-screen AppKit windows
//  accept first responder headlessly, so this runs on the plain `swift test` host.
//
//  Headless AppKit — macOS only.
//
#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct MacOSFocusBindingTests {

    private func makeCoordinator() -> NativeTextViewCoordinator {
        NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
    }

    /// A `NativeTextView` hosted in an off-screen window, delegated to `coordinator` so its
    /// first-responder overrides can reach `onFocusChange`. Returns the window too so the caller
    /// can drive `makeFirstResponder` on it (and keep it alive for the test's duration).
    private func makeHostedTextView(
        delegatingTo coordinator: NativeTextViewCoordinator,
        editable: Bool = true
    ) -> (view: NativeTextView, window: NSWindow) {
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.isEditable = editable
        view.delegate = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(view)
        return (view, window)
    }

    // MARK: - Real first-responder round trip (no edit)

    @Test("Gaining first responder reports focus TRUE with no edit performed")
    func focusGainReportsWithoutEdit() {
        let coordinator = makeCoordinator()
        let (view, window) = makeHostedTextView(delegatingTo: coordinator)
        var reported: [Bool] = []
        coordinator.onFocusChange = { reported.append($0) }

        let became = window.makeFirstResponder(view)

        #expect(became, "an editable NSTextView in a window must accept first responder")
        #expect(reported.last == true, "pure focus gain (no typing) must report true")
    }

    @Test("Losing first responder reports focus FALSE with no edit performed")
    func focusLossReportsWithoutEdit() {
        let coordinator = makeCoordinator()
        let (view, window) = makeHostedTextView(delegatingTo: coordinator)
        _ = window.makeFirstResponder(view)
        var reported: [Bool] = []
        coordinator.onFocusChange = { reported.append($0) }

        let resigned = window.makeFirstResponder(nil)

        #expect(resigned)
        #expect(reported.last == false, "pure focus loss (no typing) must report false")
    }

    @Test("A full focus→blur round trip reports true then false, in order")
    func focusRoundTripReportsInOrder() {
        let coordinator = makeCoordinator()
        let (view, window) = makeHostedTextView(delegatingTo: coordinator)
        var reported: [Bool] = []
        coordinator.onFocusChange = { reported.append($0) }

        _ = window.makeFirstResponder(view)
        _ = window.makeFirstResponder(nil)

        // The pure-focus events, in order — ignoring any AppKit intermediate churn, the first
        // reported value is a gain and the last is a loss.
        #expect(reported.first == true)
        #expect(reported.last == false)
    }

    // MARK: - Inert without a reporter

    @Test("A coordinator with no focus reporter is inert — focus changes are safe no-ops")
    func noReporterIsInert() {
        let coordinator = makeCoordinator()
        let (view, window) = makeHostedTextView(delegatingTo: coordinator)
        // No `onFocusChange` wired (the un-bound wrapper case). Must not crash.
        _ = window.makeFirstResponder(view)
        _ = window.makeFirstResponder(nil)
    }
}
#endif
