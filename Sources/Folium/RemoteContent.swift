import Foundation

/// Reads the Content-Security-Policy refusals `Resources/remote-content.js`
/// reports, and decides which of them the per-document opt-in could load
/// (issue #19).
///
/// The shell's CSP refuses every remote fetch, so a document that references
/// one gets a refusal report rather than a request. Only some of those
/// refusals describe something the opt-in shell would then load: it relaxes
/// `img-src` and `media-src` and nothing else, so a blocked remote
/// stylesheet must not raise an offer to load it. An offer that does nothing
/// when taken is worse than none.
///
/// Plain string handling with no WebKit dependency, so it is unit-testable
/// rather than growing inside `MarkdownWebView`'s excluded glue.
enum RemoteContent {
    /// The message name the shell posts on, and the name
    /// `MarkdownWebView` registers its handler under. One constant so the
    /// two sides cannot drift apart.
    static let messageName = "foliumRemoteContent"

    /// Directives the opt-in shell relaxes. Matched by prefix: WebKit
    /// reports the specific sub-directive that refused a load — an
    /// `<img>` comes back as `img-src-elem`, not `img-src` — and the
    /// sub-directives are exactly the cases their parent covers.
    private static let loadableDirectives = ["img-src", "media-src"]

    /// Schemes the opt-in shell admits. `http:` as well as `https:`:
    /// "Load" means this document's remote references may load, and a shell
    /// that quietly dropped the cleartext half would leave those images
    /// missing with the offer already dismissed — the silent omission this
    /// whole feature exists to prevent.
    private static let loadableSchemes: Set<String> = ["http", "https"]

    /// Whether a refusal describes content that clicking "Load" would
    /// actually load.
    ///
    /// - Parameters:
    ///   - directive: the CSP directive that refused the load.
    ///   - blockedURI: what it refused. WebKit sometimes reports only the
    ///     origin rather than the full URL, which is why nothing here reads
    ///     anything but the scheme.
    static func isLoadable(directive: String, blockedURI: String) -> Bool {
        guard loadableDirectives.contains(where: { directive.hasPrefix($0) }) else { return false }
        guard let scheme = URL(string: blockedURI)?.scheme?.lowercased() else { return false }
        return loadableSchemes.contains(scheme)
    }
}
