import Foundation

/// Rewrites document-relative `src`/`href` values in rendered HTML so images
/// and links next to a Markdown file resolve correctly (issue #18).
///
/// `MarkdownWebView` loads the page shell from `Resources/page.html` inside
/// the app bundle, and never reloads it. A relative reference in a rendered
/// document — `![](./screenshot.png)` — has no base of its own; WebKit
/// resolves it against whatever page is currently loaded, which is the
/// shell, not the document.
///
/// An early version of this fix rewrote references to absolute `file://`
/// URLs and widened `loadFileURL`'s read-access grant to cover the
/// document's directory. Measurement against the real shell (see
/// `docs/adr/0007-document-resources-via-url-scheme.md`) found that grant
/// has to include whatever directory the shell itself loads from, and in
/// production there is no directory that contains both
/// `Folium.app/Contents/Resources` and an arbitrary document under the
/// user's home folder. This function now targets the private `folium-doc:`
/// scheme instead: `DocumentResourceSchemeHandler` reads the bytes on the
/// app's own process, so the web content process never receives a
/// filesystem grant at all. The fix still belongs here, in Swift, rather
/// than a `<base>` tag in the page shell: the CSP's `base-uri 'none'`
/// (issue #17) forecloses that route deliberately, so relative references
/// have to be rewritten before they ever reach the DOM.
enum DocumentRelativeLinks {
    /// Rewrites every document-relative `src`/`href` value in `html` to a
    /// `folium-doc://doc/<relative path>` URL, expressed relative to
    /// `directory`.
    ///
    /// Only plain relative references are touched. Left alone, byte-for-byte:
    /// - Absolute URLs with any scheme (`http:`, `https:`, `data:`,
    ///   `mailto:`, `file:`, ...): already point somewhere specific.
    /// - Protocol-relative references (`//host/path`): resolving these
    ///   against a `file://` base does not error — it silently produces
    ///   `file://host/path`, a `file:` URL with a foreign host component.
    ///   That is a bug this function must not have: it would hand the
    ///   `img-src file:` / navigation-policy `file:` cases (see
    ///   `NavigationPolicy`) something not actually local, on the strength
    ///   of a scheme match alone.
    /// - Absolute-path references (`/etc/passwd`): not what "relative to the
    ///   document" means, and resolving one would let a document point
    ///   anywhere on the filesystem rather than somewhere under its own
    ///   directory. Left for the (already-existing, already broken) default
    ///   behavior rather than given a new capability.
    /// - Pure fragments (`#usage`): nothing to resolve; `NavigationPolicy`
    ///   already handles in-page scrolling.
    ///
    /// Conservative on top of that: a value this function doesn't recognize
    /// is left exactly as it was rather than rewritten into something that
    /// might not parse. `CONTEXT.md`'s first floor is that the document says
    /// what the file says — a value this function can't confidently resolve
    /// is safer left broken in the familiar way than replaced with a guess.
    static func resolve(_ html: String, relativeTo directory: URL) -> String {
        guard let regex = attributeValueRegex else { return html }
        let fullRange = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: fullRange)
        guard !matches.isEmpty else { return html }

