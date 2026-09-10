import AppKit
import Testing
import WebKit
@testable import Folium

/// Seam tests for issue #19: a document's remote content stays blocked until
/// that document's own user asks for it, and asking actually permits the
/// load.
///
/// Everything here is asserted on what `Resources/remote-content.js` reports
/// back over the real page-to-native channel, driven through the real
/// `FoliumRenderBody` injection path. That is the seam this app owns — the
/// browser's own `securitypolicyviolation` event is upstream's, and whether
/// a badge server answers is the network's.
///
/// The event fires before a connection is opened, so none of these tests
/// need the target to be reachable. `example.invalid` is an IANA-reserved
/// domain guaranteed never to resolve, which is what keeps them
/// deterministic on a machine with no network.
@MainActor
@Suite(.serialized)
struct RemoteContentOptInTests {
    init() {
        AppKitHost.startIfNeeded()
    }

    // MARK: - Blocked by default

    @Test func aRemoteImageIsBlockedAndReportedUnderTheDefaultShell() async throws {
        let reports = try await reportsFromShell(
            allowingRemoteContent: false,
            rendering: #"<img src="https://example.invalid/badge.svg">"#
        )

        let violation = try #require(
            reports.first { $0.kind == "violation" },
            "the shell refused the remote image without reporting it"
        )
        #expect(violation.directive.hasPrefix("img-src"))
        #expect(violation.blockedURI.contains("example.invalid"))
        // The whole point of reporting it: this is what raises the offer.
        #expect(RemoteContent.isLoadable(directive: violation.directive, blockedURI: violation.blockedURI))
    }

    /// A live reload that removes the last remote image has to take the
    /// offer with it. Otherwise the bar goes on claiming something the file
    /// no longer says — the same class of untruth as a missing image.
    @Test func aLiveReloadThatRemovesTheLastRemoteImageWithdrawsTheOffer() async throws {
        let (webView, state) = try await shellReportingToItsOwnState()

        try await render(#"<img src="https://example.invalid/badge.svg">"#, into: webView)
        #expect(state.hasBlockedContent)

        try await render("<p>The badges are gone.</p>", into: webView)
        #expect(!state.hasBlockedContent)
    }

    /// And the other direction: a reload that introduces a remote image has
    /// to raise the offer, even though the render that precedes it clears
    /// whatever the last one found.
    @Test func aLiveReloadThatAddsARemoteImageRaisesTheOffer() async throws {
        let (webView, state) = try await shellReportingToItsOwnState()

        try await render("<p>Nothing remote here yet.</p>", into: webView)
        #expect(!state.hasBlockedContent)

        try await render(#"<img src="https://example.invalid/badge.svg">"#, into: webView)
        #expect(state.hasBlockedContent)
    }

    @Test func aDocumentWithNoRemoteContentReportsNothingToOffer() async throws {
        let reports = try await reportsFromShell(
            allowingRemoteContent: false,
            rendering: "<p>Just words.</p>"
        )
        #expect(!reports.contains { $0.kind == "violation" })
    }

    // MARK: - The opt-in permits the load

    @Test func aRemoteImageIsNotBlockedUnderTheOptInShell() async throws {
        let reports = try await reportsFromShell(
            allowingRemoteContent: true,
            rendering: #"<img src="https://example.invalid/badge.svg">"#
        )
        #expect(!reports.contains { $0.kind == "violation" })
    }

    /// Cleartext too. Blocking it after the user opted in would leave those
    /// images missing with the offer already dismissed and no way to ask
    /// again.
    @Test func aCleartextRemoteImageIsNotBlockedUnderTheOptInShell() async throws {
        let reports = try await reportsFromShell(
            allowingRemoteContent: true,
            rendering: #"<img src="http://example.invalid/badge.svg">"#
        )
        #expect(!reports.contains { $0.kind == "violation" })
    }

    /// The positive control for every "no violation" assertion above.
    ///
    /// Those tests read "nothing was refused" — which is also what a shell
    /// that failed to load, or that carries no policy at all, would produce.
    /// This proves the opt-in shell is a working page with its policy in
    /// force: its own scripts ran, and it still refuses what it should.
    @Test func theOptInShellIsAWorkingShellWithItsPolicyStillInForce() async throws {
        let (webView, collector) = try await loadedShell(allowingRemoteContent: true)
        defer { _ = collector }

        // The shell's own bundled assets loaded under its CSP: highlight.js
        // defines window.hljs, and code-block.js defines FoliumRenderBody.
        let scriptsRan = try await webView.evaluateJavaScript(
            "typeof window.hljs === 'object' && typeof window.FoliumRenderBody === 'function'"
        )
        #expect(scriptsRan as? Bool == true)

        // And the policy is still refusing things — it was relaxed, not removed.
        _ = try await webView.evaluateJavaScript(
            MarkdownPage.renderBodyScript(bodyHTML: #"<link rel="stylesheet" href="https://example.invalid/x.css">"#)
        )
        try await Task.sleep(for: Self.reportSettlingTime)
        #expect(collector.reports.contains { $0.kind == "violation" })
    }

    /// Opting in buys remote images, and nothing else. A remote stylesheet
    /// stays refused, and — because loading it is not something the opt-in
    /// could ever deliver — it must not raise the offer either.
    @Test func aRemoteStylesheetStaysBlockedUnderBothShellsAndOffersNothing() async throws {
        for allowingRemoteContent in [false, true] {
            let reports = try await reportsFromShell(
                allowingRemoteContent: allowingRemoteContent,
                rendering: #"<link rel="stylesheet" href="https://example.invalid/theme.css">"#
            )

            let violation = try #require(
                reports.first { $0.kind == "violation" },
                "a remote stylesheet was not refused (opt-in: \(allowingRemoteContent))"
            )
            #expect(violation.directive.hasPrefix("style-src"))
            #expect(!RemoteContent.isLoadable(directive: violation.directive, blockedURI: violation.blockedURI))
        }
    }

    // MARK: - The app's own reporter, not a stand-in

    /// Everything above collects reports with a test double, to read them.
    /// This drives the same channel into the real `RemoteContentReporter`
    /// and the real `RemoteContentState`, so the production translation from
    /// a posted message to a raised offer is covered too — that class lives
    /// in `MarkdownWebView.swift`, which is excluded from the unit-coverage
    /// requirement.
    @Test func theRealReporterRaisesTheOfferOnTheRealState() async throws {
        let (webView, state) = try await shellReportingToItsOwnState()

        #expect(!state.hasBlockedContent)
        try await render(#"<img src="https://example.invalid/badge.svg">"#, into: webView)
        #expect(state.hasBlockedContent)
        // Raising the offer must not be mistaken for taking it.
        #expect(!state.isAllowed)
    }

    /// Loads the default shell wired to the app's real `RemoteContentReporter`
    /// and a real `RemoteContentState`, through the app's own
    /// `MarkdownWebView.configuration`.
    private func shellReportingToItsOwnState() async throws -> (webView: WKWebView, state: RemoteContentState) {
        let state = RemoteContentState()
        let configuration = MarkdownWebView.configuration(documentDirectory: nil, remoteContent: state)
        let webView = WKWebView(frame: Self.viewFrame, configuration: configuration)
        let waiter = NavigationFinishWaiter()
        webView.navigationDelegate = waiter
        webView.loadFileURL(
            MarkdownPage.shellURL(allowingRemoteContent: false),
            allowingReadAccessTo: MarkdownPage.resourceBaseURL
        )
        await waiter.waitUntilFinished()
        return (webView, state)
    }

    /// Renders a body through the production injection path and waits for
    /// whatever the page reports about it to arrive.
    private func render(_ bodyHTML: String, into webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript(MarkdownPage.renderBodyScript(bodyHTML: bodyHTML))
        try await Task.sleep(for: Self.reportSettlingTime)
    }

    // MARK: - Helpers

    private static let viewFrame = NSRect(x: 0, y: 0, width: 1012, height: 800)

    /// How long to let the page's reports arrive. They are posted during the
    /// injection, not after a delay, so this is a ceiling for the case
    /// something regresses rather than a duration anything depends on.
    private static let reportSettlingTime = Duration.milliseconds(600)

    /// Loads a shell with a report collector attached to the same message
    /// name the app registers.
    private func loadedShell(
        allowingRemoteContent: Bool
    ) async throws -> (webView: WKWebView, collector: ReportCollector) {
        let collector = ReportCollector()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(collector, name: RemoteContent.messageName)
        let webView = WKWebView(frame: Self.viewFrame, configuration: configuration)
        let waiter = NavigationFinishWaiter()
        webView.navigationDelegate = waiter
        webView.loadFileURL(
            MarkdownPage.shellURL(allowingRemoteContent: allowingRemoteContent),
            allowingReadAccessTo: MarkdownPage.resourceBaseURL
        )
        await waiter.waitUntilFinished()
        return (webView, collector)
    }

    /// Renders `bodyHTML` through the production injection path and returns
    /// every report the page posted back.
    private func reportsFromShell(
        allowingRemoteContent: Bool,
        rendering bodyHTML: String
    ) async throws -> [Report] {
        let (webView, collector) = try await loadedShell(allowingRemoteContent: allowingRemoteContent)
        _ = try await webView.evaluateJavaScript(MarkdownPage.renderBodyScript(bodyHTML: bodyHTML))
        try await Task.sleep(for: Self.reportSettlingTime)
        return collector.reports
    }

    struct Report: Equatable {
        let kind: String
        let directive: String
        let blockedURI: String
    }

    /// Stands in for `RemoteContentReporter` where a test needs to read the
    /// reports rather than their effect.
    @MainActor
    final class ReportCollector: NSObject, WKScriptMessageHandler {
        private(set) var reports: [Report] = []

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            reports.append(
                Report(
                    kind: body["kind"] as? String ?? "",
                    directive: body["directive"] as? String ?? "",
                    blockedURI: body["blockedURI"] as? String ?? ""
                )
            )
        }
    }
}

/// Bridges `didFinish` to `async/await`. No `decidePolicyFor` override:
/// nothing in this suite clicks a link, and running the real `Coordinator`
/// here would only add a policy decision none of these tests are about.
@MainActor
private final class NavigationFinishWaiter: NSObject, WKNavigationDelegate {
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
