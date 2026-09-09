import AppKit
import Testing
@testable import Folium

/// Seam tests for `FoliumAppDelegate`, which is on the coverage exclusion list
/// and so owes its coverage here (issue #5).
///
/// Both assertions guard a setting that fails *silently*: with either one
/// missing, the app still launches, still opens files, and simply comes up
/// empty after a quit instead of reopening what was open. Verified against the
/// built app both ways before these were written.
@MainActor
struct DocumentRestorationTests {
    @Test func launchingRegistersTheKeepWindowsDefault() {
        let delegate = FoliumAppDelegate()

        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        #expect(UserDefaults.standard.bool(forKey: DocumentRestoration.quitAlwaysKeepsWindowsKey))
    }

    @Test func theAppOptsIntoSecureRestorableState() {
        // AppKit persists nothing at all for an app that answers `false` here,
        // so restoration is off before this ever reaches a window.
        #expect(FoliumAppDelegate().applicationSupportsSecureRestorableState(NSApplication.shared))
    }

    /// `scripts/bench.sh` sets FOLIUM_BENCH_OPEN so cold launch can be timed
    /// against a real window (see the doc comment on
    /// `applicationDidFinishLaunching`); every real user launches with it
    /// unset, and this is the half of that behavior a test process can
    /// verify safely. The positive case — that setting it actually opens the
    /// document — needs `NSDocumentController` to resolve `MarkdownDocument`
    /// for the Markdown UTI, which only happens once `DocumentGroup` has
    /// registered it as part of a live `FoliumApp` scene; `swift test` never
    /// constructs one, the same reason `MarkdownDocument.swift` itself is
    /// off the coverage list. `make bench`, run against the real app, is
    /// where that half is actually exercised end to end.
    @Test func benchOpenHookDoesNothingWhenTheEnvVarIsUnset() {
        unsetenv("FOLIUM_BENCH_OPEN")
        let before = NSDocumentController.shared.documents.count

        FoliumAppDelegate().applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        #expect(NSDocumentController.shared.documents.count == before)
    }
}
