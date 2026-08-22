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
        let webView = try await loadedShell()

        // The production path: LiveDocument renders *and* resolves against the
        // file's own directory. Anything less would test a reimplementation.
        let document = LiveDocument(text: try String(contentsOf: fixture, encoding: .utf8), fileURL: fixture)
        _ = try await webView.evaluateJavaScript(
            MarkdownPage.renderBodyScript(bodyHTML: document.bodyHTML)
        )

        #expect(await waitUntil { try await self.naturalWidth(of: "img", in: webView) > 0 })
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

    /// Loads the real shell exactly as `MarkdownWebView` does. No window and
    /// no `Coordinator` here: nothing in this suite clicks a link or waits on
    /// an animation, which is what `ContentSecurityPolicyTests` needs those
    /// for.
    private func loadedShell() async throws -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1012, height: 800))
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
