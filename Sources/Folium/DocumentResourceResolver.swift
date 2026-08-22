import Foundation

/// Decides which files on disk a rendered document is allowed to reach
/// through the private `folium-doc:` scheme (issue #18).
///
/// `MarkdownWebView` used to widen `loadFileURL`'s `allowingReadAccessTo`
/// grant to make relative images and links work, but that grant is given to
/// the whole web content process — every script the page runs, not just the
/// `<img>`/`<a>` tags Folium itself renders. There is also no directory that
/// contains both the shell (inside `Folium.app/Contents/Resources`) and an
/// arbitrary document (anywhere under the user's home directory) for the
/// grant to name. `DocumentResourceSchemeHandler` reads bytes on the app's
/// own process instead and hands them to the web content process one file at
/// a time, and this type is the policy that governs which files that is —
/// kept here, with no WebKit import, so the policy is unit-tested rather
/// than trusted to a directory handed to WebKit. See
/// `docs/adr/0007-document-resources-via-url-scheme.md`.
enum DocumentResourceResolver {
    /// The custom scheme `DocumentRelativeLinks` rewrites document-relative
    /// `src`/`href` values into, and `DocumentResourceSchemeHandler`
    /// registers a handler for. Kept here, in the logic layer, so
    /// `NavigationPolicy` can compare against it without importing WebKit
    /// just to name the scheme `DocumentResourceSchemeHandler` also uses.
    static let scheme = "folium-doc"

    /// Maps an incoming `folium-doc:` request to the real file it names, or
    /// `nil` if the request doesn't name a file this document is allowed to
    /// read.
    ///
    /// A rendered Markdown document is untrusted input — it might be a repo
    /// checkout nobody has read yet — so every one of these checks matters:
    /// - The request path is resolved against `documentDirectory`, then
    ///   canonicalised (`standardized`, `resolvingSymlinksInPath`) *before*
    ///   the containment check runs. Canonicalising first is what catches
    ///   both `folium-doc://doc/../../../etc/passwd` (a `..` sequence
    ///   written directly into a document, since `DocumentRelativeLinks`
    ///   only rewrites plain relative references — a `folium-doc:` URL
    ///   authored by hand in the source Markdown reaches here unchanged) and
    ///   a symlink inside the document's own directory that points outside
    ///   it: checking containment against the *un*canonicalised path would
    ///   miss both, because neither `..` nor a symlink target is visible in
    ///   the string until it's resolved.
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

    /// Whether `candidate` is `directory` itself or something inside it.
    /// String-prefix comparison, not `URL`'s own relationship APIs: both
    /// URLs are already standardized absolute file paths at this point, and
    /// a prefix check on the path string is the plainest way to state "is
    /// under" without pulling in path-component-by-component comparison for
    /// no added safety.
    private static func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let directoryPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return candidate.path.hasPrefix(directoryPath)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}
