import SwiftUI
import WebKit

/// Displays rendered Markdown HTML in a `WKWebView` (ADR 0001).
///
/// Loads `MarkdownPage`'s static shell exactly once via `loadFileURL` (the
/// only WKWebView API that grants a page read access to sibling local
/// files — `loadHTMLString(_:baseURL:)` does not, despite taking a
/// `baseURL`: WebKit gives every `file://` resource its own origin, and a
/// plain `baseURL` only resolves relative URLs, it doesn't grant access to
/// what they point at). Every subsequent `bodyHTML` change is pushed in via
/// `evaluateJavaScript` instead of a reload — see `MarkdownWebViewState` for
/// why reloading on every change would be prohibitively expensive.
struct MarkdownWebView: NSViewRepresentable {
    let bodyHTML: String
    let scrollKeys: ScrollKeyBindings
    /// The open document's own directory, or `nil` for one with nothing on
    /// disk (e.g. a brand-new untitled window). Carried by the `folium-doc:`
    /// scheme handler this view registers below, and by `Coordinator` for
    /// resolving a clicked sibling-document link — see issue #18.
    let documentDirectory: URL?
    /// This document's remote-content policy (issue #19). Read here to
    /// choose which shell to load; written by `RemoteContentReporter` below,
    /// which the shell posts Content-Security-Policy refusals to.
    @ObservedObject var remoteContent: RemoteContentState

    func makeCoordinator() -> Coordinator {
        Coordinator(documentDirectory: documentDirectory)
    }

    /// Assembles the configuration a document's web view is created with.
    ///
    /// Separate from `makeNSView` so a test can call it. `makeNSView` takes a
    /// SwiftUI `Context`, which no test can construct, and the
    /// `folium-doc:` handler registered here is the whole of issue #18's
    /// resource path — registered anywhere else, the integration suite would
    /// be proving its own wiring works rather than the app's.
    static func configuration(
        documentDirectory: URL?,
        remoteContent: RemoteContentState
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // The receiving end of `Resources/remote-content.js`. Registering it
        // is also what makes `window.webkit.messageHandlers
        // .foliumRemoteContent` exist at all — that object is absent unless
        // something claimed the name, which is why the script checks.
        configuration.userContentController.add(
            RemoteContentReporter(state: remoteContent),
            name: RemoteContent.messageName
        )
        guard let documentDirectory else {
            // A document with nothing on disk gets no handler: a folium-doc:
            // request has nowhere to resolve against, so it could only fail.
            return configuration
        }
        // Must be set before the web view exists —
        // `setURLSchemeHandler(_:forURLScheme:)` cannot be called on a
        // configuration a live WKWebView already holds.
        configuration.setURLSchemeHandler(
            DocumentResourceSchemeHandler(documentDirectory: documentDirectory),
            forURLScheme: DocumentResourceResolver.scheme
        )
        return configuration
    }

    func makeNSView(context: Context) -> ScrollKeyWebView {
        let configuration = Self.configuration(
            documentDirectory: documentDirectory,
            remoteContent: remoteContent
        )
        let webView = ScrollKeyWebView(configuration: configuration)
        webView.scrollKeys = scrollKeys
        webView.navigationDelegate = context.coordinator
        // The answer is discarded: the first shell is loaded either way.
        // The call is what records which one, so the next update can tell
        // whether it changed.
        _ = context.coordinator.state.needsShellReload(allowingRemoteContent: remoteContent.isAllowed)
        loadShell(into: webView)
        return webView
    }

    func updateNSView(_ webView: ScrollKeyWebView, context: Context) {
        // Rebinding a key in Preferences has to reach the documents already
        // open, not just the next one.
        webView.scrollKeys = scrollKeys
        // Clicking "Load" arrives here: the shell in the window enforces the
        // policy the user just changed, so it has to be replaced rather than
        // adjusted. The reload re-parses every stylesheet and all of
        // highlight.js — the cost `MarkdownWebViewState` exists to avoid on
        // every content change. Paid once per document at most, on an
        // explicit click, because opting in is one-way.
        if context.coordinator.state.needsShellReload(allowingRemoteContent: remoteContent.isAllowed) {
            loadShell(into: webView)
        }
        if let ready = context.coordinator.state.render(bodyHTML: bodyHTML) {
            context.coordinator.inject(ready, into: webView)
        }
    }

