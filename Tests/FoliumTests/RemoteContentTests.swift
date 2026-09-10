import Testing
@testable import Folium

/// Which Content-Security-Policy refusals the per-document opt-in is allowed
/// to offer to load (issue #19).
///
/// The rule these all turn on: an offer that would do nothing when taken is
/// worse than no offer. The opt-in shell relaxes `img-src` and `media-src`
/// for `http:` and `https:`, and nothing else, so those are the only
/// refusals that may raise the bar.
struct RemoteContentTests {
    @Test func offersToLoadABlockedRemoteImage() {
        #expect(RemoteContent.isLoadable(directive: "img-src", blockedURI: "https://img.shields.io/badge.svg"))
    }

    @Test func offersToLoadBlockedRemoteMedia() {
        #expect(RemoteContent.isLoadable(directive: "media-src", blockedURI: "https://example.com/clip.mp4"))
    }

    /// WebKit names the specific sub-directive that refused the load, so an
    /// `<img>` is reported against `img-src-elem` rather than the `img-src`
    /// the policy was written with. Matching the parent by exact string
    /// would recognise nothing a real browser reports.
    @Test func offersToLoadARefusalReportedAgainstASubDirective() {
        #expect(RemoteContent.isLoadable(directive: "img-src-elem", blockedURI: "https://example.com/badge.svg"))
    }

    /// Cleartext counts. "Load" means this document's remote references may
    /// load; a shell that quietly kept refusing half of them would leave
    /// those images missing with the offer already dismissed.
    @Test func offersToLoadACleartextRemoteImage() {
        #expect(RemoteContent.isLoadable(directive: "img-src", blockedURI: "http://example.com/badge.svg"))
    }

    /// The opt-in shell does not relax `style-src`, and never will: nothing
    /// a document references is cascaded as code. Offering to load a blocked
    /// stylesheet would be offering something the click cannot deliver.
    @Test func doesNotOfferToLoadABlockedStylesheet() {
        #expect(!RemoteContent.isLoadable(directive: "style-src-elem", blockedURI: "https://example.com/theme.css"))
    }

    @Test func doesNotOfferToLoadABlockedScript() {
        #expect(!RemoteContent.isLoadable(directive: "script-src", blockedURI: "https://example.com/tracker.js"))
    }

    /// A refusal against a local scheme is not remote content. `folium-doc:`
    /// is already permitted by both shells, so a refusal naming it means
    /// something else went wrong — and switching shells would not fix it.
    @Test func doesNotOfferToLoadANonRemoteScheme() {
        #expect(!RemoteContent.isLoadable(directive: "img-src", blockedURI: "folium-doc://doc/logo.png"))
        #expect(!RemoteContent.isLoadable(directive: "img-src", blockedURI: "file:///tmp/logo.png"))
        #expect(!RemoteContent.isLoadable(directive: "img-src", blockedURI: "data:image/png;base64,AAAA"))
    }

    /// WebKit reports `blockedURI` as the bare word "inline" for a violation
    /// with no URL behind it, and as an empty string when it withholds the
    /// address. Neither parses to a scheme, and neither may raise an offer.
    @Test func doesNotOfferToLoadARefusalWithNoURLBehindIt() {
        #expect(!RemoteContent.isLoadable(directive: "img-src", blockedURI: "inline"))
        #expect(!RemoteContent.isLoadable(directive: "img-src", blockedURI: ""))
    }

    @Test func doesNotOfferToLoadARefusalWithNoDirective() {
        #expect(!RemoteContent.isLoadable(directive: "", blockedURI: "https://example.com/badge.svg"))
    }
}
