import Foundation
import Testing
@testable import Folium

/// Unit coverage for issue #18's resolution table: which `src`/`href`
/// values get rewritten to a `folium-doc://doc/<relative path>` URL, and
/// which are left exactly as they were. `DocumentResourceResolverTests`
/// covers the separate question of which of those rewritten URLs are
/// actually servable.
struct DocumentRelativeLinksTests {
    // A directory with a space and a `#` in its name, so a naive
    // string-concatenation implementation would corrupt every case below —
    // `URL`'s own percent-encoding is what keeps them correct.
    private let directory = URL(fileURLWithPath: "/Users/me/My Docs #2", isDirectory: true)

    // MARK: - Relative forms that must resolve

    @Test func dotSlashRelativeImageResolvesUnderTheDirectory() {
        let html = #"<img src="./screenshot.png" alt="">"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<img src="folium-doc://doc/screenshot.png" alt="">"#)
    }

    @Test func bareRelativeImageResolvesUnderTheDirectory() {
        let html = #"<img src="screenshot.png" alt="">"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<img src="folium-doc://doc/screenshot.png" alt="">"#)
    }

    @Test func parentDirectoryReferenceWalksUpBeforeResolving() {
        // The rewriter's job is only to describe the reference, not to
        // decide whether it's servable — that containment decision belongs
        // to DocumentResourceResolver (DocumentResourceResolverTests), which
        // refuses anything above the document's own directory. This still
        // walks the `..` up correctly, so the URL means what it says.
        let html = #"<a href="../sibling/notes.md">notes</a>"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<a href="folium-doc://doc/../sibling/notes.md">notes</a>"#)
    }

    @Test func siblingMarkdownLinkResolves() {
        let html = #"<a href="sibling.md">sibling</a>"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<a href="folium-doc://doc/sibling.md">sibling</a>"#)
    }

    @Test func siblingMarkdownLinkWithAnchorKeepsTheFragment() {
        let html = ##"<a href="sibling.md#section">sibling</a>"##
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == ##"<a href="folium-doc://doc/sibling.md#section">sibling</a>"##)
    }

    // MARK: - Percent-encoding: spaces, `#`/`?`, and non-ASCII in filenames

    @Test func alreadyPercentEncodedSpaceIsNotDoubleEncoded() {
        // cmark-gfm itself percent-encodes a space in a `<...>`-bracketed
        // destination before this function ever sees it — see the doc
        // comment on `resolve`. Re-encoding the already-encoded `%20`
        // would turn it into `%2520`, a broken filename.
        let html = #"<img src="./my%20file.png" alt="">"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<img src="folium-doc://doc/my%20file.png" alt="">"#)
    }

    @Test func alreadyPercentEncodedNonASCIIIsNotDoubleEncoded() {
        let html = #"<img src="./caf%C3%A9.png" alt="">"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<img src="folium-doc://doc/caf%C3%A9.png" alt="">"#)
    }

    @Test func literalHashInAFilenameSplitsAsAFragmentLikeAnyURLWould() {
        // cmark-gfm does not percent-encode `#`/`?` in a destination — see
        // the spike in the PR description. `resolve` treats the value as an
        // ordinary URL reference, exactly like a browser resolving the same
        // string would, rather than guessing that the author meant a
        // literal `#` in a filename.
        let html = ##"<img src="./a#b.png" alt="">"##
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == ##"<img src="folium-doc://doc/a#b.png" alt="">"##)
    }

    @Test func literalQuestionMarkInAFilenameIsKeptAsAQueryByTheSameLogic() {
        let html = #"<img src="./a?b=1.png" alt="">"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<img src="folium-doc://doc/a?b=1.png" alt="">"#)
    }

    // MARK: - Forms that must be left exactly alone

