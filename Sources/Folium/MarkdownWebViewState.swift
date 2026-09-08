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

    /// Whether an injection's paint should be confirmed at all: only under
    /// FOLIUM_BENCH.
    ///
    /// Confirming a paint chains a second, awaited `WKWebView` call after
    /// the injection; returning `false` is what keeps that round trip off a
    /// real user's launch and live-reload.
    ///
    /// Deliberately not "which moment is this?". An earlier version named
    /// the paint — `first-paint` once per view, `reload-paint` after — and
    /// it was wrong: SwiftUI settles a document through several web views,
    /// each with its own state, so a live-reload whose injection landed in a
    /// freshly created view called itself `first-paint` and the reload
    /// measurement silently found nothing. Observed in 2 of 3 runs. Every
    /// paint now reports itself the same way, and `scripts/bench.sh` — which
    /// holds the wall-clock reading for each thing it asked for — decides
    /// which request a paint answers.
    func shouldConfirmPaint() -> Bool {
        benchMarker.isEnabled
    }

    /// Whether this view should run `MarkdownPage.scrollProbeScript` now
    /// that it has painted: only when this run armed the scroll probe, and
    /// only for the first view to ask.
    ///
    /// Once per process rather than per view because SwiftUI settles one
    /// document through several web views, each with its own state, and a
    /// probe per view would scroll the document several times over and
    /// report each run's numbers again.
    static func shouldRunScrollProbe(probe: BenchProbe = BenchProbe.current()) -> Bool {
        guard probe == .scroll else { return false }
        return scrollProbeClaim.claim()
    }

    private static let scrollProbeClaim = OneShot()
}
