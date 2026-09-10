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
    /// Per window, created here and stored nowhere else: opting one document
    /// into remote content must not opt in anything else, now or later
    /// (issue #19).
    @StateObject private var remoteContent = RemoteContentState()
    @ObservedObject var scrollKeys: ScrollKeyStore

    init(text: String, fileURL: URL?, scrollKeys: ScrollKeyStore) {
        _document = StateObject(wrappedValue: LiveDocument(text: text, fileURL: fileURL))
        self.scrollKeys = scrollKeys
    }

    var body: some View {
        MarkdownWebView(
            bodyHTML: document.bodyHTML,
            scrollKeys: scrollKeys.bindings,
            // Taken from the document rather than derived again here, so the
            // directory the body's references were rewritten against is the
            // one the scheme handler resolves them back against (issue #18).
            documentDirectory: document.documentDirectory,
            remoteContent: remoteContent
        )
        // A safe-area inset, not an overlay: this reserves its own height, so
        // the top of the document sits below the bar instead of behind it,
        // and the web view's own scrolling accounts for it.
        .safeAreaInset(edge: .top, spacing: 0) {
            if remoteContent.hasBlockedContent {
                RemoteContentBar { remoteContent.allow() }
            }
        }
    }
}

/// The offer to load a document's blocked remote content (issue #19).
///
/// Native chrome around the document rather than markup inside it, per
/// `CONTEXT.md` priority 3: the document belongs to GitHub's rendering, and
/// everything around it belongs to macOS. Injecting this as HTML would also
/// put it in the user's ⌘F results and in a copied selection.
private struct RemoteContentBar: View {
    let load: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("This document contains remote images.")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Load", action: load)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        // `.bar` is the material AppKit uses behind a window's own
        // accessory bars, so this picks up the system's vibrancy and its
        // light/dark appearance without naming a colour.
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
