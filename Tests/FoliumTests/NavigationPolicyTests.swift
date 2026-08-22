import Foundation
import Testing
@testable import Folium

struct NavigationPolicyTests {
    private let shellURL = URL(string: "file:///Applications/Folium.app/Contents/Resources/Resources/page.html")!

    // MARK: - Table-driven coverage of every rule in NavigationPolicy.decide

    private struct Case {
        let name: String
        let url: URL?
        let isLinkActivation: Bool
        let expected: NavigationDecision
    }

    private var cases: [Case] {
        [
            Case(name: "nil URL blocks", url: nil, isLinkActivation: true, expected: .block),
            Case(
                name: "http link opens in the browser",
                url: URL(string: "http://example.com"), isLinkActivation: true,
                expected: .openInBrowser(URL(string: "http://example.com")!)
            ),
            Case(
                name: "https link opens in the browser",
                url: URL(string: "https://example.com/a"), isLinkActivation: true,
                expected: .openInBrowser(URL(string: "https://example.com/a")!)
            ),
            Case(
                name: "https link opens in the browser even as the initial navigation",
                url: URL(string: "https://example.com"), isLinkActivation: false,
                expected: .openInBrowser(URL(string: "https://example.com")!)
            ),
            Case(
                name: "in-shell fragment scrolls instead of navigating",
                url: shellURL.appendingFragment("usage"), isLinkActivation: true,
                expected: .scrollToAnchor("usage")
            ),
            Case(
                name: "in-shell fragment scrolls even when it wasn't a click",
                url: shellURL.appendingFragment("usage"), isLinkActivation: false,
                expected: .scrollToAnchor("usage")
            ),
            Case(
                name: "the shell's own initial load is allowed",
                url: shellURL, isLinkActivation: false,
                expected: .allow
            ),
            Case(
                name: "a link back to the shell with no fragment is blocked, not reloaded",
                url: shellURL, isLinkActivation: true,
                expected: .block
            ),
            Case(
                name: "file: to a different file opens as a sibling document",
                url: URL(string: "file:///Users/me/notes.md"), isLinkActivation: true,
                expected: .openDocument(URL(string: "file:///Users/me/notes.md")!)
            ),
            Case(
                name: "file: to a different file opens even when it wasn't a click",
                url: URL(string: "file:///Users/me/notes.md"), isLinkActivation: false,
                expected: .openDocument(URL(string: "file:///Users/me/notes.md")!)
            ),
            Case(
                name: "javascript: is blocked",
                url: URL(string: "javascript:alert(1)"), isLinkActivation: true,
                expected: .block
            ),
            Case(
                name: "data: is blocked",
                url: URL(string: "data:text/html,hi"), isLinkActivation: true,
                expected: .block
            ),
            Case(
                name: "mailto: is blocked",
                url: URL(string: "mailto:a@example.com"), isLinkActivation: true,
                expected: .block
            ),
            Case(
                name: "a custom scheme is blocked",
                url: URL(string: "myapp://open"), isLinkActivation: true,
                expected: .block
            )
        ]
    }

    /// The shell URL a real `.app` produces is *base-relative*, not
    /// absolute: `Bundle.main.resourceURL` returns `Contents/Resources/`
    /// relative to the bundle, so `MarkdownPage.pageURL` carries a
    /// `baseURL` and a `relativeString` of `Contents/Resources/...`. WebKit
    /// hands `decidePolicyFor` the fully resolved absolute URL. `URL`
    /// equality compares the relative string and base — not the resolved
    /// absolute string — so the two forms of the same file compare unequal
    /// unless the comparison resolves them first.
    ///
    /// Every other case here builds `shellURL` from an absolute string, and
    /// `swift test` resolves `resourceBaseURL` to SPM's flat bundle, which
    /// is absolute too — so nothing else in this suite ever sees the shape
    /// the shipping app actually runs with. Blocking the shell's own load
    /// leaves every document window permanently blank.
    @Test func allowsTheShellsOwnLoadWhenTheShellURLIsBaseRelative() {
        let bundle = URL(string: "file:///Applications/Folium.app/")!
        let relativeShell = URL(string: "Contents/Resources/Resources/page.html", relativeTo: bundle)!
        // Precondition: this is the shape the app really has, not an absolute URL.
        #expect(relativeShell.baseURL != nil)
        #expect(relativeShell.absoluteString == shellURL.absoluteString)

        let decision = NavigationPolicy.decide(
            NavigationRequest(url: shellURL, isLinkActivation: false),
            shellURL: relativeShell
        )

        #expect(decision == .allow)
    }

    /// The same resolution has to apply to fragments, or every in-document
    /// anchor click in the shipping app falls through to `.block` instead of
    /// scrolling.
    @Test func scrollsToAnchorWhenTheShellURLIsBaseRelative() {
        let bundle = URL(string: "file:///Applications/Folium.app/")!
        let relativeShell = URL(string: "Contents/Resources/Resources/page.html", relativeTo: bundle)!

        let decision = NavigationPolicy.decide(
            NavigationRequest(url: shellURL.appendingFragment("usage"), isLinkActivation: true),
            shellURL: relativeShell
        )

        #expect(decision == .scrollToAnchor("usage"))
    }

    @Test func decidesEveryRuleCorrectly() {
        for testCase in cases {
            let decision = NavigationPolicy.decide(
                NavigationRequest(url: testCase.url, isLinkActivation: testCase.isLinkActivation),
                shellURL: shellURL
            )
            #expect(decision == testCase.expected, "\(testCase.name)")
        }
    }
}

private extension URL {
    func appendingFragment(_ fragment: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.fragment = fragment
        return components.url!
    }
}