    @Test func httpURLIsLeftAlone() {
        let html = #"<img src="http://example.com/x.png" alt="">"#
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    @Test func httpsURLIsLeftAlone() {
        let html = #"<a href="https://example.com/page">link</a>"#
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    @Test func dataURLIsLeftAlone() {
        let html = #"<img src="data:image/png;base64,AAAA" alt="">"#
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    @Test func mailtoURLIsLeftAlone() {
        let html = #"<a href="mailto:a@example.com">mail</a>"#
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    @Test func aSchemeContainingAHyphenIsStillRecognizedAsAbsolute() {
        // RFC 3986 allows `+`, `-`, and `.` after a scheme's first letter —
        // rarer than `http`/`file`, but real (`ms-settings:`, `web+app:`).
        // `hasScheme` only proves it recognizes one of these correctly if a
        // test actually uses a character besides a plain letter here.
        let html = #"<a href="web+custom-scheme:payload">link</a>"#
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    @Test func aReferenceToTheDocumentsOwnDirectoryIsLeftAlone() {
        // `.` resolves to `directory` itself — nothing relative to walk down
        // to, and no file for a `folium-doc:` request to name. Left
        // untouched rather than turned into a URL naming a directory, the
        // same conservative default as every other form `resolve` can't
        // confidently turn into a file reference.
        let html = #"<a href=".">here</a>"#
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    @Test func absoluteFileURLIsLeftAlone() {
        let html = #"<a href="file:///Users/other/notes.md">notes</a>"#
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    @Test func protocolRelativeURLIsLeftAlone() {
        // Resolving this against a file:// base does not fail — it
        // silently produces `file://example.com/x.png`, a `file:` URL with
        // a foreign host. That would be worse than doing nothing: it hands
        // NavigationPolicy's file:-URL handling something that only looks
        // local. Left untouched instead.
        let html = #"<img src="//example.com/x.png" alt="">"#
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    @Test func absolutePathReferenceIsLeftAlone() {
        // Not "relative to the document" in the sense this function
        // resolves — resolving it would let a document point anywhere on
        // the filesystem rather than somewhere under its own directory.
        let html = #"<img src="/etc/passwd" alt="">"#
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    @Test func pureFragmentIsLeftAlone() {
        let html = ##"<a href="#usage">usage</a>"##
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    @Test func emptyValueIsLeftAlone() {
        let html = #"<a href="">empty</a>"#
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    // MARK: - Only src/href are touched, and unrelated markup is untouched

    @Test func attributesOtherThanSrcAndHrefAreUntouched() {
        let html = #"<img src="screenshot.png" alt="a relative path in prose: ./not-an-attribute.png">"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        let expected = #"<img src="folium-doc://doc/screenshot.png" "#
            + #"alt="a relative path in prose: ./not-an-attribute.png">"#
        #expect(resolved == expected)
    }

    @Test func multipleReferencesInOneDocumentAllResolve() {
        let html = """
        <p><img src="a.png" alt=""></p>
        <p><a href="b.md">b</a></p>
        <p><img src="https://example.com/c.png" alt=""></p>
        """
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved.contains(#"src="folium-doc://doc/a.png""#))
        #expect(resolved.contains(#"href="folium-doc://doc/b.md""#))
        #expect(resolved.contains(#"src="https://example.com/c.png""#))
    }

    @Test func htmlWithNoSrcOrHrefIsUnchanged() {
        let html = "<p>Just text, no links or images.</p>"
        #expect(DocumentRelativeLinks.resolve(html, relativeTo: directory) == html)
    }

    // MARK: - LiveDocument's nil-directory path (a document with nothing on disk)

    @Test @MainActor func aDocumentWithNoFileOnDiskGetsNoRewriting() {
        let document = LiveDocument(text: "![alt](./screenshot.png)", fileURL: nil)
        #expect(document.bodyHTML.contains(#"src="./screenshot.png""#))
    }

    @Test @MainActor func aDocumentWithARealFileGetsItsRelativeImageResolved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentRelativeLinksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("document.md")
        try Data().write(to: fileURL)

        let document = LiveDocument(text: "![alt](./screenshot.png)", fileURL: fileURL)

        #expect(document.bodyHTML.contains(#"src="folium-doc://doc/screenshot.png""#))
    }
}
