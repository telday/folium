import Foundation

/// What `WKNavigationDelegate.decidePolicyFor` is being asked about, stripped
/// down to the two facts the decision actually depends on.
///
/// No WebKit import: `WKNavigationAction` itself carries a live reference to
/// the pending navigation, which only makes sense inside a real web view.
/// Reducing it to a `URL?` and a `Bool` here is what lets the decision live
/// in the unit-tested logic layer instead of `MarkdownWebView`'s excluded glue.
struct NavigationRequest: Equatable {
    let url: URL?
    /// `true` when `WKNavigationAction.navigationType == .linkActivated` —
    /// a user click, as opposed to the shell's own initial `loadFileURL`.
    let isLinkActivation: Bool
}

/// What Folium's navigation delegate should do about a `NavigationRequest`.
enum NavigationDecision: Equatable {
    /// Let the navigation proceed. Only the shell's own initial load
    /// qualifies — see `NavigationPolicy.decide`.
    case allow
    case openInBrowser(URL)
    case scrollToAnchor(String)
    /// A link to another file — a sibling Markdown file, most often, once
    /// `DocumentRelativeLinks` (issue #18) has rewritten it to a
    /// `folium-doc:` URL and `decide` has resolved that back to a real path.
    /// Handled by cancelling the navigation and handing the URL to
    /// `NSWorkspace`, the same way `openInBrowser` hands an http(s) URL to
    /// the user's browser.
    case openDocument(URL)
    case block
}

/// Enforces `CONTEXT.md`'s no-network floor at the navigation layer: nothing
/// this app loads may leave the shell's own `file://` page. Kept as a pure
/// function rather than grown inside `MarkdownWebView.swift`'s excluded
/// glue — see `docs/agents/definition-of-done.md`.
enum NavigationPolicy {
    /// - Parameters:
    ///   - shellURL: `MarkdownPage.pageURL`, the shell's own address. A
    ///     request whose URL matches this one, fragment aside, is the shell
    ///     navigating to (or within) itself rather than following a link.
    ///   - documentDirectory: the open document's own directory, needed to
    ///     resolve a `folium-doc:` link back to the real file it names. `nil`
    ///     for a document with nothing on disk, which has no such links to
    ///     resolve in the first place.
    static func decide(_ request: NavigationRequest, shellURL: URL, documentDirectory: URL?) -> NavigationDecision {
        guard let url = request.url else { return .block }

        if url.scheme == "http" || url.scheme == "https" {
            return .openInBrowser(url)
        }

        if url.strippingFragment() == shellURL.strippingFragment() {
            if let fragment = url.fragment, !fragment.isEmpty {
                return .scrollToAnchor(fragment)
            }
            // The shell's own load arrives with no fragment and isn't a link
            // click; a link back to the shell with no fragment has nothing
            // to do, so it falls through to .block below instead of
            // reloading the page out from under `MarkdownWebViewState`.
            if !request.isLinkActivation {
                return .allow
            }
            return .block
        }

        // An absolute file: URL an author wrote directly into the Markdown
        // source (`DocumentRelativeLinks` leaves any URL with an explicit
        // scheme untouched — see its doc comment). Handing it to
        // NSWorkspace, rather than trying to load it into this web view, is
        // what "sibling file" opening as a new native document window means.
        if url.scheme == "file" {
            return .openDocument(url)
        }

        // A folium-doc: URL is what `DocumentRelativeLinks` (issue #18) now
        // rewrites a document-relative link like `[roadmap](./roadmap.md)`
        // to. Unlike an <img>/<link> request, which the web content process
        // never sees the real path for, a clicked link has to leave the web
        // view entirely — so this maps it back through the same containment
        // check `DocumentResourceSchemeHandler` uses before handing anything
        // to NSWorkspace. No `documentDirectory` or a request the resolver
        // refuses both fall through to .block rather than opening nothing:
        // a link that resolves to nowhere is not a link this app should act on.
        if url.scheme == DocumentResourceResolver.scheme {
            guard let documentDirectory,
                  let resolved = DocumentResourceResolver.fileURL(for: url, documentDirectory: documentDirectory)
            else {
                return .block
            }
            return .openDocument(resolved)
        }

        // Everything else — javascript:, data:, mailto:, custom schemes —
        // is blocked.
        return .block
    }
}

private extension URL {
    /// `URL.fragment` is the only piece two "same document, different
    /// anchor" URLs differ by, so comparing without it is how `decide` tells
    /// "the shell itself" apart from "a link somewhere else entirely".
    ///
    /// Resolved against its base first, because the two URLs being compared
    /// reach `decide` in different shapes. `MarkdownPage.pageURL` is built
    /// on `Bundle.main.resourceURL`, which a real `.app` returns as
    /// *relative* to the bundle — a `baseURL` plus a `relativeString` of
    /// `Contents/Resources/...` — while WebKit hands `decidePolicyFor` the
    /// fully resolved absolute URL. `URL` equality compares the relative
    /// string and base rather than the resolved absolute string, so without
    /// this the shell's own load compares unequal to itself and gets
    /// blocked, leaving every document window blank.
    func strippingFragment() -> URL {
        var components = URLComponents(url: absoluteURL, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.url ?? absoluteURL
    }
}
