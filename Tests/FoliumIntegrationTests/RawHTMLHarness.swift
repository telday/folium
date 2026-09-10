import AppKit
import Testing
import WebKit
@testable import Folium

/// Shared setup for the two raw-HTML suites (issue #20):
/// `RawHTMLSafetyTests`, which is about what a document's HTML is not
/// allowed to *do*, and `RawHTMLRenderingTests`, which is about what it does
/// *show*. Same change, seen from its two sides — see
/// [ADR 0009](../../docs/adr/0009-raw-html-sanitized-below-the-renderer.md).
///
/// Everything here drives the app's own pieces: the shell is loaded through
/// `MarkdownWebView.configuration` and `loadFileURL` the way `MarkdownWebView`
/// loads it, and content goes in through `MarkdownRenderer.renderHTML` plus
/// `MarkdownPage.renderBodyScript`. Hand-writing the HTML under test would
/// answer a question nobody asked: the renderer's option is half of what is
/// being tested.
@MainActor
enum RawHTMLHarness {
    static let viewFrame = NSRect(x: 0, y: 0, width: 1012, height: 800)

    /// Renders `markdown` the way the app does, into an already-loaded shell.
    static func render(_ markdown: String, in webView: WKWebView) async throws {
        let bodyHTML = MarkdownRenderer.renderHTML(from: markdown)
        _ = try await webView.evaluateJavaScript(MarkdownPage.renderBodyScript(bodyHTML: bodyHTML))
    }

    /// Loads the real shell through the app's own configuration builder, so
    /// the `folium-doc:` handler is the one the running app registers. No
    /// window and no `Coordinator`: the tests that click a link need both,
    /// and ask for `shellWithCoordinator` instead.
    static func shell(documentDirectory: URL? = nil) async throws -> WKWebView {
        let webView = WKWebView(
            frame: viewFrame,
            configuration: MarkdownWebView.configuration(
                documentDirectory: documentDirectory,
                remoteContent: RemoteContentState()
            )
        )
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadFileURL(MarkdownPage.pageURL, allowingReadAccessTo: MarkdownPage.resourceBaseURL)
        await waiter.waitUntilFinished()
        return webView
    }

    /// The same shell with the real `MarkdownWebView.Coordinator` behind it,
    /// in a real key `NSWindow` — what the clicking and navigation tests
    /// need, for the reason `ContentSecurityPolicyTests` records: a click
    /// only reaches `decidePolicyFor` the way it does in the running app
    /// once the view is in a window.
    static func shellWithCoordinator(
        openExternal: @escaping (URL) -> Void
    ) async throws -> (webView: WKWebView, waiter: CoordinatorWaiter) {
        let webView = WKWebView(
            frame: viewFrame,
            configuration: MarkdownWebView.configuration(
                documentDirectory: nil,
                remoteContent: RemoteContentState()
            )
        )
        let coordinator = MarkdownWebView.Coordinator(openExternal: openExternal)
        let waiter = CoordinatorWaiter(coordinator: coordinator)
        webView.navigationDelegate = waiter
        webView.loadFileURL(MarkdownPage.pageURL, allowingReadAccessTo: MarkdownPage.resourceBaseURL)
        await waiter.waitUntilFinished()

        let window = NSWindow(
            contentRect: viewFrame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // A programmatically created NSWindow releases itself on close, which
        // double-frees once ARC also lets go — a segfault that takes the
        // whole bundle down instead of failing a test (same fix as
        // ScrollKeyTests).
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        return (webView, waiter)
    }

    /// Runs `script` in the page with a `securitypolicyviolation` listener
    /// already attached, and reports the first directive that refused
    /// something — or `nil` if the policy allowed everything.
    ///
    /// Listener before content, in one evaluation, so there is no window in
    /// which a violation could fire unobserved. That shape is
    /// `ContentSecurityPolicyTests`'s; what differs here is that the caller
    /// supplies the whole statement, so one helper serves both "render this
    /// document" and "have the page build an element itself".
    static func violatedDirective(whileEvaluating script: String, in webView: WKWebView) async throws -> String? {
        let functionBody = """
        return await new Promise(function (resolve) {
          document.addEventListener('securitypolicyviolation', function handler(e) {
            document.removeEventListener('securitypolicyviolation', handler);
            resolve(e.violatedDirective);
          });
          \(script);
          // The violation fires pre-request, synchronously with CSP in
          // force; this is only a ceiling for the case something regresses.
          setTimeout(function () { resolve(null); }, 2000);
        });
        """
        let result = try await webView.callAsyncJavaScript(functionBody, in: nil, contentWorld: .page)
        return result as? String
    }

    /// The statement `violatedDirective(whileEvaluating:in:)` needs in order
    /// to put `markdown` on the page the way the app would.
    static func renderScript(for markdown: String) -> String {
        MarkdownPage.renderBodyScript(bodyHTML: MarkdownRenderer.renderHTML(from: markdown))
    }

    /// Whether any of the safety suite's payloads managed to run. They all
    /// assign the same flag, so one reader serves all of them.
    static func didExecute(in webView: WKWebView) async throws -> Bool {
        try await boolean("window.PWNED === true", in: webView)
    }

    static func boolean(_ expression: String, in webView: WKWebView) async throws -> Bool {
        let result = try await webView.evaluateJavaScript(expression)
        return (result as? Bool) ?? ((result as? Int) == 1)
    }

    static func string(_ expression: String, in webView: WKWebView) async throws -> String {
        let result = try await webView.evaluateJavaScript(expression)
        return (result as? String) ?? ""
    }

    static func number(_ expression: String, in webView: WKWebView) async throws -> Double {
        let result = try await webView.evaluateJavaScript(expression)
        return (result as? Double) ?? Double((result as? Int) ?? 0)
    }

    static func height(of selector: String, in webView: WKWebView) async throws -> Double {
        try await number("document.querySelector('\(selector)').getBoundingClientRect().height", in: webView)
    }

    /// Polls rather than sleeping a fixed duration. Used in both directions:
    /// waiting for something to happen, and — with a short timeout, and the
    /// result expected to be `false` — waiting long enough to be satisfied
    /// that it won't.
    static func waitUntil(
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

    /// Bridges `WKNavigationDelegate`'s completion callback to `async/await` for
    /// the tests that need no navigation policy of their own.
    @MainActor
    final class NavigationWaiter: NSObject, WKNavigationDelegate {
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

    /// Records what would have been opened externally, standing in for
    /// `NSWorkspace.shared.open(_:)` — see the `openExternal` doc comment on
    /// `MarkdownWebView.Coordinator` for why the production default is injected
    /// rather than called directly from a test.
    @MainActor
    final class OpenedURLRecorder {
        private(set) var openedURLs: [URL] = []
        func record(_ url: URL) { openedURLs.append(url) }
    }

    /// Forwards to a real `MarkdownWebView.Coordinator` — the production
    /// navigation delegate under test — while also resolving a continuation on
    /// `didFinish`, which `Coordinator` offers no way to wait for.
    @MainActor
    final class CoordinatorWaiter: NSObject, WKNavigationDelegate {
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
}
