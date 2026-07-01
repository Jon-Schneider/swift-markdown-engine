//
//  IOSFocusBindingTests.swift
//  MarkdownEngineTests
//
//  Verify-tests for Requirement E — host-drivable focus on iOS. The
//  `MarkdownUITextViewWrapper(focus:)` binding lets a host focus/blur the editor
//  programmatically (e.g. a "d focuses the description" shortcut) AND is written back to when
//  the user taps the field or the keyboard dismisses. The wrapper's reconcile-against-live-
//  first-responder half needs a `UIViewRepresentable.Context` + a window and is verified in the
//  app / manually; what's deterministically testable headlessly is the REPORT-BACK wiring:
//    1. `textViewDidBeginEditing` forwards focus-gained (`true`) to `onFocusChange`,
//    2. `textViewDidEndEditing` forwards focus-lost (`false`),
//    3. an un-wired view (no `onFocusChange`) is inert — no crash, nothing reported,
//    4. a real become/resign-first-responder round trip in a key window drives the same
//       delegate path end-to-end.
//
//  UIKit-runtime behaviors, so — like the other iOS suites — this file is `#if canImport(UIKit)`
//  and only executes on the iOS simulator; on the macOS host (`swift test`) it compiles out.
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("iOS host-driven focus (focus binding report-back)")
struct IOSFocusBindingTests {

    private func makeLaidOutView(_ markdown: String = "hello", isEditable: Bool = true) -> MarkdownUITextView {
        let view = MarkdownUITextView(configuration: .default, isEditable: isEditable)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        if #available(iOS 17.0, *) { view.traitOverrides.preferredContentSizeCategory = .large }
        view.render(markdown: markdown)
        view.layoutIfNeeded()
        return view
    }

    // MARK: - Delegate report-back

    @Test("textViewDidBeginEditing reports focus gained (true)")
    func beginEditingReportsFocusGained() {
        let view = makeLaidOutView()
        var reported: [Bool] = []
        view.onFocusChange = { reported.append($0) }

        view.textViewDidBeginEditing(view)

        #expect(reported == [true])
    }

    @Test("textViewDidEndEditing reports focus lost (false)")
    func endEditingReportsFocusLost() {
        let view = makeLaidOutView()
        var reported: [Bool] = []
        view.onFocusChange = { reported.append($0) }

        view.textViewDidEndEditing(view)

        #expect(reported == [false])
    }

    @Test("A begin→end sequence reports true then false, in order")
    func beginThenEndReportsInOrder() {
        let view = makeLaidOutView()
        var reported: [Bool] = []
        view.onFocusChange = { reported.append($0) }

        view.textViewDidBeginEditing(view)
        view.textViewDidEndEditing(view)

        #expect(reported == [true, false])
    }

    @Test("A view with no focus reporter is inert — the delegate calls are safe no-ops")
    func noReporterIsInert() {
        let view = makeLaidOutView()
        // No `onFocusChange` wired (the un-bound wrapper case). These must not crash.
        view.textViewDidBeginEditing(view)
        view.textViewDidEndEditing(view)
    }

    // MARK: - End-to-end responder round trip

    @Test("A real become→resign first responder round trip drives the report-back (no edit)")
    func firstResponderRoundTripDrivesReportBack() {
        let view = makeLaidOutView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var reported: [Bool] = []
        view.onFocusChange = { reported.append($0) }

        // Runs on a BOOTED simulator (a real window server), not headless — an editable
        // UITextView in the key window is granted first responder, so this exercises the
        // genuine UIKit focus path (become → textViewDidBeginEditing → onFocusChange), with
        // no edit performed. If focus were ever declined here the test SHOULD fail loudly
        // rather than silently pass, so the assertion is unconditional.
        let became = view.becomeFirstResponder()
        #expect(became, "an editable UITextView in the key window must accept first responder")
        #expect(reported.last == true, "pure focus gain (no typing) must report true")

        view.resignFirstResponder()
        #expect(reported.last == false, "pure focus loss (no typing) must report false")
    }
}
#endif
