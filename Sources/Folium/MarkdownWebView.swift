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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ScrollKeyWebView {
        let webView = ScrollKeyWebView()
        webView.scrollKeys = scrollKeys
        webView.navigationDelegate = context.coordinator
        webView.loadFileURL(MarkdownPage.pageURL, allowingReadAccessTo: MarkdownPage.resourceBaseURL)
        return webView
    }

    func updateNSView(_ webView: ScrollKeyWebView, context: Context) {
        // Rebinding a key in Preferences has to reach the documents already
        // open, not just the next one.
        webView.scrollKeys = scrollKeys
        if let ready = context.coordinator.state.render(bodyHTML: bodyHTML) {
            context.coordinator.inject(ready, into: webView)
        }
    }

    /// Bridges the shell's one-time `didFinish` navigation callback to
    /// `MarkdownWebViewState`, and delivers whatever content was queued
    /// while it was still loading. Also enforces `CONTEXT.md`'s no-network
    /// floor at the navigation layer via `decidePolicyFor`.
    final class Coordinator: NSObject, WKNavigationDelegate {
        let state = MarkdownWebViewState()

        /// Opens an external link. Injected, defaulting to the real
        /// `NSWorkspace.shared.open(_:)`, so tests can record what would
        /// have opened instead of launching the user's browser on every run.
        let openExternal: (URL) -> Void

        init(openExternal: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
            self.openExternal = openExternal
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
            guard let event = state.paintEventToConfirm() else {
                webView.evaluateJavaScript(script)
                return
            }
            webView.evaluateJavaScript(script) { [state] _, _ in
                Task { @MainActor in
                    _ = try? await webView.callAsyncJavaScript(
                        MarkdownPage.paintConfirmationScript,
                        contentWorld: .page
                    )
                    state.benchMarker.mark(event)

                    // The scroll probe runs after the paint it follows, not
                    // instead of it: it scrolls the real document for ~180
                    // frames, so starting it any earlier would be measuring
                    // a document still being drawn.
                    guard state.shouldRunScrollProbe(after: event) else { return }
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
            switch NavigationPolicy.decide(request, shellURL: MarkdownPage.pageURL) {
            case .allow:
                decisionHandler(.allow)
            case .openInBrowser(let url):
                openExternal(url)
                decisionHandler(.cancel)
            case .scrollToAnchor(let fragment):
                webView.evaluateJavaScript(MarkdownPage.scrollToAnchorScript(fragment))
                decisionHandler(.cancel)
            case .block:
                decisionHandler(.cancel)
            }
        }
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
