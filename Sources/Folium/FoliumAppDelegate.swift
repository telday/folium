import AppKit
import Foundation

/// Opts Folium into AppKit's document/window state restoration, which a
/// SwiftUI `DocumentGroup` app does not get by default (issue #5), and puts
/// the app's out-of-the-box preferences in place.
///
/// Host glue: it exists only to answer AppKit at launch. The settings it
/// applies, and why each is required, live in `DocumentRestoration` and
/// `ScrollKeyStore` in the logic layer.
final class FoliumAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: DocumentRestoration.registrationDefaults)
        UserDefaults.standard.register(defaults: ScrollKeyStore.registrationDefaults)
    }

    /// `scripts/bench.sh` needs a document open the instant launch finishes,
    /// so it can time cold launch against a real window. Finder and `open`
    /// both do this through an Apple Event, but that event only reaches an
    /// app process Launch Services itself spawned — not one this script
    /// starts directly, which it has to do to read the process's own
    /// stderr. `BenchOpen` reaches the same `NSDocumentController` call a
    /// double-click would, just triggered by an environment variable
    /// instead of an Apple Event. Unset for every real user, so this is
    /// inert outside a bench run.
    ///
    /// The activation is not cosmetic. `MarkdownWebView`'s paint
    /// confirmation waits on `requestAnimationFrame`, and WebKit does not
    /// run animation-frame callbacks for a window that isn't on screen — a
    /// process started from a terminal stays behind whatever was already
    /// frontmost, so without this the callback never fires and the run
    /// reports "not measured" instead of a number. Measured directly: 0 of
    /// 6 unactivated runs produced a `first-paint` marker.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let url = BenchOpen.url() else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    /// Folium keeps no secrets in its restorable state — a document window
    /// records which file it shows — and secure coding is what AppKit requires
    /// before it will persist any of it.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
