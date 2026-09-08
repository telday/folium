import AppKit
import SwiftUI
import WebKit

/// Files every document window into Folium's single native tab group, so
/// opening several Markdown files at once reads the way Safari/Finder/Xcode
/// read (ADR 0004, issue #5).
///
/// This is host glue by necessity: SwiftUI's `DocumentGroup` never hands the
/// app the `NSWindow` it created, so the only way to reach it is from inside
/// the document's own view tree — a zero-size `NSView` that notices which
/// window it was added to. All the *decisions* live in `DocumentTabbing`, in
/// the unit-tested logic layer; what's left here is reading AppKit state and
/// calling `addTabbedWindow(_:ordered:)`, which is the real system tab
/// mechanism (CONTEXT.md priority 1: never reimplement what AppKit provides —
/// dragging to reorder, dragging a tab out, ⌘W, and Mission Control all come
/// with it).
struct DocumentWindowTabber: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TabbingHostView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Adopts `window` into the tab group, given the app's windows front to
    /// back. Takes both as parameters rather than reading `NSApp` so the
    /// integration tests can drive it with windows they control.
    @MainActor
    static func adopt(
        _ window: NSWindow,
        orderedWindows: [NSWindow],
        userPreference: NSWindow.UserTabbingPreference = NSWindow.userTabbingPreference
    ) {
        let prefersTabbing = DocumentTabbing.prefersTabbing(userPreference: .init(userPreference))

        // Identify the window as ours before looking for a target, so the
        // *next* window to open can find this one.
        window.tabbingIdentifier = DocumentTabbing.tabbingIdentifier
        window.tabbingMode = prefersTabbing ? .preferred : .automatic

        let candidates = orderedWindows.filter { $0 !== window }.map { other in
            DocumentTabbing.Candidate(
                window: other,
                isDocumentWindow: other.tabbingIdentifier == DocumentTabbing.tabbingIdentifier,
                isVisible: other.isVisible
            )
        }
        let target = DocumentTabbing.mergeTarget(
            prefersTabbing: prefersTabbing,
            // A group of one is just this window; only a group with something
            // else in it means AppKit (or the user) already tabbed it.
            newWindowIsAlreadyTabbed: (window.tabGroup?.windows.count ?? 1) > 1,
            orderedOtherWindows: candidates
        )
        target?.addTabbedWindow(window, ordered: .above)
    }

    /// Switches tabs once, under FOLIUM_BENCH only, and marks both ends so
    /// `scripts/bench.sh` can time it and check that nothing re-rendered.
    ///
    /// Here rather than in the script because a tab switch is not something
    /// an outside process can ask for: `open` reaches Launch Services, but
    /// selecting a tab is an AppKit call on a window this app owns, and
    /// synthesising the keystroke instead would need accessibility
    /// permission the harness cannot assume.
    ///
    /// The end of the switch is a *frame*, confirmed through
    /// `MarkdownPage.paintConfirmationScript` in the tab being switched to.
    /// A tab switch deliberately does not re-render — that is half of what
    /// `CONTEXT.md` budgets — so there is no injection to hang the timing
    /// on, and the newly revealed web view drawing a frame is the only
    /// honest signal that the switch is visible to the user.
    @MainActor
    static func runTabSwitchProbeIfBenching(_ window: NSWindow) {
        let marker = BenchMarker()
        // Two *documents*, not two windows. SwiftUI settles a single open
        // document through more than one window, so a window count reaches 2
        // during the cold launch, before the second document is ever opened.
        guard marker.isEnabled,
              BenchProbe.current() == .tabSwitch,
              NSDocumentController.shared.documents.count >= 2,
              let group = window.tabGroup,
              group.windows.count >= 2,
              let target = group.windows.first(where: { $0 !== group.selectedWindow }),
              tabSwitchProbeClaim.claim()
        else { return }

        Task { @MainActor in
            // The window that just joined the group is still settling —
            // measuring a switch into a tab mid-layout would time the
            // layout, not the switch.
            try? await Task.sleep(for: .milliseconds(750))
            marker.mark("tab-switch-start")
            group.selectedWindow = target
            // No end marker without a confirmed frame. Marking one anyway
            // when the revealed tab has no web view to ask would report the
            // cost of setting `selectedWindow` and nothing else — 2 ms for a
            // switch that really takes tens of them. `scripts/bench.sh`
            // prints "not measured" when this marker never arrives, which is
            // the honest answer.
            guard let webView = firstWebView(in: target) else { return }
            _ = try? await webView.callAsyncJavaScript(
                MarkdownPage.paintConfirmationScript,
                contentWorld: .page
            )
            marker.mark("tab-switch-end")
        }
    }

    /// One probe per process: `adopt` runs for every window that joins the
    /// group, and only the first switch is a cold one.
    private static let tabSwitchProbeClaim = OneShot()

    /// SwiftUI owns the view tree, so the web view inside a document window
    /// can only be found by looking for it.
    @MainActor
    private static func firstWebView(in window: NSWindow) -> WKWebView? {
        func search(_ view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(search)
    }

    /// A zero-size view whose only job is to report the window it landed in.
    ///
    /// The work happens in `viewDidMoveToWindow` rather than on a later
    /// runloop turn deliberately: by the time an asynchronous hop ran, the
    /// window would already have been ordered in as a separate window, and the
    /// merge would read as a visible flash.
    private final class TabbingHostView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DocumentWindowTabber.adopt(window, orderedWindows: NSApp.orderedWindows)
            DocumentWindowTabber.runTabSwitchProbeIfBenching(window)
        }
    }
}

extension DocumentTabbing.UserPreference {
    /// Mirrors AppKit's setting into the logic layer's AppKit-free vocabulary.
    /// `@unknown default` maps to the macOS default rather than the opt-out:
    /// a value we don't recognize is not evidence the user asked for no tabs.
    init(_ preference: NSWindow.UserTabbingPreference) {
        switch preference {
        case .manual: self = .manual
        case .inFullScreen: self = .inFullScreen
        case .always: self = .always
        @unknown default: self = .inFullScreen
        }
    }
}
