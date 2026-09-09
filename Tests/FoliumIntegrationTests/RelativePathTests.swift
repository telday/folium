import AppKit
import Testing
import WebKit
@testable import Folium

/// Seam tests for issue #18: a document's relative `src`/`href` values have
/// to resolve against **the document's own directory**, not the app bundle
/// the page shell is loaded from.
///
/// The bug this guards is silent: the shell lives in
/// `MarkdownPage.resourceBaseURL`, so `![](./sibling.png)` used to resolve to
/// a file inside the bundle that does not exist, and the document rendered a
/// broken image with nothing to indicate anything was missing — a floor-1
/// ("the document says what the file says") violation.
///
/// These drive the real pipeline — a real fixture file read off disk, through
/// `LiveDocument` (which is what applies `DocumentRelativeLinks`), into the
/// real shell — rather than hand-writing the resolved HTML, so a regression
/// anywhere along that path shows up here.
@MainActor
@Suite(.serialized)
struct RelativePathTests {
    init() {
        AppKitHost.startIfNeeded()
    }

    /// The Definition of Done for issue #18 asks specifically for proof the
    /// image **loads**, not that an `<img>` element exists: a resolved-wrong
    /// `src` still produces a perfectly good element, so asserting on the DOM
    /// shape alone would pass against the broken behaviour. `naturalWidth` is
    /// non-zero only once WebKit has actually decoded the file.
    @Test func siblingImageReferencedRelativelyActuallyLoads() async throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "relative-image", withExtension: "md", subdirectory: "Fixtures"),
            "missing Fixtures/relative-image.md"
        )
        let webView = try await loadedShell(documentDirectory: fixture.deletingLastPathComponent())

        // The production path: LiveDocument renders *and* resolves against the
        // file's own directory. Anything less would test a reimplementation.
        let document = LiveDocument(text: try String(contentsOf: fixture, encoding: .utf8), fileURL: fixture)
        _ = try await webView.evaluateJavaScript(
            MarkdownPage.renderBodyScript(bodyHTML: document.bodyHTML)
        )

        #expect(await waitUntil { try await self.naturalWidth(of: "img", in: webView) > 0 })
    }

    /// The teeth of `DocumentResourceResolver`'s containment check, proven
    /// through the real `WKURLSchemeHandler` rather than by calling the
    /// resolver directly (`DocumentResourceResolverTests` already does
    /// that): this is what an attacker actually controls, a `src` value
    /// baked straight into rendered HTML. `DocumentRelativeLinks` only ever
    /// emits a `folium-doc:` URL that stays inside the document's own
    /// directory, so the one way this string reaches the handler is a
    /// document that spells out the scheme by hand — which `resolve` leaves
    /// untouched as an already-absolute reference (see its doc comment),
    /// same as it would leave a literal `file:` URL untouched.
    @Test func traversalOutsideTheDocumentDirectoryIsRefused() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let webView = try await loadedShell(documentDirectory: directory)

        let result = try await loadImage(src: "folium-doc://doc/../../../../../../etc/passwd", in: webView)

        #expect(result == .failed)
    }

    /// The other half of containment: a symlink *inside* the document's own
    /// directory that resolves to a file outside it. `DocumentResourceResolverTests`
    /// covers this against the resolver directly; this proves the same thing
    /// end to end, through the handler WebKit actually calls.
    @Test func symlinkEscapingTheDocumentDirectoryIsRefused() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secretDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: secretDirectory) }
        let secretFile = secretDirectory.appendingPathComponent("secret.png")
        try Self.onePixelPNG.write(to: secretFile)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("escape.png"),
            withDestinationURL: secretFile
        )
        let webView = try await loadedShell(documentDirectory: directory)

        let result = try await loadImage(src: "folium-doc://doc/escape.png", in: webView)

        #expect(result == .failed)
    }

    /// Widening what the document can reach must not widen what the *network*
    /// can reach. Issue #18 was blocked on #17 for exactly this reason, so the
    /// guard is re-asserted here rather than left to the other suite: it would
    /// be easy to "fix" a stubborn relative path by loosening `img-src`.
    @Test func resolvingRelativePathsDoesNotUnblockRemoteImages() async throws {
        let webView = try await loadedShell()
        let violation = try await recordFirstCSPViolation(
            on: webView,
            injecting: #"<img id="remote" src="https://example.invalid/leak.png">"#
        )

        let recorded = try #require(violation, "no securitypolicyviolation fired for the remote <img>")
        #expect(recorded["directive"] as? String == "img-src")
    }

    // MARK: - Sibling document links (issue #18, user story 2)

    /// The other half of issue #18: a link to a sibling Markdown file has to
    /// work, not just an image. That path ends in
    /// `MarkdownWebView.Coordinator.decidePolicyFor`, which is
    /// coverage-excluded glue — so per `CONTEXT.md`'s third floor its
    /// behaviour is owed an integration test rather than a unit one.
    ///
    /// Driven through the whole real pipeline: Markdown on disk →
    /// `LiveDocument` (which applies `DocumentRelativeLinks`) → the shell →
    /// a real click → the real `Coordinator`. Only `NSWorkspace` is stood in
    /// for, so the test records what would have opened instead of launching
    /// another copy of the app mid-suite.
    @Test func clickingASiblingMarkdownLinkOpensItInsteadOfNavigating() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sibling = directory.appendingPathComponent("notes.md")
        try "# Notes".write(to: sibling, atomically: true, encoding: .utf8)
        let readme = directory.appendingPathComponent("README.md")
        try "[the notes](./notes.md)".write(to: readme, atomically: true, encoding: .utf8)

        let recorder = OpenedURLRecorder()
        let (webView, waiter) = try await loadedShellWithCoordinator(
            documentDirectory: directory,
            openDocument: { recorder.record($0) }
        )
        defer { webView.window?.close() }
        _ = waiter // kept alive: `navigationDelegate` is a weak reference

        let document = LiveDocument(text: try String(contentsOf: readme, encoding: .utf8), fileURL: readme)
        _ = try await webView.evaluateJavaScript(MarkdownPage.renderBodyScript(bodyHTML: document.bodyHTML))
        _ = try await webView.evaluateJavaScript("document.querySelector('#markdown-content a').click();")

        #expect(await waitUntil { recorder.openedURLs.count == 1 })
        #expect(recorder.openedURLs == [sibling.standardizedFileURL.resolvingSymlinksInPath()])
        // Cancelled, so the document the user was reading is still on screen.
        #expect(webView.url?.path == MarkdownPage.pageURL.path)
    }

    /// The allowlist, end to end: `install.command` next to a README is as
    /// reachable by containment as `notes.md` is, and `.openDocument` hands
    /// its URL to `NSWorkspace`, which would *launch* it. A click on one
    /// must do nothing at all — neither open nor navigate.
    @Test func clickingASiblingLinkToANonMarkdownFileDoesNothing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "echo pwned".write(
            to: directory.appendingPathComponent("install.command"),
            atomically: true,
            encoding: .utf8
        )
        let readme = directory.appendingPathComponent("README.md")
        try "[run the installer](./install.command)".write(to: readme, atomically: true, encoding: .utf8)

        let recorder = OpenedURLRecorder()
        let (webView, waiter) = try await loadedShellWithCoordinator(
            documentDirectory: directory,
            openDocument: { recorder.record($0) }
        )
        defer { webView.window?.close() }
        _ = waiter // kept alive: `navigationDelegate` is a weak reference

        let document = LiveDocument(text: try String(contentsOf: readme, encoding: .utf8), fileURL: readme)
        _ = try await webView.evaluateJavaScript(MarkdownPage.renderBodyScript(bodyHTML: document.bodyHTML))
        _ = try await webView.evaluateJavaScript("document.querySelector('#markdown-content a').click();")

        // Nothing to wait *for*, so the assertion has to be that nothing
        // happened within a window long enough for it to have happened.
        #expect(await waitUntil(within: .milliseconds(500)) { !recorder.openedURLs.isEmpty } == false)
        #expect(webView.url?.path == MarkdownPage.pageURL.path)
    }

    // MARK: - Helpers

    /// A 1x1 transparent PNG — the smallest file that is unambiguously a
    /// real, loadable image rather than a stand-in. Mirrors
    /// `ContentSecurityPolicyTests`'s fixture of the same shape.
    private static let onePixelPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    /// Loads the real shell exactly as `MarkdownWebView` does — including
    /// registering a `folium-doc:` scheme handler for `documentDirectory`,
    /// the same wiring `MarkdownWebView.makeNSView` does before creating its
    /// web view (`setURLSchemeHandler(_:forURLScheme:)` cannot be called
    /// afterwards). No window and no `Coordinator` here: nothing in this
    /// suite clicks a link or waits on an animation, which is what
    /// `ContentSecurityPolicyTests` needs those for.
    private func loadedShell(documentDirectory: URL? = nil) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let documentDirectory {
            let schemeHandler = DocumentResourceSchemeHandler(documentDirectory: documentDirectory)
            configuration.setURLSchemeHandler(schemeHandler, forURLScheme: DocumentResourceResolver.scheme)
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1012, height: 800), configuration: configuration)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadFileURL(MarkdownPage.pageURL, allowingReadAccessTo: MarkdownPage.resourceBaseURL)
        await waiter.waitUntilFinished()
        return webView
    }

    /// The same shell, but with a real `MarkdownWebView.Coordinator` as the
    /// navigation delegate and attached to a real key `NSWindow` — what the
    /// two clicking tests above need and the resource tests don't.
    /// `ContentSecurityPolicyTests` found the window necessary for a click to
    /// reach `decidePolicyFor` the way it does in the running app.
    private func loadedShellWithCoordinator(
        documentDirectory: URL,
        openDocument: @escaping (URL) -> Void
    ) async throws -> (webView: WKWebView, waiter: CoordinatorWaiter) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            DocumentResourceSchemeHandler(documentDirectory: documentDirectory),
            forURLScheme: DocumentResourceResolver.scheme
        )
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1012, height: 800),
            configuration: configuration
        )
        let coordinator = MarkdownWebView.Coordinator(
            documentDirectory: documentDirectory,
            openDocument: openDocument
        )
        let waiter = CoordinatorWaiter(coordinator: coordinator)
        webView.navigationDelegate = waiter
        webView.loadFileURL(MarkdownPage.pageURL, allowingReadAccessTo: MarkdownPage.resourceBaseURL)
        await waiter.waitUntilFinished()

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // A programmatically created NSWindow releases itself on close, which
        // double-frees once ARC also lets go — a segfault that takes the whole
        // bundle down instead of failing a test (same fix as ScrollKeyTests).
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        return (webView, waiter)
    }

    private func naturalWidth(of selector: String, in webView: WKWebView) async throws -> Double {
        let result = try await webView.evaluateJavaScript(
            "document.querySelector('\(selector)')?.naturalWidth ?? 0"
        )
        return (result as? Double) ?? Double((result as? Int) ?? 0)
    }

    private enum ImageLoadResult: Equatable {
        case loaded
        case failed
    }

    /// Appends an `<img src="\(src)">` to the page and waits for its own
    /// `load`/`error` event, rather than polling `naturalWidth` the way
    /// `siblingImageReferencedRelativelyActuallyLoads` does: a refused
    /// request never becomes non-zero, so a poll can only prove "hasn't
    /// loaded *yet*", not "was refused". Watching for `error` distinguishes
    /// a real refusal from a slow load.
    private func loadImage(src: String, in webView: WKWebView) async throws -> ImageLoadResult {
        let srcJSON = try JSONEncoder().encode(src)
        let srcJSString = String(data: srcJSON, encoding: .utf8)!
        let functionBody = """
        return new Promise(function (resolve) {
          var img = document.createElement('img');
          img.onload = function () { resolve('loaded'); };
          img.onerror = function () { resolve('failed'); };
          img.src = \(srcJSString);
          document.body.appendChild(img);
          setTimeout(function () { resolve('failed'); }, 3000);
        });
        """
        let result = try await webView.callAsyncJavaScript(functionBody, in: nil, contentWorld: .page)
        return (result as? String) == "loaded" ? .loaded : .failed
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelativePathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Polls rather than sleeping: how long WebKit takes to decode a file off
    /// disk is not a fixed duration, and a fixed sleep is either flaky or slow.
    private func waitUntil(
        within timeout: Duration = .seconds(5),
        _ condition: () async throws -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// Mirrors `ContentSecurityPolicyTests`: listener attached before the
    /// content in one evaluation, and injection via `innerHTML` — the same
    /// DOM path `window.FoliumRenderBody` uses, and the only one observed to
    /// fire the event reliably.
    private func recordFirstCSPViolation(
        on webView: WKWebView,
        injecting html: String
    ) async throws -> [String: Any]? {
        let htmlJSON = try JSONEncoder().encode(html)
        let htmlJSString = String(data: htmlJSON, encoding: .utf8)!
        let result = try await webView.callAsyncJavaScript(
            """
            return await new Promise(function (resolve) {
              document.addEventListener('securitypolicyviolation', function handler(e) {
                document.removeEventListener('securitypolicyviolation', handler);
                resolve({ directive: e.violatedDirective, blockedURI: String(e.blockedURI) });
              });
              document.getElementById('markdown-content').innerHTML = \(htmlJSString);
              window.setTimeout(function () { resolve(null); }, 3000);
            });
            """,
            contentWorld: .page
        )
        return result as? [String: Any]
    }
}

/// Resolves once the shell's one-time `didFinish` fires.
///
/// `navigationDelegate` is a **weak** reference, so this has to be held by the
/// caller for the duration — letting it go out of scope silently drops the
/// callback and the `await` never returns.
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

/// Records what would have been handed to `NSWorkspace.shared.open(_:)` —
/// see `MarkdownWebView.Coordinator.openDocument` for why the production
/// default is injected rather than called for real in a test.
@MainActor
private final class OpenedURLRecorder {
    private(set) var openedURLs: [URL] = []
    func record(_ url: URL) { openedURLs.append(url) }
}

/// Forwards to a real `MarkdownWebView.Coordinator` — the production
/// navigation delegate under test — while also resolving a continuation on
/// `didFinish`, since `Coordinator` exposes no way to wait for the shell to
/// finish loading. Mirrors `ContentSecurityPolicyTests`'s waiter of the same
/// name; kept per-suite because each is `private` to its own file.
@MainActor
private final class CoordinatorWaiter: NSObject, WKNavigationDelegate {
    private let coordinator: MarkdownWebView.Coordinator
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    init(coordinator: MarkdownWebView.Coordinator) {
        self.coordinator = coordinator
    }

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        coordinator.webView(webView, didFinish: navigation)
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        coordinator.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
    }
}