        let mutable = NSMutableString(string: html)
        // Replacing back-to-front keeps every earlier match's NSRange valid;
        // replacing a later range first would shift the string out from
        // under any match still to come.
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let valueRange = match.range(at: 1)
            guard valueRange.location != NSNotFound,
                  let value = Range(valueRange, in: html).map({ String(html[$0]) }),
                  let resolved = resolvedAbsoluteString(for: value, relativeTo: directory)
            else { continue }
            mutable.replaceCharacters(in: valueRange, with: resolved)
        }
        return mutable as String
    }

    /// Matches a `src="..."` or `href="..."` attribute, capturing the quoted
    /// value. The lookbehind requires the attribute name to start right
    /// after whitespace, so a hypothetical `data-src="..."` — not something
    /// cmark-gfm emits, but not impossible in HTML generally — doesn't match
    /// on the `src` inside it. cmark-gfm's HTML renderer always quotes
    /// attribute values with `"` and HTML-escapes any literal `"` inside
    /// them to `&quot;`, so a bare `"` inside `[^"]*` is always the value's
    /// real end, never one it contains.
    private static let attributeValueRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?<=\s)(?:src|href)="([^"]*)""#
    )

    /// Resolves one attribute value, or returns `nil` if it should be left
    /// untouched — either because it is one of the forms `resolve` leaves
    /// alone, or because it failed to parse as a URL reference at all.
    private static func resolvedAbsoluteString(for value: String, relativeTo directory: URL) -> String? {
        guard !value.isEmpty, !value.hasPrefix("#"), !value.hasPrefix("//"), !value.hasPrefix("/") else {
            return nil
        }
        guard !hasScheme(value) else { return nil }
        // `URL(string:relativeTo:)` against the real directory does the
        // actual reference-resolution work — walking `..` segments,
        // decoding what's already percent-encoded without doing it twice —
        // exactly as it did when this produced a `file://` URL. What's new
        // is turning that resolved location into a `folium-doc:` URL naming
        // the same file relative to `directory`, since the scheme handler
        // on the other end resolves every request that way too (see
        // `DocumentResourceResolver`).
        guard let resolved = URL(string: value, relativeTo: directory)?.absoluteURL else { return nil }
        return documentSchemeURLString(for: resolved, relativeTo: directory)
    }

    /// Rebuilds `resolved` (an absolute `file://` location) as a
    /// `folium-doc://doc/<relative path>` URL, walking up out of `directory`
    /// with `..` segments if the reference pointed above it. Query and
    /// fragment carry over unchanged — a document-relative reference like
    /// `sibling.md#section` still has to land on the right anchor once
    /// `NavigationPolicy` opens it.
    private static func documentSchemeURLString(for resolved: URL, relativeTo directory: URL) -> String? {
        // `.standardized`, not `.standardizedFileURL`: the latter — like
        // `.resolvingSymlinksInPath()` — consults the filesystem-
        // representation machinery, which on macOS silently renders an
        // accented character in Unicode's decomposed form (`e` + a
        // combining acute accent) instead of the precomposed form
        // `URL(string:relativeTo:)` itself produces. `.standardized` only
        // collapses `.`/`..` segments in the string, so it can't introduce
        // that mismatch.
        let directoryComponents = directory.standardized.pathComponents.filter { $0 != "/" }
        let targetComponents = resolved.standardized.pathComponents.filter { $0 != "/" }

        var sharedPrefixLength = 0
        while sharedPrefixLength < directoryComponents.count,
              sharedPrefixLength < targetComponents.count,
              directoryComponents[sharedPrefixLength] == targetComponents[sharedPrefixLength] {
            sharedPrefixLength += 1
        }
        let ascents = Array(repeating: "..", count: directoryComponents.count - sharedPrefixLength)
        let relativeComponents = ascents + targetComponents[sharedPrefixLength...]
        guard !relativeComponents.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "doc"
        // Setting `.path` from decoded component strings, rather than
        // building the string by hand, is what makes `URLComponents`
        // percent-encode it correctly — the same job `URL(string:relativeTo:)`
        // did when this produced a `file://` URL directly.
        components.path = "/" + relativeComponents.joined(separator: "/")
        components.query = resolved.query
        components.fragment = resolved.fragment
        return components.url?.absoluteString
    }

    /// The scheme string is defined once, on `DocumentResourceResolver`, and
    /// referenced from here and from `DocumentResourceSchemeHandler` — so
    /// the three places that all have to agree on `"folium-doc"` can't drift
    /// apart from each other.
    private static let scheme = DocumentResourceResolver.scheme

    /// Whether `value` starts with an RFC 3986 URI scheme (`ALPHA
    /// *(ALPHA / DIGIT / "+" / "-" / ".") ":"`) — the same grammar that
    /// makes `https:`, `mailto:`, `data:`, and `file:` absolute references
    /// rather than relative ones. Checked explicitly, rather than leaned on
    /// implicitly via `URL(string:relativeTo:)`'s own scheme handling, so
    /// the “leave absolute URLs alone” rule is something a reader can see
    /// and a test can target directly.
    private static func hasScheme(_ value: String) -> Bool {
        guard let colonIndex = value.firstIndex(of: ":") else { return false }
        let candidate = value[value.startIndex..<colonIndex]
        guard let first = candidate.first, first.isASCII, first.isLetter else { return false }
        return candidate.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "+-.".contains(character))
        }
    }
}
