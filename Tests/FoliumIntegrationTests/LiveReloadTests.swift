import AppKit
import Combine
import Foundation
import Testing
import WebKit
@testable import Folium

/// End-to-end live-reload (issue #7): a real file, a real watch, the real
/// coalescing window on the real clock, and a real `WKWebView` showing the
/// result.
///
/// The unit tests drive each piece with the timing held still. Only this tier
/// shows that the pieces are connected — that editing the file elsewhere
/// changes the pixels, with nothing asked of the user. It also covers the
/// `DocumentView` glue in the excluded `FoliumApp.swift`, which does nothing
/// but hold a `LiveDocument` and pass its body HTML to `MarkdownWebView`.
@MainActor
struct LiveReloadTests {
    @Test func anExternalEditRepaintsTheDocumentWithNothingAskedOfTheUser() async throws {
        let file = try TempFile(contents: "# Before")
        let document = LiveDocument(text: "# Before", fileURL: file.url)
        let webView = try await loadedWebView(showing: document.bodyHTML)
        #expect(try await heading(of: webView) == "Before")

        // The whole feature, in one line: somebody else writes the file.
        try file.write("# After")

        #expect(await waitUntil { document.bodyHTML.contains("<h1>After</h1>") })
        try await inject(document.bodyHTML, into: webView)
        #expect(try await heading(of: webView) == "After")
    }

    @Test func anAtomicSaveRepaints_andTheWatchSurvivesToDoItAgain() async throws {
        // How most editors save. Getting it wrong gives a document that
        // live-reloads exactly once and then quietly stops, which is why the
        // second save is asserted and not just the first.
        let file = try TempFile(contents: "# One")
        let document = LiveDocument(text: "# One", fileURL: file.url)

        try file.atomicallyReplace(with: "# Two")
        #expect(await waitUntil { document.bodyHTML.contains("<h1>Two</h1>") })

        try file.atomicallyReplace(with: "# Three")
        #expect(await waitUntil { document.bodyHTML.contains("<h1>Three</h1>") })

        let webView = try await loadedWebView(showing: document.bodyHTML)
        #expect(try await heading(of: webView) == "Three")
    }

    @Test func aBurstOfWritesRepaintsOnceRatherThanOncePerWrite() async throws {
        // An autosave, or a formatter running on save: every write here is a
        // reload's worth of file-system events on its own.
        let file = try TempFile(contents: "# Start")
        let document = LiveDocument(text: "# Start", fileURL: file.url)
        let repaints = Counter()
        let subscription = document.$bodyHTML.dropFirst().sink { _ in repaints.increment() }
        defer { subscription.cancel() }

        for index in 1...10 { try file.write("# Write \(index)") }

        #expect(await waitUntil { document.bodyHTML.contains("<h1>Write 10</h1>") })
        // Let anything still pending come through before counting, so a storm
        // can't hide behind the assertion above.
        try await Task.sleep(for: LiveReload.coalescingWindow * 6)

        // Ten writes, one repaint. Two is allowed in case the first window
        // closed before the rest of the burst arrived; ten would mean the
        // coalescer isn't doing anything.
        #expect(repaints.total >= 1)
        #expect(repaints.total <= 2)
        #expect(document.bodyHTML.contains("<h1>Write 10</h1>"))
    }

    @Test func aRenderedDocumentKeepsItsShellAcrossReloads() async throws {
        // Content updates patch the page shell rather than reloading it. If a
        // live-reload ever started reloading the shell, this marker, set after
        // the first paint, would be gone.
        let file = try TempFile(contents: "# Before")
        let document = LiveDocument(text: "# Before", fileURL: file.url)
        let webView = try await loadedWebView(showing: document.bodyHTML)
        _ = try await webView.evaluateJavaScript("window.foliumShellMarker = 'alive'")

        try file.write("# After")
        #expect(await waitUntil { document.bodyHTML.contains("<h1>After</h1>") })
        try await inject(document.bodyHTML, into: webView)

        #expect(try await heading(of: webView) == "After")
        let marker = try await webView.evaluateJavaScript("window.foliumShellMarker") as? String
        #expect(marker == "alive")
    }

    @Test func callAsyncJavaScriptActuallyWaitsRatherThanReturningImmediately() async throws {
        // The `first-paint` marker's whole timing story rests on one WebKit
        // fact: `evaluateJavaScript` does not wait for a returned `Promise`
        // to settle. Confirmed directly against a real `WKWebView` while
        // building this — a script whose completion value is a pending
        // `Promise` fails immediately with "unsupported type" rather than
        // waiting for it. `callAsyncJavaScript` is the API that actually
        // waits: it runs the string as an `async` function body and only
        // calls back once that function's own `await`s finish, which is what
        // `MarkdownWebView` uses for `MarkdownPage.paintConfirmationScript`.
        //
        // Verified here with a timer rather than that script itself:
        // `requestAnimationFrame` never fires for a `WKWebView` under
        // `swift test` — also confirmed directly, by watching it hang
        // indefinitely — because this process has no compositor connection
        // for the view to paint through. The double-rAF path itself can only
        // be exercised by `make bench` against the real, windowed app.
        let webView = try await loadedWebView(showing: "<h1>Paint me</h1>")

        let start = ContinuousClock.now
        let result = try await webView.callAsyncJavaScript(
            "await new Promise(resolve => setTimeout(resolve, 50)); return true;",
            contentWorld: .page
        )
        let elapsed = start.duration(to: .now)

        #expect(result as? Bool == true)
        #expect(elapsed >= .milliseconds(50))
    }

    @Test func aFileThatCannotBeWatchedStillOpensAndRenders() async throws {
        // A path Folium can't watch must not cost the user the document.
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).md")
        let document = LiveDocument(text: "# Opened anyway", fileURL: missing)

        let webView = try await loadedWebView(showing: document.bodyHTML)

        #expect(try await heading(of: webView) == "Opened anyway")
    }

    // MARK: - Helpers

    /// Polls, because the point is to observe the real timing. The generous
    /// ceiling is there to fail a broken reload, not to measure a working one:
    /// `make bench` owns the latency numbers, since per CONTEXT.md a
    /// wall-clock gate on a shared CI runner measures noise.
    private func waitUntil(
        within timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Mirrors `MarkdownWebView`: load the static shell once, then push
    /// content into it with `evaluateJavaScript`.
    private func loadedWebView(showing bodyHTML: String) async throws -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1012, height: 800))
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadFileURL(MarkdownPage.pageURL, allowingReadAccessTo: MarkdownPage.resourceBaseURL)
        await waiter.waitUntilFinished()
        try await inject(bodyHTML, into: webView)
        return webView
    }

    private func inject(_ bodyHTML: String, into webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript(MarkdownPage.renderBodyScript(bodyHTML: bodyHTML))
    }

    private func heading(of webView: WKWebView) async throws -> String {
        let result = try await webView.evaluateJavaScript("document.querySelector(\"h1\").textContent")
        return (result as? String) ?? ""
    }
}

/// Bridges WebKit's load-finished callback to `async/await`, so a test can
/// wait for the shell before injecting content.
@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class Counter {
    private(set) var total = 0

    func increment() {
        total += 1
    }
}

/// A Markdown file in its own temporary directory, deleted when the test's
/// reference to it goes away.
private final class TempFile {
    let url: URL
    private let directory: URL

    init(contents: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoliumIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("document.md")
        try write(contents)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func write(_ contents: String) throws {
        try Data(contents.utf8).write(to: url)
    }

    /// Saves the way an editor does: a temporary file renamed over the
    /// original.
    func atomicallyReplace(with contents: String) throws {
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: staging)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
    }
}
