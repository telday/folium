import AppKit
import Testing
import WebKit
@testable import Folium

/// Half of issue #20's seam: raw HTML in a document reaches the page
/// (`CMARK_OPT_UNSAFE`) and **does nothing**. A `<script>`, an `onerror=`
/// attribute, a `javascript:` destination, a `<meta http-equiv="refresh">`
/// and a remote `<iframe>` are all inert — not because anything filtered the
/// markup, but because the layers below the renderer refuse the behaviour
/// regardless of who wrote it. See
/// [ADR 0009](../../docs/adr/0009-raw-html-sanitized-below-the-renderer.md).
///
/// `RawHTMLRenderingTests` is the other half: that the same change makes
/// documents render what they say. `RawHTMLHarness` holds the setup both
/// use.
///
/// Every test here was run with its guard removed. Reverting
/// `CMARK_OPT_UNSAFE` leaves most of them green — with nothing rendered
/// there is nothing to defend against — so the guard each one is really
/// about is named in its own comment, and each was confirmed red without it.
@MainActor
@Suite(.serialized)
struct RawHTMLSafetyTests {
    init() {
        AppKitHost.startIfNeeded()
    }

    /// The headline worry about `CMARK_OPT_UNSAFE`, and the first thing
    /// issue #20's Definition of Done asks for.
    ///
    /// Two independent things stop it, and neither is the renderer: the
    /// shell's `script-src file:` admits no inline script, and
    /// `FoliumRenderBody` swaps content in through `innerHTML`, which HTML
    /// defines as never executing a `<script>` it parses. The CSP half is
    /// the one with teeth — `scriptCreatedInThePageIsRefusedByTheCSP` below
    /// takes `innerHTML` out of the picture and shows the payload is live
    /// and CSP alone still refuses it.
    @Test func scriptTagInADocumentDoesNotExecute() async throws {
        let webView = try await RawHTMLHarness.shell()

        try await RawHTMLHarness.render("<script>window.PWNED = true;</script>", in: webView)

        #expect(try await RawHTMLHarness.didExecute(in: webView) == false)
    }

    /// The teeth for the test above: the same payload, inserted the one way
    /// `innerHTML` cannot be credited for, so what is left refusing it is
    /// the Content-Security-Policy. Delete the CSP `<meta>` from the shell
    /// and this goes red — confirmed, and that is what it is here to prove.
    @Test func scriptCreatedInThePageIsRefusedByTheCSP() async throws {
        let webView = try await RawHTMLHarness.shell()

        let directive = try await RawHTMLHarness.violatedDirective(
            whileEvaluating: """
            var script = document.createElement('script');
            script.textContent = 'window.PWNED = true;';
            document.body.appendChild(script)
            """,
            in: webView
        )

        #expect(directive?.hasPrefix("script-src") == true)
        #expect(try await RawHTMLHarness.didExecute(in: webView) == false)
    }

    /// The vector `innerHTML` does *not* neutralise: an event-handler
    /// attribute on an element that fails to load runs as soon as the
    /// element is parsed into the document, script tag or no. CSP's
    /// `script-src` is the only thing between this document and arbitrary
    /// code — confirmed red with the CSP `<meta>` removed — which is why it
    /// is asserted through the real render path rather than against a
    /// hand-built element the way `ContentSecurityPolicyTests` does.
    @Test func eventHandlerAttributeInADocumentDoesNotFire() async throws {
        let webView = try await RawHTMLHarness.shell()

        try await RawHTMLHarness.render(
            #"<img src="does-not-exist.png" onerror="window.PWNED = true">"#,
            in: webView
        )

        // Nothing to wait *for*, so the assertion is that it stayed false
        // for longer than the load failure it hangs off takes to happen.
        let fired = await RawHTMLHarness.waitUntil(within: .milliseconds(500)) {
            try await RawHTMLHarness.didExecute(in: webView)
        }
        #expect(fired == false)
    }

