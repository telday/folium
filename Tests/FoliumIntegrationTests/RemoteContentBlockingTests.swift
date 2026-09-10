import Testing
import WebKit
@testable import Folium

/// Issue #19's first half: a document's remote content is blocked until its
/// own user asks for it, and the block is reported rather than silent.
///
/// Asserted on what `Resources/remote-content.js` reports back over the real
/// page-to-native channel, driven through the real `FoliumRenderBody`
/// injection path. That is the seam this app owns — the browser's
/// `securitypolicyviolation` event is upstream's, and whether a badge server
/// answers is the network's.
///
/// The event fires before a connection is opened, so nothing here needs the
/// target to be reachable. `example.invalid` is an IANA-reserved domain
/// guaranteed never to resolve, which keeps these deterministic on a machine
/// with no network.
@MainActor
@Suite(.serialized)
struct RemoteContentBlockingTests {
    init() {
        AppKitHost.startIfNeeded()
    }

    @Test func aRemoteImageIsBlockedAndReportedUnderTheDefaultShell() async throws {
        let reports = try await violations(
            underShellAllowingRemoteContent: false,
            rendering: #"<img src="https://example.invalid/badge.svg">"#
        )

        let violation = try #require(
            reports.first,
            "the shell refused the remote image without reporting it"
        )
        #expect(violation.directive.hasPrefix("img-src"))
        #expect(violation.blockedURI.contains("example.invalid"))
        // The whole point of reporting it: this is what raises the offer.
        #expect(violation.violation.isLoadable)
    }

    @Test func aDocumentWithNoRemoteContentReportsNothingToOffer() async throws {
        let reports = try await violations(
            underShellAllowingRemoteContent: false,
            rendering: "<p>Just words.</p>"
        )
        #expect(reports.isEmpty)
    }

    @Test func aRemoteImageIsNotBlockedUnderTheOptInShell() async throws {
        let reports = try await violations(
            underShellAllowingRemoteContent: true,
            rendering: #"<img src="https://example.invalid/badge.svg">"#
        )
        #expect(reports.isEmpty)
    }

    /// Cleartext too. Blocking it after the user opted in would leave those
    /// images missing with the offer already dismissed and no way to ask
    /// again.
    @Test func aCleartextRemoteImageIsNotBlockedUnderTheOptInShell() async throws {
        let reports = try await violations(
            underShellAllowingRemoteContent: true,
            rendering: #"<img src="http://example.invalid/badge.svg">"#
        )
        #expect(reports.isEmpty)
    }

    /// The positive control for every "no violation" assertion above.
    ///
    /// Those read "nothing was refused" — which is also what a shell that
    /// failed to load, or that carries no policy at all, would produce. This
    /// proves the opt-in shell is a working page with its policy in force:
    /// its own bundled scripts ran, and it still refuses what it should.
    @Test func theOptInShellIsAWorkingShellWithItsPolicyStillInForce() async throws {
        let (webView, collector) = try await RemoteContentHarness.collectingWebView(allowingRemoteContent: true)

        // highlight.js defines window.hljs; code-block.js defines
        // FoliumRenderBody. Both loaded under the opt-in shell's CSP.
        let scriptsRan = try await webView.evaluateJavaScript(
            "typeof window.hljs === 'object' && typeof window.FoliumRenderBody === 'function'"
        )
        #expect(scriptsRan as? Bool == true)

        try await RemoteContentHarness.render(
            #"<link rel="stylesheet" href="https://example.invalid/x.css">"#,
            into: webView
        )
        try await RemoteContentHarness.waitForReport { !collector.violations.isEmpty }
        #expect(!collector.violations.isEmpty, "the opt-in shell refused nothing at all")
    }

    /// Opting in buys remote images, and nothing else. A remote stylesheet
    /// stays refused, and — because loading it is not something the opt-in
    /// could ever deliver — it must not raise the offer either.
    @Test func aRemoteStylesheetStaysBlockedUnderBothShellsAndOffersNothing() async throws {
        for allowingRemoteContent in [false, true] {
            let reports = try await violations(
                underShellAllowingRemoteContent: allowingRemoteContent,
                rendering: #"<link rel="stylesheet" href="https://example.invalid/theme.css">"#
            )

            let violation = try #require(
                reports.first,
                "a remote stylesheet was not refused (opt-in: \(allowingRemoteContent))"
            )
            #expect(violation.directive.hasPrefix("style-src"))
            #expect(!violation.violation.isLoadable)
        }
    }

    /// The app's own reporter and state, rather than the collector the other
    /// tests read. `RemoteContentReporter` lives in `MarkdownWebView.swift`,
    /// which is excluded from the unit-coverage requirement, so this is what
    /// covers the translation from a posted message to a raised offer.
    @Test func theRealReporterRaisesTheOfferOnTheRealState() async throws {
        let state = RemoteContentState()
        let (webView, waiter) = RemoteContentHarness.reportingWebView(to: state)
        try await RemoteContentHarness.load(shellAllowingRemoteContent: false, into: webView, waiter: waiter)

        #expect(!state.hasBlockedContent)
        try await RemoteContentHarness.render(
            #"<img src="https://example.invalid/badge.svg">"#,
            into: webView, settlingOn: state, until: true
        )
        #expect(state.hasBlockedContent)
        // Raising the offer must not be mistaken for taking it.
        #expect(!state.isAllowed)
    }

    private func violations(
        underShellAllowingRemoteContent allowingRemoteContent: Bool,
        rendering bodyHTML: String
    ) async throws -> [RemoteContentReport] {
        let (webView, collector) = try await RemoteContentHarness.collectingWebView(
            allowingRemoteContent: allowingRemoteContent
        )
        _ = try await webView.evaluateJavaScript(MarkdownPage.renderBodyScript(bodyHTML: bodyHTML))
        try await RemoteContentHarness.waitForReport { !collector.violations.isEmpty }
        return collector.violations
    }
}
