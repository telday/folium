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
    /// What the loaded shell's DOM is currently showing, so an update that
    /// carries the same body doesn't rebuild it. See `render(bodyHTML:)`.
    private var renderedBodyHTML: String?
    /// Which shell the view has been told to load, or `nil` before it has
    /// loaded any. See `willLoadShell(allowingRemoteContent:)`.
    private var loadedShellAllowsRemoteContent: Bool?
    var benchMarker: BenchMarker = BenchMarker()

    /// Call when the shell's one-time `WKNavigationDelegate` `didFinish`
    /// fires. Returns body content to render immediately if one arrived
    /// (via `render(bodyHTML:)`) before the shell finished loading.
    func shellDidFinishLoading() -> String? {
        isShellLoaded = true
        defer { pendingBodyHTML = nil }
        guard let pending = pendingBodyHTML else { return nil }
        renderedBodyHTML = pending
        return pending
    }

    /// Call whenever new body content should render. Returns the HTML to
    /// inject immediately if the shell has already loaded, or `nil` if it's
    /// been queued to render once `shellDidFinishLoading()` is called
    /// instead — only the most recent call's content is kept.
    ///
    /// Also `nil` when the shell is already showing this exact body. SwiftUI
    /// calls `updateNSView` for any change to anything the view reads, not
    /// only for a change to the document, and rebuilding the DOM re-runs
    /// highlight.js over every code block in it. `CONTEXT.md` budgets a tab
    /// switch at "≤ 50 ms, no re-render", and this is what makes that true.
    ///
    /// It is also what keeps the view from driving itself in a circle. The
    /// page reports back to `RemoteContentState` on every render (issue
    /// #19), that report is state the view observes, and observing it
    /// schedules another `updateNSView` — so a body that re-injected
    /// unconditionally would ask to be re-injected again, about ten thousand
    /// times a second. Measured, before this guard existed.
    func render(bodyHTML: String) -> String? {
        guard isShellLoaded else {
            pendingBodyHTML = bodyHTML
            return nil
        }
        guard bodyHTML != renderedBodyHTML else { return nil }
        renderedBodyHTML = bodyHTML
        return bodyHTML
    }

    /// Whether the web view has to load a shell to be showing remote content
    /// (or not showing it) as `allowingRemoteContent` says (issue #19).
    ///
    /// True the first time it is asked, and again whenever the answer
    /// changes — which happens at most once per document, when the user
    /// clicks "Load". Opting in cannot be done by editing the page already
    /// on screen: its Content-Security-Policy came from a `<meta>` tag, and
    /// that policy is fixed from the moment the parser read it.
    ///
    /// Calling this marks the shell as no longer loaded, so the body handed
    /// to `render(bodyHTML:)` next is queued for the new shell's `didFinish`
    /// rather than injected into the page on its way out.
    func willLoadShell(allowingRemoteContent: Bool) -> Bool {
        guard loadedShellAllowsRemoteContent != allowingRemoteContent else { return false }
        loadedShellAllowsRemoteContent = allowingRemoteContent
        isShellLoaded = false
        // The shell coming in has an empty document in it, so whatever the
        // one going out was showing has to be injected again.
        renderedBodyHTML = nil
        return true
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
