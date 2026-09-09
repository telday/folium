import Foundation

/// Decides which files on disk a rendered document is allowed to reach
/// through the private `folium-doc:` scheme (issue #18).
///
/// `DocumentResourceSchemeHandler` reads the bytes and this decides whether
/// it may. Kept apart from that handler, and free of any WebKit import, so
/// the decision is ordinary unit-tested Swift. See
/// [ADR 0007](../../docs/adr/0007-document-resources-via-url-scheme.md) for
/// why a scheme handler rather than a read-access grant.
enum DocumentResourceResolver {
    /// The custom scheme `DocumentRelativeLinks` rewrites document-relative
    /// `src`/`href` values into, and `DocumentResourceSchemeHandler`
    /// registers a handler for. Defined here so the three places that have
    /// to agree on the string can't drift, and so `NavigationPolicy` can
    /// name it without importing WebKit.
    static let scheme = "folium-doc"

    /// Maps an incoming `folium-doc:` request to the real file it names, or
    /// `nil` if the request doesn't name a file this document is allowed to
    /// read.
    ///
    /// A rendered Markdown document is untrusted input — it might be a repo
    /// checkout nobody has read yet — so every one of these checks matters:
    /// - The request path is resolved against `documentDirectory` and then
    ///   canonicalised (`standardized`, `resolvingSymlinksInPath`) *before*
    ///   the containment check runs. Neither a `..` sequence nor a symlink's
    ///   target is visible in the path string until it is resolved, so a
    ///   check against the uncanonicalised path would miss both.
    ///
    ///   A document can reach here with either. `DocumentRelativeLinks`
    ///   rewrites only plain relative references, so a `folium-doc:` URL an
    ///   author typed into the Markdown by hand arrives unchanged — `..`
    ///   segments included — and a symlink can sit in the document's own
    ///   directory pointing anywhere.
    /// - Only a plain, regular file is served — never a directory (which
    ///   would let a document list the contents of the folder it's in) and
    ///   never a device file, pipe, or socket.
    static func fileURL(for requestURL: URL, documentDirectory: URL) -> URL? {
        guard let relativePath = relativePathComponent(of: requestURL) else { return nil }

        // `documentDirectory` itself might contain a symlink further up its
        // own chain (e.g. the whole checkout is symlinked from elsewhere) —
        // resolved once here so the containment check below compares two
        // canonical paths, not a canonical one against a symbolic one.
        let canonicalDirectory = documentDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalCandidate = documentDirectory
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard isContained(canonicalCandidate, in: canonicalDirectory) else { return nil }
        guard isRegularFile(canonicalCandidate) else { return nil }
        return canonicalCandidate
    }

    /// The part of `requestURL` naming a file, relative to the document's
    /// directory: everything after the scheme and host
    /// (`folium-doc://doc/<this part>`). `URL.path` decodes percent-escapes
    /// itself, which is what lets a filename containing a space or an
    /// accented character round-trip correctly.
    private static func relativePathComponent(of requestURL: URL) -> String? {
        let path = requestURL.path
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    /// Whether `candidate` is something inside `directory`. Both are already
    /// canonical absolute paths here, so a prefix check on the path string
    /// says "is under" as safely as a component-by-component walk would.
    /// The trailing separator is what stops `/docs-private` from counting as
    /// inside `/docs`.
    private static func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let directoryPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return candidate.path.hasPrefix(directoryPath)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}
