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
        let documentDirectory: URL?
        let expected: NavigationDecision

        init(
            name: String,
            url: URL?,
            isLinkActivation: Bool,
            documentDirectory: URL? = nil,
            expected: NavigationDecision
        ) {
            self.name = name
            self.url = url
            self.isLinkActivation = isLinkActivation
            self.documentDirectory = documentDirectory
            self.expected = expected
        }
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
                // An absolute file: URL an author wrote directly into the
                // Markdown source is never rewritten by DocumentRelativeLinks
                // (it already has a scheme), so it reaches decide() exactly
                // as authored — with no containment check possible, since it
                // could name anything on the filesystem. Handing that to
                // NSWorkspace would launch whatever it points at from a
                // single click on untrusted content, so this is blocked, not
                // opened. See the comment on this case in NavigationPolicy.
                name: "an absolute file: link is blocked, not opened",
                url: URL(string: "file:///Users/me/notes.md"), isLinkActivation: true,
                expected: .block
            ),
            Case(
                name: "an absolute file: link is blocked even when it wasn't a click",
                url: URL(string: "file:///Users/me/notes.md"), isLinkActivation: false,
                expected: .block
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
                shellURL: shellURL,
                documentDirectory: testCase.documentDirectory
            )
            #expect(decision == testCase.expected, "\(testCase.name)")
        }
    }

    // MARK: - folium-doc: links (issue #18)
    //
    // These need a real file on disk — DocumentResourceResolver.fileURL,
    // which decide() calls to map a clicked link back to a real path,
    // refuses to resolve anything that doesn't exist as a regular file — so
    // they're kept out of the table above and given their own fixture.

    @Test func documentSchemeLinkToAFileInsideTheDirectoryOpensAsASiblingDocument() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = directory.appendingPathComponent("notes.md")
        try Data().write(to: notes)

        let decision = NavigationPolicy.decide(
            NavigationRequest(url: URL(string: "folium-doc://doc/notes.md"), isLinkActivation: true),
            shellURL: shellURL,
            documentDirectory: directory
        )

        #expect(decision == .openDocument(notes.standardizedFileURL.resolvingSymlinksInPath()))
    }

    @Test func documentSchemeLinkToAFileWithTheLongMarkdownExtensionOpens() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = directory.appendingPathComponent("notes.markdown")
        try Data().write(to: notes)

        let decision = NavigationPolicy.decide(
            NavigationRequest(url: URL(string: "folium-doc://doc/notes.markdown"), isLinkActivation: true),
            shellURL: shellURL,
            documentDirectory: directory
        )

        #expect(decision == .openDocument(notes.standardizedFileURL.resolvingSymlinksInPath()))
    }

    /// The containment check alone isn't enough: `install.command` sitting
    /// right next to a README is exactly as reachable, by the same
    /// containment rules, as `screenshot.png` is. `.openDocument` hands its
    /// URL to `NSWorkspace`, which launches it — so this is refused even
    /// though the file is real, regular, and fully inside the document's
    /// own directory.
    @Test func documentSchemeLinkToANonMarkdownFileIsBlockedEvenThoughItsContained() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("install.command")
        try Data().write(to: executable)

        let decision = NavigationPolicy.decide(
            NavigationRequest(url: URL(string: "folium-doc://doc/install.command"), isLinkActivation: true),
            shellURL: shellURL,
            documentDirectory: directory
        )

        #expect(decision == .block)
    }

    @Test func documentSchemeLinkThatEscapesTheDirectoryIsBlockedNotOpened() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let decision = NavigationPolicy.decide(
            NavigationRequest(url: URL(string: "folium-doc://doc/../../etc/passwd"), isLinkActivation: true),
            shellURL: shellURL,
            documentDirectory: directory
        )

        #expect(decision == .block)
    }

    @Test func documentSchemeLinkWithNoDocumentDirectoryIsBlocked() {
        // A document with nothing on disk (a brand-new untitled window) has
        // no directory of its own to resolve a folium-doc: link against.
        let decision = NavigationPolicy.decide(
            NavigationRequest(url: URL(string: "folium-doc://doc/notes.md"), isLinkActivation: true),
            shellURL: shellURL,
            documentDirectory: nil
        )

        #expect(decision == .block)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NavigationPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private extension URL {
    func appendingFragment(_ fragment: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.fragment = fragment
        return components.url!
    }
}
