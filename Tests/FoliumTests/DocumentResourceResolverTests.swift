import Foundation
import Testing
@testable import Folium

/// Unit coverage for the policy that decides which files a `folium-doc:`
/// request may read (issue #18). A rendered Markdown document is untrusted
/// input, so every case here is written from the attacker's side: what does
/// this request try to reach, and should it succeed?
///
/// Real files and directories under a throwaway temporary directory, not
/// hand-constructed `URL`s: `resolvingSymlinksInPath()` and the
/// regular-file check both consult the filesystem, so a fixture that
/// doesn't exist on disk can't exercise them.
struct DocumentResourceResolverTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentResourceResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - The straightforward case

    @Test func aFileDirectlyInsideTheDirectoryResolves() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("screenshot.png")
        try Data([0xAA]).write(to: file)

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/screenshot.png")!,
            documentDirectory: directory
        )

        #expect(resolved?.path == file.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    @Test func aFileInASubdirectoryResolves() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subdirectory = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let file = subdirectory.appendingPathComponent("screenshot.png")
        try Data([0xAA]).write(to: file)

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/images/screenshot.png")!,
            documentDirectory: directory
        )

        #expect(resolved != nil)
    }

    // MARK: - Traversal: the attack this type exists to refuse

    @Test func dotDotTraversalOutOfTheDirectoryIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A real target above `directory`, so a bug that let this through
        // would resolve to an actual file rather than merely a missing one —
        // the test would fail the same way either way, but this rules out
        // "it returned nil because /etc/passwd doesn't exist in CI" as an
        // alternative explanation for a pass.
        let outsideFile = directory.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try Data([0xAA]).write(to: outsideFile)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/../\(outsideFile.lastPathComponent)")!,
            documentDirectory: directory
        )

        #expect(resolved == nil)
    }

    @Test func deeplyNestedDotDotTraversalIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/../../../../../../etc/passwd")!,
            documentDirectory: directory
        )

        #expect(resolved == nil)
    }

    // MARK: - Symlink escape: the attack canonicalising the path is for

    @Test func aSymlinkInsideTheDirectoryPointingOutsideItIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secretDirectory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: secretDirectory) }
        let secretFile = secretDirectory.appendingPathComponent("secret.txt")
        try Data([0xAA]).write(to: secretFile)

        // A symlink an attacker's document could plant (or that already
        // exists for an unrelated reason) inside the document's own
        // directory, pointing at a file the document has no business
        // reading.
        let escapeLink = directory.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: secretFile)

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/escape")!,
            documentDirectory: directory
        )

        #expect(resolved == nil)
    }

    @Test func aSymlinkedFileThatStaysInsideTheDirectoryResolves() throws {
        // The containment check is about where the *real* file ends up, not
        // whether a symlink was involved at all — a symlink that resolves to
        // somewhere still inside the document's own directory is exactly as
        // legitimate as the file it names directly.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let realFile = directory.appendingPathComponent("real.png")
        try Data([0xAA]).write(to: realFile)
        let linkedFile = directory.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: realFile)

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/linked.png")!,
            documentDirectory: directory
        )

        #expect(resolved?.path == realFile.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    // MARK: - Only regular files are served

    @Test func aDirectoryIsRefusedEvenThoughItsPathIsInsideTheDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subdirectory = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/images")!,
            documentDirectory: directory
        )

        #expect(resolved == nil)
    }

    @Test func aPathThatDoesNotExistIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/does-not-exist.png")!,
            documentDirectory: directory
        )

        #expect(resolved == nil)
    }

    // MARK: - Percent-decoding

    @Test func aSpaceInTheFilenameIsDecodedAndResolves() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("my file.png")
        try Data([0xAA]).write(to: file)

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/my%20file.png")!,
            documentDirectory: directory
        )

        #expect(resolved != nil)
    }

    @Test func nonASCIICharactersInTheFilenameAreDecodedAndResolve() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("café.png")
        try Data([0xAA]).write(to: file)

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/caf%C3%A9.png")!,
            documentDirectory: directory
        )

        #expect(resolved != nil)
    }

    /// A literal `#` in a filename has to arrive already percent-encoded
    /// (`%23`) to survive as part of the path at all — an un-encoded `#`
    /// starts a URL fragment instead, which `URLSchemeTask.request.url`
    /// would never even hand to this function as part of the path. This
    /// asserts the decoding side of that contract: once it's `%23` in the
    /// request, it has to come back out as a literal `#` when read from disk.
    @Test func aPercentEncodedHashInTheFilenameIsDecodedAndResolves() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a#b.png")
        try Data([0xAA]).write(to: file)

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/a%23b.png")!,
            documentDirectory: directory
        )

        #expect(resolved != nil)
    }

    @Test func aPercentEncodedQuestionMarkInTheFilenameIsDecodedAndResolves() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a?b.png")
        try Data([0xAA]).write(to: file)

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/a%3Fb.png")!,
            documentDirectory: directory
        )

        #expect(resolved != nil)
    }

    // MARK: - Degenerate requests

    @Test func aRequestNamingTheDirectoryItselfIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let resolved = DocumentResourceResolver.fileURL(
            for: URL(string: "folium-doc://doc/")!,
            documentDirectory: directory
        )

        #expect(resolved == nil)
    }
}
