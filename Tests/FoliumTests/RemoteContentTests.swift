import Testing
@testable import Folium

/// Which Content-Security-Policy refusals the per-document opt-in is allowed
/// to offer to load (issue #19).
///
/// The rule these all turn on: an offer that would do nothing when taken is
/// worse than no offer. The opt-in shell relaxes `img-src` for `http:` and
/// `https:`, and nothing else, so those are the only refusals that may raise
/// the bar.
struct RemoteContentTests {
    @Test func offersToLoadABlockedRemoteImage() {
        #expect(violation("img-src", "https://img.shields.io/badge.svg").isLoadable)
    }

    /// WebKit names the specific sub-directive that refused the load, so an
    /// `<img>` is reported against `img-src-elem` rather than the `img-src`
    /// the policy was written with. Matching the parent by exact string
    /// would recognise nothing a real browser reports.
    @Test func offersToLoadARefusalReportedAgainstASubDirective() {
        #expect(violation("img-src-elem", "https://example.com/badge.svg").isLoadable)
    }

    /// Cleartext counts. "Load" means this document's remote references may
    /// load; a shell that went on refusing half of them would leave those
    /// images missing with the offer already dismissed.
    @Test func offersToLoadACleartextRemoteImage() {
        #expect(violation("img-src", "http://example.com/badge.svg").isLoadable)
    }

    /// The opt-in shell does not relax `style-src`, and never will: nothing
    /// a document references is cascaded as code. Offering to load a blocked
    /// stylesheet would be offering something the click cannot deliver.
    @Test func doesNotOfferToLoadABlockedStylesheet() {
        #expect(!violation("style-src-elem", "https://example.com/theme.css").isLoadable)
    }

    @Test func doesNotOfferToLoadABlockedScript() {
        #expect(!violation("script-src", "https://example.com/tracker.js").isLoadable)
    }

    /// Images only. Issue #19 asks for remote images and the bar says
    /// images, so offering media would be a promise `page-remote.html` does
    /// not keep — its `media-src` still admits no remote scheme.
    ///
    /// Raw HTML (issue #20) is what makes this reachable rather than
    /// theoretical: a document can now write `<video src="https://…">`,
    /// where before this test guarded a case nothing could produce.
    /// Widening the shell and this rule together is issue #49; until then
    /// the assertion below is the honest one.
    @Test func doesNotOfferToLoadBlockedRemoteMedia() {
        #expect(!violation("media-src", "https://example.com/clip.mp4").isLoadable)
    }

    /// A refusal against a local scheme is not remote content. `folium-doc:`
    /// is already permitted by both shells, so a refusal naming it means
    /// something else went wrong — and switching shells would not fix it.
    @Test func doesNotOfferToLoadANonRemoteScheme() {
        #expect(!violation("img-src", "folium-doc://doc/logo.png").isLoadable)
        #expect(!violation("img-src", "file:///tmp/logo.png").isLoadable)
        #expect(!violation("img-src", "data:image/png;base64,AAAA").isLoadable)
    }

    /// WebKit reports `blockedURI` as the bare word "inline" for a violation
    /// with no URL behind it, and as an empty string when it withholds the
    /// address. Neither parses to a scheme, and neither may raise an offer.
    @Test func doesNotOfferToLoadARefusalWithNoURLBehindIt() {
        #expect(!violation("img-src", "inline").isLoadable)
        #expect(!violation("img-src", "").isLoadable)
    }

    @Test func doesNotOfferToLoadARefusalWithNoDirective() {
        #expect(!violation("", "https://example.com/badge.svg").isLoadable)
    }

    // MARK: - Decoding what the page posted

    @Test func decodesARefusalReportedByThePage() {
        let decoded = RemoteContentViolation(message: [
            "kind": "violation",
            "directive": "img-src-elem",
            "blockedURI": "https://example.com/badge.svg"
        ])
        #expect(decoded == RemoteContentViolation(
            directive: "img-src-elem",
            blockedURI: "https://example.com/badge.svg"
        ))
    }

    /// The render notice travels down the same channel and is not a refusal.
    @Test func doesNotDecodeTheRenderNoticeAsARefusal() {
        #expect(RemoteContentViolation(message: ["kind": "willRender"]) == nil)
    }

    @Test func doesNotDecodeAMessageWithNoKind() {
        #expect(RemoteContentViolation(message: ["directive": "img-src"]) == nil)
    }

    /// The page's report is built from a browser event, and a field it omits
    /// must not crash the decode or be read as something else.
    @Test func decodesARefusalWithFieldsMissingOrOfTheWrongType() {
        let decoded = RemoteContentViolation(message: ["kind": "violation", "directive": 42])
        #expect(decoded == RemoteContentViolation(directive: "", blockedURI: ""))
        #expect(decoded?.isLoadable == false)
    }

    private func violation(_ directive: String, _ blockedURI: String) -> RemoteContentViolation {
        RemoteContentViolation(directive: directive, blockedURI: blockedURI)
    }
}