    private func loadShell(into webView: WKWebView) {
        webView.loadFileURL(
            MarkdownPage.shellURL(allowingRemoteContent: remoteContent.isAllowed),
            allowingReadAccessTo: MarkdownPage.resourceBaseURL
        )
    }

    /// Bridges the shell's one-time `didFinish` navigation callback to
    /// `MarkdownWebViewState`, and delivers whatever content was queued
    /// while it was still loading. Also enforces `CONTEXT.md`'s no-network
    /// floor at the navigation layer via `decidePolicyFor`.
    final class Coordinator: NSObject, WKNavigationDelegate {
        let state = MarkdownWebViewState()

        /// The open document's own directory — see `MarkdownWebView`'s
        /// property of the same name. Captured once, at `makeCoordinator()`
        /// time: SwiftUI doesn't call it again for the lifetime of the
        /// view's identity, and a document's own directory doesn't move
        /// out from under an already-open window.
        let documentDirectory: URL?

        /// Opens an external link. Injected, defaulting to the real
        /// `NSWorkspace.shared.open(_:)`, so tests can record what would
        /// have opened instead of launching the user's browser on every run.
        let openExternal: (URL) -> Void

        /// Opens a sibling document (issue #18) with the user's default
        /// application for its file type — `NSWorkspace.shared.open(_:)`
        /// again, but injected separately from `openExternal` so a test
        /// asserting on one path can't be satisfied by the other firing
        /// instead.
        let openDocument: (URL) -> Void

        init(
            documentDirectory: URL? = nil,
            openExternal: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
            openDocument: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
        ) {
            self.documentDirectory = documentDirectory
            self.openExternal = openExternal
            self.openDocument = openDocument
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let queued = state.shellDidFinishLoading() else { return }
            inject(queued, into: webView)
        }

        /// Injects rendered body HTML. Outside a bench run this is a single
        /// `evaluateJavaScript` call with no completion handler, same as
        /// before this file measured anything. Under FOLIUM_BENCH,
        /// `MarkdownWebViewState.paintEventToConfirm` names an event to
        /// confirm and mark, and confirming means chaining
        /// `MarkdownPage.paintConfirmationScript` through
        /// `callAsyncJavaScript` — `evaluateJavaScript` does not wait for a
        /// returned `Promise`, confirmed against a real `WKWebView`;
        /// `callAsyncJavaScript` runs the string as an `async` function body
        /// and does wait, on its `await`s.
        func inject(_ bodyHTML: String, into webView: WKWebView) {
            let script = MarkdownPage.renderBodyScript(bodyHTML: bodyHTML)
            guard state.shouldConfirmPaint() else {
                webView.evaluateJavaScript(script)
                return
            }
            webView.evaluateJavaScript(script) { [state] _, _ in
                Task { @MainActor in
                    _ = try? await webView.callAsyncJavaScript(
                        MarkdownPage.paintConfirmationScript,
                        contentWorld: .page
                    )
                    // The body's size identifies *what* was drawn. A live
                    // reload changes the document, so its repaint carries a
                    // different size than the paint before it; a view that
                    // is merely settling redraws the same body at the same
                    // size, and the script can tell them apart.
                    state.benchMarker.mark("paint", detail: String(bodyHTML.count))

                    // The scroll probe runs after the paint it follows, not
                    // instead of it: it scrolls the real document for ~180
                    // frames, so starting it any earlier would be measuring
                    // a document still being drawn.
                    guard MarkdownWebViewState.shouldRunScrollProbe() else { return }
                    let result = try? await webView.callAsyncJavaScript(
                        MarkdownPage.scrollProbeScript,
                        contentWorld: .page
                    )
                    guard let values = result as? [String: Any],
                          let line = BenchBudget.scrollReportLine(from: values) else { return }
                    state.benchMarker.writeLine("FOLIUM_BENCH_REPORT scrolling \(line)")
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let request = NavigationRequest(
                url: navigationAction.request.url,
                isLinkActivation: navigationAction.navigationType == .linkActivated
            )
            let decision = NavigationPolicy.decide(
                request,
                shellURLs: MarkdownPage.shellURLs,
                documentDirectory: documentDirectory
            )
            switch decision {
            case .allow:
                decisionHandler(.allow)
            case .openInBrowser(let url):
                openExternal(url)
                decisionHandler(.cancel)
            case .scrollToAnchor(let fragment):
                webView.evaluateJavaScript(MarkdownPage.scrollToAnchorScript(fragment))
                decisionHandler(.cancel)
            case .openDocument(let url):
                openDocument(url)
                decisionHandler(.cancel)
            case .block:
                decisionHandler(.cancel)
            }
        }
    }
}

/// Delivers the shell's Content-Security-Policy refusals to one document's
/// `RemoteContentState` (issue #19).
///
/// `WKUserContentController.add(_:name:)` holds its handler strongly, and the
/// controller belongs to the web view's configuration, so this must not hold
/// the web view back. It holds only the state object, which the document
/// window owns and the web view does not.
@MainActor
final class RemoteContentReporter: NSObject, WKScriptMessageHandler {
    private let state: RemoteContentState

