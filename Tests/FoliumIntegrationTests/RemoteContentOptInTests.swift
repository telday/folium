import Testing
import WebKit
@testable import Folium

/// Issue #19's second half: what taking the offer does, who it applies to,
/// and what a live reload does to it.
///
/// These play the sequence `MarkdownWebView.updateNSView` plays when the
/// bar's button is pressed — `allow()`, ask `MarkdownWebViewState` which
/// shell to load, load it, let the queued body arrive on `didFinish` —
/// against the real state objects, the real reporter, and the real shells.
/// Only SwiftUI's call into `updateNSView` is stood in for; everything it
/// would do is production code.
@MainActor
@Suite(.serialized)
struct RemoteContentOptInTests {
    init() {
        AppKitHost.startIfNeeded()
    }

    private let body = #"<img id="badge" src="https://example.invalid/badge.svg">"#

    /// The Definition of Done's second half: that *opting in* permits the
    /// load, not merely that the opt-in shell would.
    @Test func takingTheOfferLoadsTheDocumentsRemoteContent() async throws {
        let document = try await OpenDocument()
        try await document.render(body, untilBlocked: true)
        #expect(document.state.hasBlockedContent, "the offer was never raised, so there was nothing to take")

        try await document.takeTheOffer(redrawing: body)

        // The reload landed on the opt-in shell, and the queued body came
        // back with it rather than being lost in the swap.
        #expect(document.webView.url?.lastPathComponent == "page-remote.html")
        let restored = try await document.webView.evaluateJavaScript("!!document.getElementById('badge')")
        #expect(restored as? Bool == true, "the document did not survive the shell swap")
        #expect(!document.state.hasBlockedContent, "the offer is still up after it was taken")
    }

    /// User story 3: "I want that choice to apply to this document only, so
    /// that trusting one file doesn't weaken the guarantee everywhere."
    @Test func optingOneDocumentInLeavesEveryOtherDocumentBlocked() async throws {
        let trusted = try await OpenDocument()
        // A second document, already open when the first one is trusted.
        let alreadyOpen = try await OpenDocument()

        try await trusted.render(body, untilBlocked: true)
        try await trusted.takeTheOffer(redrawing: body)
        #expect(trusted.webView.url?.lastPathComponent == "page-remote.html")

        // A third, opened *after* the first was trusted. This is the leak
        // that matters most: a per-window choice smuggled through a shared
        // default would be read when the next window is built, so a document
        // already open when the choice was made could stay correct while
        // every later one silently inherits it.
        let openedLater = try await OpenDocument()

        for (document, name) in [
            (alreadyOpen, "the document already open"),
            (openedLater, "the document opened afterwards")
        ] {
            #expect(!document.state.isAllowed, "\(name) inherited the opt-in")
            #expect(document.webView.url?.lastPathComponent == "page.html", "\(name) is on the opt-in shell")
            try await document.render(body, untilBlocked: true)
            #expect(document.state.hasBlockedContent, "\(name) stopped offering to load its own remote content")
        }
    }

    /// A live reload that removes the last remote image has to take the offer
    /// with it. Otherwise the bar goes on claiming something the file no
    /// longer says — the same class of untruth as a missing image.
    @Test func aLiveReloadThatRemovesTheLastRemoteImageWithdrawsTheOffer() async throws {
        let document = try await OpenDocument()

        try await document.render(body, untilBlocked: true)
        #expect(document.state.hasBlockedContent)

        try await document.render("<p>The badges are gone.</p>", untilBlocked: false)
        #expect(!document.state.hasBlockedContent)
    }

    /// And the other direction: a reload that introduces a remote image has
    /// to raise the offer, even though the render preceding it clears
    /// whatever the last one found.
    @Test func aLiveReloadThatAddsARemoteImageRaisesTheOffer() async throws {
        let document = try await OpenDocument()

        try await document.render("<p>Nothing remote here yet.</p>", untilBlocked: false)
        #expect(!document.state.hasBlockedContent)

        try await document.render(body, untilBlocked: true)
        #expect(document.state.hasBlockedContent)
    }

    /// Trusting a document survives its live reload: it is still the same
    /// file, and re-asking on every save would make the app unusable beside
    /// the editor `CONTEXT.md` names as the workflow.
    @Test func aLiveReloadAfterOptingInDoesNotAskAgain() async throws {
        let document = try await OpenDocument()
        try await document.render(body, untilBlocked: true)
        try await document.takeTheOffer(redrawing: body)

        try await document.render(#"<img src="https://example.invalid/other.svg">"#, untilBlocked: false)
        #expect(document.state.isAllowed)
        #expect(!document.state.hasBlockedContent, "the reload asked the user again")
        #expect(document.webView.url?.lastPathComponent == "page-remote.html")
    }

    /// One document window's worth of the app: its own `RemoteContentState`,
    /// its own `MarkdownWebViewState`, and a web view carrying the real
    /// `RemoteContentReporter`.
    @MainActor
    private final class OpenDocument {
        let state = RemoteContentState()
        let viewState = MarkdownWebViewState()
        let webView: WKWebView
        private let waiter: ReloadableNavigationWaiter

        init() async throws {
            (webView, waiter) = RemoteContentHarness.reportingWebView(to: state)
            _ = viewState.needsShellReload(allowingRemoteContent: state.isAllowed)
            try await loadShell()
        }

        /// Renders through `MarkdownWebViewState`, so the dedupe and queueing
        /// the app relies on are in the path rather than bypassed.
        func render(_ bodyHTML: String, untilBlocked expected: Bool) async throws {
            guard let ready = viewState.render(bodyHTML: bodyHTML) else { return }
            try await RemoteContentHarness.render(
                ready, into: webView, settlingOn: state, until: expected
            )
        }

        /// What the bar's button does, and what `updateNSView` does next.
        func takeTheOffer(redrawing bodyHTML: String) async throws {
            state.allow()
            #expect(
                viewState.needsShellReload(allowingRemoteContent: state.isAllowed),
                "opting in did not ask for a reload"
            )
            _ = viewState.render(bodyHTML: bodyHTML)
            try await loadShell()
        }

        /// Loads whichever shell `state` calls for, and hands `didFinish` to
        /// `viewState` the way `Coordinator` does — which is what delivers a
        /// body queued across the swap.
        private func loadShell() async throws {
            try await RemoteContentHarness.load(
                shellAllowingRemoteContent: state.isAllowed, into: webView, waiter: waiter
            )
            if let queued = viewState.shellDidFinishLoading() {
                _ = try await webView.evaluateJavaScript(MarkdownPage.renderBodyScript(bodyHTML: queued))
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}
