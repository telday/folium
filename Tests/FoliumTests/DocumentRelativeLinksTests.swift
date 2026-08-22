import Foundation
import Testing
@testable import Folium

/// Unit coverage for issue #18's resolution table: which `src`/`href`
/// values get rewritten to an absolute `file://` URL under the document's
/// directory, and which are left exactly as they were.
struct DocumentRelativeLinksTests {
    // A directory with a space and a `#` in its name, so a naive
    // string-concatenation implementation would corrupt every case below —
    // `URL`'s own percent-encoding is what keeps them correct.
    private let directory = URL(fileURLWithPath: "/Users/me/My Docs #2", isDirectory: true)

    // MARK: - Relative forms that must resolve

    @Test func dotSlashRelativeImageResolvesUnderTheDirectory() {
        let html = #"<img src="./screenshot.png" alt="">"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<img src="file:///Users/me/My%20Docs%20%232/screenshot.png" alt="">"#)
    }

    @Test func bareRelativeImageResolvesUnderTheDirectory() {
        let html = #"<img src="screenshot.png" alt="">"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<img src="file:///Users/me/My%20Docs%20%232/screenshot.png" alt="">"#)
    }

    @Test func parentDirectoryReferenceWalksUpBeforeResolving() {
        let html = #"<a href="../sibling/notes.md">notes</a>"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<a href="file:///Users/me/sibling/notes.md">notes</a>"#)
    }

    @Test func siblingMarkdownLinkResolves() {
        let html = #"<a href="sibling.md">sibling</a>"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<a href="file:///Users/me/My%20Docs%20%232/sibling.md">sibling</a>"#)
    }

    @Test func siblingMarkdownLinkWithAnchorKeepsTheFragment() {
        let html = ##"<a href="sibling.md#section">sibling</a>"##
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == ##"<a href="file:///Users/me/My%20Docs%20%232/sibling.md#section">sibling</a>"##)
    }

    // MARK: - Percent-encoding: spaces, `#`/`?`, and non-ASCII in filenames

    @Test func alreadyPercentEncodedSpaceIsNotDoubleEncoded() {
        // cmark-gfm itself percent-encodes a space in a `<...>`-bracketed
        // destination before this function ever sees it — see the doc
        // comment on `resolve`. Re-encoding the already-encoded `%20`
        // would turn it into `%2520`, a broken filename.
        let html = #"<img src="./my%20file.png" alt="">"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<img src="file:///Users/me/My%20Docs%20%232/my%20file.png" alt="">"#)
    }

    @Test func alreadyPercentEncodedNonASCIIIsNotDoubleEncoded() {
        let html = #"<img src="./caf%C3%A9.png" alt="">"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<img src="file:///Users/me/My%20Docs%20%232/caf%C3%A9.png" alt="">"#)
    }

    @Test func literalHashInAFilenameSplitsAsAFragmentLikeAnyURLWould() {
        // cmark-gfm does not percent-encode `#`/`?` in a destination — see
        // the spike in the PR description. `resolve` treats the value as an
        // ordinary URL reference, exactly like a browser resolving the same
        // string would, rather than guessing that the author meant a
        // literal `#` in a filename.
        let html = ##"<img src="./a#b.png" alt="">"##
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == ##"<img src="file:///Users/me/My%20Docs%20%232/a#b.png" alt="">"##)
    }

    @Test func literalQuestionMarkInAFilenameIsKeptAsAQueryByTheSameLogic() {
        let html = #"<img src="./a?b=1.png" alt="">"#
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved == #"<img src="file:///Users/me/My%20Docs%20%232/a?b=1.png" alt="">"#)
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
        #expect(resolved == #"<img src="file:///Users/me/My%20Docs%20%232/screenshot.png" alt="a relative path in prose: ./not-an-attribute.png">"#)
    }

    @Test func multipleReferencesInOneDocumentAllResolve() {
        let html = """
        <p><img src="a.png" alt=""></p>
        <p><a href="b.md">b</a></p>
        <p><img src="https://example.com/c.png" alt=""></p>
        """
        let resolved = DocumentRelativeLinks.resolve(html, relativeTo: directory)
        #expect(resolved.contains(#"src="file:///Users/me/My%20Docs%20%232/a.png""#))
        #expect(resolved.contains(#"href="file:///Users/me/My%20Docs%20%232/b.md""#))
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

        let expectedPrefix = "src=\"\(directory.appendingPathComponent("screenshot.png").absoluteString)\""
        #expect(document.bodyHTML.contains(expectedPrefix))
    }
}
