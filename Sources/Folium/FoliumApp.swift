import SwiftUI

@main
struct FoliumApp: App {
    // Turns on document/window state restoration, which SwiftUI's own app
    // delegate leaves off. See FoliumAppDelegate.
    @NSApplicationDelegateAdaptor(FoliumAppDelegate.self) private var appDelegate

    // One store for the whole app: rebinding a key in the Settings scene has
    // to reach every document window, which is a separate scene.
    @StateObject private var scrollKeys = ScrollKeyStore()

    // `App.init()` runs exactly once, unconditionally, as part of SwiftUI's
    // own launch sequence — unlike a top-level `let`, which only runs if
    // something later touches it. `BenchBudget.budgets` has nothing to wait
    // on, so this is where `scripts/bench.sh` reads the budgets instead of
    // keeping its own copy of them.
    init() {
        let marker = BenchMarker()
        for line in BenchBudget.budgetTableLines() {
            marker.writeLine(line)
        }
    }

    var body: some Scene {
        DocumentGroup(viewing: MarkdownDocument.self) { configuration in
            DocumentView(
                text: configuration.document.text,
                fileURL: configuration.fileURL,
                scrollKeys: scrollKeys
            )
            // Files this document's window into the app's shared native
            // tab group — the only way to reach the NSWindow that
            // DocumentGroup made for it. See DocumentWindowTabber.
            .background(DocumentWindowTabber())
        }

        // The Settings scene is what puts "Settings…" in the app menu at ⌘,
        // and manages the window behind it. Opening a preferences window
        // ourselves would be the lookalike CONTEXT.md priority 1 rules out.
        Settings {
            PreferencesView(scrollKeys: scrollKeys)
        }
    }
}

/// The contents of one document window, kept live against the file on disk
/// (issue #7).
///
/// This exists only because `@StateObject` has to live in a `View`, and
/// `DocumentGroup`'s content closure isn't one. All it does is keep a
/// `LiveDocument` alive for as long as the window is open.
///
/// Deliberately inside `FoliumApp.swift`, which is already excluded from the
/// coverage requirement: a file of its own would grow the exclusion list in
/// `scripts/coverage.sh` for something with nothing in it to test.
private struct DocumentView: View {
    @StateObject private var document: LiveDocument
    @ObservedObject var scrollKeys: ScrollKeyStore

    init(text: String, fileURL: URL?, scrollKeys: ScrollKeyStore) {
        _document = StateObject(wrappedValue: LiveDocument(text: text, fileURL: fileURL))
        self.scrollKeys = scrollKeys
    }

    var body: some View {
        MarkdownWebView(bodyHTML: document.bodyHTML, scrollKeys: scrollKeys.bindings)
    }
}
