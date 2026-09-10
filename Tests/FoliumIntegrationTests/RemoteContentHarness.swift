import AppKit
import Testing
import WebKit
@testable import Folium

/// Shared setup for the two remote-content suites (issue #19):
/// `RemoteContentBlockingTests`, which is about what each shell refuses, and
/// `RemoteContentOptInTests`, which is about what taking the offer does.
///
/// Everything here drives the app's own pieces — `MarkdownWebView
/// .configuration` registers the real `RemoteContentReporter`, and bodies go
/// in through `MarkdownPage.renderBodyScript`. What a test stands in for is
/// only SwiftUI's call into `updateNSView`, which no test can construct a
/// `Context` for.
@MainActor
struct RemoteContentHarness {
    static let viewFrame = NSRect(x: 0, y: 0, width: 1012, height: 800)

    /// The ceiling on how long a report may take to arrive. Reached only
    /// when the thing being waited for never happens — which for the tests
    /// asserting that *nothing* was refused is every run, and is the price
    /// of proving a negative. Generous, because a fixed wait that is merely
    /// long enough on this machine is a flake on a loaded one.
    static let reportTimeout = Duration.seconds(2)

    /// Polls until `condition` holds, or the ceiling is reached. A report
    /// arrives when WebKit dispatches it, and how long that takes is not
    /// something a test should hardcode.
    static func waitForReport(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + reportTimeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A web view collecting the page's reports with a test double, for a
    /// test that needs to read them rather than their effect.
    static func collectingWebView(
        allowingRemoteContent: Bool
    ) async throws -> (webView: WKWebView, collector: ReportCollector) {
        let collector = ReportCollector()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(collector, name: RemoteContent.messageName)
        let webView = WKWebView(frame: viewFrame, configuration: configuration)
        let waiter = ReloadableNavigationWaiter()
        webView.navigationDelegate = waiter
        try await load(shellAllowingRemoteContent: allowingRemoteContent, into: webView, waiter: waiter)
        return (webView, collector)
    }

    /// A web view wired to the app's real `RemoteContentReporter` and a real
    /// `RemoteContentState`, with a waiter that can be re-armed for the
    /// reload the opt-in triggers.
    static func reportingWebView(
        to state: RemoteContentState
    ) -> (webView: WKWebView, waiter: ReloadableNavigationWaiter) {
        let configuration = MarkdownWebView.configuration(documentDirectory: nil, remoteContent: state)
        let webView = WKWebView(frame: viewFrame, configuration: configuration)
        let waiter = ReloadableNavigationWaiter()
        webView.navigationDelegate = waiter
        return (webView, waiter)
    }

    static func load(
        shellAllowingRemoteContent allowingRemoteContent: Bool,
        into webView: WKWebView,
        waiter: ReloadableNavigationWaiter
    ) async throws {
        waiter.rearm()
        webView.loadFileURL(
            MarkdownPage.shellURL(allowingRemoteContent: allowingRemoteContent),
            allowingReadAccessTo: MarkdownPage.resourceBaseURL
        )
        await waiter.waitUntilFinished()
    }

    /// Renders a body the way the app does, and waits for `state` to reach
    /// `expected` — or, with no state given, just long enough for a report
    /// that should not exist to have arrived if it did.
    static func render(
        _ bodyHTML: String,
        into webView: WKWebView,
        settlingOn state: RemoteContentState? = nil,
        until expected: Bool = false
    ) async throws {
        _ = try await webView.evaluateJavaScript(MarkdownPage.renderBodyScript(bodyHTML: bodyHTML))
        guard let state else {
            try await Task.sleep(for: .milliseconds(200))
            return
        }
        try await waitForReport { state.hasBlockedContent == expected }
    }
}

/// One message the page posted, kept as raw fields so a test can assert on
/// what crossed the channel. `RemoteContentViolation` is what production
/// decodes with; this deliberately does not, so a test can catch the decoder
/// disagreeing with the page.
struct RemoteContentReport: Equatable {
    let kind: String
    let directive: String
    let blockedURI: String

    var violation: RemoteContentViolation {
        RemoteContentViolation(directive: directive, blockedURI: blockedURI)
    }
}

@MainActor
final class ReportCollector: NSObject, WKScriptMessageHandler {
    private(set) var reports: [RemoteContentReport] = []

    var violations: [RemoteContentReport] {
        reports.filter { $0.kind == RemoteContent.violationKind }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        reports.append(
            RemoteContentReport(
                kind: body["kind"] as? String ?? "",
                directive: body["directive"] as? String ?? "",
                blockedURI: body["blockedURI"] as? String ?? ""
            )
        )
    }
}

/// Bridges `didFinish` to `async/await`, and can be re-armed for the second
/// navigation the remote-content opt-in causes. A web view holds its
/// navigation delegate weakly, so tests keep a reference to it.
@MainActor
final class ReloadableNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    /// Call before each navigation, so a `didFinish` already delivered does
    /// not satisfy the wait for the navigation after it.
    func rearm() {
        finished = false
    }

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
