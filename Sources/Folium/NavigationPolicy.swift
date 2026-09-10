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
    /// A link to a sibling Markdown file (issue #18), carrying the real path
    /// `decide` recovered from the `folium-doc:` URL. The delegate cancels
    /// the navigation and hands this to `NSWorkspace`, the way
    /// `openInBrowser` hands an http(s) URL to the user's browser.
    case openDocument(URL)
    case block
}

/// Enforces `CONTEXT.md`'s no-network floor at the navigation layer: nothing
/// this app loads may leave the shell's own `file://` page. Kept as a pure
/// function rather than grown inside `MarkdownWebView.swift`'s excluded
/// glue — see `docs/agents/definition-of-done.md`.
enum NavigationPolicy {
    /// - Parameters:
    ///   - shellURLs: `MarkdownPage.shellURLs`, the addresses of both page
    ///     shells. A request whose URL matches one of them, fragment aside,
    ///     is the shell navigating to (or within) itself rather than
    ///     following a link. Both count, because opting a document into
    ///     remote content (issue #19) swaps one shell for the other, and an
    ///     in-page anchor link has to keep working either side of that.
    ///   - documentDirectory: the open document's own directory, needed to
    ///     resolve a `folium-doc:` link back to the real file it names. `nil`
    ///     for a document with nothing on disk, which has no such links to
    ///     resolve in the first place.
    static func decide(_ request: NavigationRequest, shellURLs: [URL], documentDirectory: URL?) -> NavigationDecision {
        guard let url = request.url else { return .block }

        if url.scheme == "http" || url.scheme == "https" {
            return .openInBrowser(url)
        }

        if shellURLs.contains(where: { url.strippingFragment() == $0.strippingFragment() }) {
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

        // An absolute file: URL the author wrote into the Markdown source.
        // `DocumentRelativeLinks` leaves any reference with a scheme alone,
        // so nothing rewrote this one and it carries no containment check.
        // Opening it would hand NSWorkspace an arbitrary path from untrusted
        // input: `<a href="file:///Users/me/Downloads/setup.command">` would
        // launch that file. Blocked. Relative references, which issue #18's
        // user stories are about, go through the folium-doc: case below.
        if url.scheme == "file" {
            return .block
        }

        // What `DocumentRelativeLinks` rewrote `[roadmap](./roadmap.md)` to
        // (issue #18). An <img> request is answered inside the web view, but
        // a clicked link has to leave it, so the real path has to be
        // recovered — through the same containment check the scheme handler
        // uses.
        //
        // Containment alone is not enough here. Reading a file under the
        // document's directory is one thing; *opening* one is launching it,
        // and a repo can hold `install.command` next to its README as
        // easily as another `.md`. Hence the extra type check.
        //
        // Anything that fails — no `documentDirectory`, a request the
        // resolver refuses, a resolved file of the wrong type — blocks.
        if url.scheme == DocumentResourceResolver.scheme {
            guard let documentDirectory,
                  let resolved = DocumentResourceResolver.fileURL(for: url, documentDirectory: documentDirectory),
                  isOpenableDocument(resolved)
            else {
                return .block
            }
            return .openDocument(resolved)
        }

        // Everything else — javascript:, data:, mailto:, custom schemes —
        // is blocked.
        return .block
    }

    /// The file-extension allowlist for what `.openDocument` will hand to
    /// `NSWorkspace`. Matches the `public.filename-extension`s
    /// `packaging/Info.plist` declares for `net.daringfireball.markdown`,
    /// the only document type this app opens. Issue #18 asks for links to
    /// sibling Markdown files to work, not for license to launch whatever
    /// else sits in the same directory.
    private static let openableDocumentExtensions: Set<String> = ["md", "markdown"]

    private static func isOpenableDocument(_ url: URL) -> Bool {
        openableDocumentExtensions.contains(url.pathExtension.lowercased())
    }
}

private extension URL {
    /// `URL.fragment` is the only piece two "same document, different
    /// anchor" URLs differ by, so comparing without it is how `decide` tells
    /// "the shell itself" apart from "a link somewhere else entirely".
    ///
    /// Resolved against its base first, because the two URLs being compared
    /// reach `decide` in different shapes. `MarkdownPage.shellURLs` is built
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