    init(state: RemoteContentState) {
        self.state = state
    }

    /// `message.body` is whatever the page passed to `postMessage`, bridged
    /// to Foundation types — a JavaScript object arrives as a dictionary.
    /// `RemoteContentViolation` does the decoding, so this stays a routing
    /// step and the field names live in one place.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        if body["kind"] as? String == RemoteContent.renderKind {
            state.documentWillRender()
            return
        }
        guard let violation = RemoteContentViolation(message: body) else { return }
        state.note(violation)
    }
}

/// A `WKWebView` that scrolls itself when one of the configured scroll keys is
/// pressed (issue #6).
///
/// The capture is here, in the responder chain, rather than in a `keydown`
/// listener inside the page. A listener would only fire while the web content
/// held focus, and it would swallow the keystroke before AppKit could offer it
/// to menu key equivalents, the Services menu or VoiceOver — the sort of thing
/// `CONTEXT.md` priority 1 exists to prevent. A key that isn't bound goes to
/// `super`, so everything WebKit already does with the keyboard (arrows, Page
/// Up/Down, Home/End, ⌘F's find bar) is untouched.
///
/// The decision of *whether* a keystroke scrolls lives in `ScrollKeyBindings`;
/// what's left here is `NSEvent` translation and the `evaluateJavaScript` call.
final class ScrollKeyWebView: WKWebView {
    var scrollKeys: ScrollKeyBindings = .standard

    /// `WKWebView`'s only designated initializer takes a configuration —
    /// there is no plain `init()` to inherit — and `MarkdownWebView` has to
    /// build that configuration first to register a `folium-doc:` scheme
    /// handler on it (issue #18) before this view exists at all.
    convenience init(configuration: WKWebViewConfiguration) {
        self.init(frame: .zero, configuration: configuration)
    }

    override func keyDown(with event: NSEvent) {
        guard let direction = scrollKeys.direction(for: ScrollKeyPress(event)) else {
            super.keyDown(with: event)
            return
        }
        evaluateJavaScript(MarkdownPage.scrollScript(direction))
    }
}

extension ScrollKeyPress {
    /// `charactersIgnoringModifiers`, so an ⌥-modified key still reports the
    /// letter printed on it rather than the symbol it would type.
    init(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        self.init(
            characters: event.charactersIgnoringModifiers ?? "",
            carriesModifier: !modifiers.isEmpty
        )
    }
}
