/// Tracks the one-time load of `MarkdownWebView`'s static page shell so
/// content updates can become cheap JS-injected DOM patches instead of full
/// page reloads (a full reload would re-parse every stylesheet and
/// re-parse/recompile all of highlight.js on every single content change —
/// prohibitive once live source-preview editing, already planned per ADR
/// 0001, means that happens on every keystroke).
///
/// No WebKit dependency, so this lives in the unit-testable logic layer
/// rather than growing inside `MarkdownWebView`'s excluded glue — see
/// `docs/agents/definition-of-done.md` on keeping real logic out of files
/// exempt from the coverage requirement.
final class MarkdownWebViewState {
    private var isShellLoaded = false
    private var pendingBodyHTML: String?
    private var hasEmittedFirstPaint = false
    var benchMarker: BenchMarker = BenchMarker()

    /// Call when the shell's one-time `WKNavigationDelegate` `didFinish`
    /// fires. Returns body content to render immediately if one arrived
    /// (via `render(bodyHTML:)`) before the shell finished loading.
    func shellDidFinishLoading() -> String? {
        isShellLoaded = true
        defer { pendingBodyHTML = nil }
        return pendingBodyHTML
    }

    /// Call whenever new body content should render. Returns the HTML to
    /// inject immediately if the shell has already loaded, or `nil` if it's
    /// been queued to render once `shellDidFinishLoading()` is called
    /// instead — only the most recent call's content is kept.
    func render(bodyHTML: String) -> String? {
        guard isShellLoaded else {
            pendingBodyHTML = bodyHTML
            return nil
        }
        return bodyHTML
    }

    /// Which marker an injection's paint should be confirmed and reported
    /// under, or `nil` if it shouldn't be confirmed at all: `"first-paint"`
    /// the first time this is called, `"reload-paint"` every time after,
    /// `nil` whenever FOLIUM_BENCH is unset. `MarkdownWebView` calls this
    /// before deciding how to inject — the decision of *whether* and *what*
    /// to confirm lives here, where it can be unit-tested, while confirming
    /// a paint for real needs a live `WKWebView` and stays in that excluded
    /// glue file.
    ///
    /// Confirming a paint chains a second, awaited `WKWebView` call after
    /// the injection; returning `nil` is what keeps that round trip off a
    /// real user's launch and live-reload.
    func paintEventToConfirm() -> String? {
        guard benchMarker.isEnabled else { return nil }
        guard hasEmittedFirstPaint else {
            hasEmittedFirstPaint = true
            return "first-paint"
        }
        return "reload-paint"
    }
}
