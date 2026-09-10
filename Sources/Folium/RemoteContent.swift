import Foundation

/// A Content-Security-Policy refusal, as `Resources/remote-content.js`
/// reports it back from the page (issue #19).
///
/// The pair travels from the page, through `RemoteContentReporter`, into
/// `RemoteContentState`, and the decoding from a posted message happens once
/// here rather than at each end. Plain string handling with no WebKit
/// dependency, so it is unit-testable rather than growing inside
/// `MarkdownWebView`'s excluded glue.
struct RemoteContentViolation: Equatable {
    /// The CSP directive that refused the load.
    let directive: String
    /// What it refused. WebKit sometimes reports only the origin rather than
    /// the full URL, which is why nothing here reads anything but the scheme.
    let blockedURI: String

    /// Decodes one `postMessage` body. Everything in it comes from the
    /// rendered document by way of a CSP report, so nothing is trusted to be
    /// present or to be a string.
    init?(message body: [String: Any]) {
        guard body["kind"] as? String == RemoteContent.violationKind else { return nil }
        directive = body["directive"] as? String ?? ""
        blockedURI = body["blockedURI"] as? String ?? ""
    }

    init(directive: String, blockedURI: String) {
        self.directive = directive
        self.blockedURI = blockedURI
    }

    /// Whether clicking "Load" would actually load this.
    ///
    /// The opt-in shell relaxes `img-src`, and nothing else, so a blocked
    /// remote stylesheet must not raise an offer to load it: an offer that
    /// does nothing when taken is worse than none.
    var isLoadable: Bool {
        guard directive.hasPrefix(RemoteContent.loadableDirective) else { return false }
        guard let scheme = URL(string: blockedURI)?.scheme?.lowercased() else { return false }
        return RemoteContent.loadableSchemes.contains(scheme)
    }
}

/// The names and values the page and the app both have to agree on for the
/// remote-content opt-in (issue #19).
enum RemoteContent {
    /// The message name the shell posts on, and the name `MarkdownWebView`
    /// registers its handler under.
    static let messageName = "foliumRemoteContent"

    /// The `kind` a refusal report carries.
    static let violationKind = "violation"

    /// The `kind` the page sends as it replaces the document's content.
    static let renderKind = "willRender"

    /// The directive the opt-in shell relaxes. Matched by prefix: WebKit
    /// reports the specific sub-directive that refused a load — an `<img>`
    /// comes back as `img-src-elem`, not `img-src` — and the sub-directives
    /// are exactly the cases their parent covers.
    ///
    /// Images only, deliberately. Issue #19 asks for remote *images*, and a
    /// document cannot reference remote media today in any case: cmark-gfm
    /// runs in safe mode, so raw HTML is stripped and `![](url)` is the only
    /// way a remote reference reaches the DOM. Widening this when raw HTML
    /// lands is a change to make then, together with the bar's wording.
    static let loadableDirective = "img-src"

    /// Schemes the opt-in shell admits. `http:` as well as `https:`: "Load"
    /// means this document's remote references may load, and a shell that
    /// quietly dropped the cleartext half would leave those images missing
    /// with the offer already dismissed.
    static let loadableSchemes: Set<String> = ["http", "https"]
}