    /// `CMARK_OPT_UNSAFE` re-permits `javascript:` in **plain Markdown link
    /// syntax**, not only inside raw HTML — safe mode used to blank that
    /// destination out, and this is the half of the change that has nothing
    /// to do with HTML at all. Issue #20's Definition of Done asks for it
    /// specifically.
    ///
    /// Clicked for real, through a real `Coordinator` in a real key window,
    /// because what refuses it only engages on an actual click. That is the
    /// CSP's `script-src`, and only it: removing the CSP `<meta>` turns this
    /// red, which means `NavigationPolicy`'s `javascript:` case never runs
    /// here at all — measured, WebKit evaluates a clicked `javascript:` URL
    /// without consulting `decidePolicyFor`. The policy that reads like the
    /// guard is not the guard. Worth knowing before anyone economises on
    /// the CSP.
    @Test func javascriptURLInPlainMarkdownLinkSyntaxDoesNotExecuteWhenClicked() async throws {
        let recorder = RawHTMLHarness.OpenedURLRecorder()
        let (webView, waiter) = try await RawHTMLHarness.shellWithCoordinator { recorder.record($0) }
        defer { webView.window?.close() }
        _ = waiter // kept alive: `navigationDelegate` is a weak reference

        try await RawHTMLHarness.render("[click me](javascript:window.PWNED=true)", in: webView)
        _ = try await webView.evaluateJavaScript("document.querySelector('#markdown-content a').click();")

        let executed = await RawHTMLHarness.waitUntil(within: .milliseconds(500)) {
            try await RawHTMLHarness.didExecute(in: webView)
        }
        #expect(executed == false)
        #expect(recorder.openedURLs.isEmpty)
        #expect(webView.url?.path == MarkdownPage.pageURL.path)
    }

    /// The vector `NavigationPolicy.decide`'s click requirement exists for,
    /// exercised end to end: before that gate, this test opened the user's
    /// default browser. Restoring the ungated `.openInBrowser` turns it red.
    ///
    /// `example.invalid` is IANA-reserved and never resolves, so even a
    /// regression cannot reach anything; what it would do is show up in the
    /// recorder.
    @Test func metaRefreshInADocumentDoesNotOpenTheBrowser() async throws {
        let recorder = RawHTMLHarness.OpenedURLRecorder()
        let (webView, waiter) = try await RawHTMLHarness.shellWithCoordinator { recorder.record($0) }
        defer { webView.window?.close() }
        _ = waiter // kept alive: `navigationDelegate` is a weak reference

        try await RawHTMLHarness.render(
            #"<meta http-equiv="refresh" content="0;url=https://example.invalid/leak">"#,
            in: webView
        )

        let opened = await RawHTMLHarness.waitUntil(within: .seconds(1)) { !recorder.openedURLs.isEmpty }
        #expect(opened == false)
        #expect(webView.url?.path == MarkdownPage.pageURL.path)
    }

    /// The behaviour on the other side of that narrowing: a *click* still
    /// opens the browser, which is what `CONTEXT.md`'s no-network floor
    /// names explicitly ("External links open in the user's default
    /// browser"). Driven from a document rather than from a hand-built
    /// anchor, so the gate can't be tightened into uselessness without this
    /// noticing.
    @Test func clickingAnExternalLinkStillOpensTheBrowser() async throws {
        let recorder = RawHTMLHarness.OpenedURLRecorder()
        let (webView, waiter) = try await RawHTMLHarness.shellWithCoordinator { recorder.record($0) }
        defer { webView.window?.close() }
        _ = waiter // kept alive: `navigationDelegate` is a weak reference

        try await RawHTMLHarness.render("[the docs](https://example.com/docs)", in: webView)
        _ = try await webView.evaluateJavaScript("document.querySelector('#markdown-content a').click();")

        #expect(await RawHTMLHarness.waitUntil { recorder.openedURLs.count == 1 })
        #expect(recorder.openedURLs == [URL(string: "https://example.com/docs")!])
    }

    /// An `<iframe>` is a whole document a file could pull in, and it is
    /// only expressible in raw HTML — nothing in Markdown syntax produces
    /// one. `default-src 'none'` covers it through `frame-src`, and the
    /// violation event is what proves the policy refused it rather than the
    /// unresolvable host doing the work for us.
    @Test func remoteIframeInADocumentIsRefused() async throws {
        let webView = try await RawHTMLHarness.shell()

        let directive = try await RawHTMLHarness.violatedDirective(
            whileEvaluating: RawHTMLHarness.renderScript(
                for: #"<iframe src="https://example.invalid/leak"></iframe>"#
            ),
            in: webView
        )

        #expect(directive?.hasPrefix("frame-src") == true)
    }
}
