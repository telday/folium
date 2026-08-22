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
