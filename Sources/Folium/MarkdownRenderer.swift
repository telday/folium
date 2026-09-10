import cmark_gfm
import cmark_gfm_extensions

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Converts Markdown to HTML via cmark-gfm, with the table, strikethrough,
/// tasklist, and autolink GFM extensions attached (ADR 0005). This is the
/// only place in the app that touches the cmark-gfm C API.
enum MarkdownRenderer {
    private static let extensionNames = ["table", "strikethrough", "tasklist", "autolink"]

    /// Renders raw HTML in the document instead of replacing it with an
    /// invisible `<!-- raw HTML omitted -->` (issue #20, [ADR 0009]).
    ///
    /// The name is cmark's, and it describes what the *library* stops
    /// doing, not what this app does: since cmark 0.29 safe mode is the
    /// default, and `CMARK_OPT_SAFE` "no longer has any effect"
    /// (`cmark-gfm.h`). Dropping every `<details>`, `<kbd>`, `<br>` and
    /// centred logo along with it violates `CONTEXT.md`'s first floor —
    /// the document has to say what the file says. So the filtering moves
    /// down a layer, to where GitHub also does it in the end: the shell's
    /// Content-Security-Policy (issue #17), which refuses to run a script,
    /// fetch a remote resource, or follow a `javascript:` URL no matter
    /// which of them wrote it, plus `NavigationPolicy` on the navigation
    /// side. Proven in `RawHTMLSafetyTests` and `RawHTMLRenderingTests`.
    ///
    /// This is a *render* option, not a parse option: the parser keeps
    /// `CMARK_OPT_DEFAULT` either way, since what it produces for a raw
    /// HTML node is the same node — safe mode only changes what
    /// `cmark_render_html` writes out for it.
    ///
    /// [ADR 0009]: ../../docs/adr/0009-raw-html-sanitized-below-the-renderer.md
    private static let renderOptions = CMARK_OPT_UNSAFE

    static func renderHTML(from markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()

        // The cmark C calls below only return nil on allocation failure, which
        // isn't reachable from any Markdown input; the guards stay on one line
        // so line coverage isn't dragged down by branches tests can't hit.
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return "" }
        defer { cmark_parser_free(parser) }

        for name in extensionNames {
            if let syntaxExtension = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }

        markdown.withCString { cString in
            cmark_parser_feed(parser, cString, strlen(cString))
        }

        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }

        let attachedExtensions = cmark_parser_get_syntax_extensions(parser)
        guard let htmlCString = cmark_render_html(document, renderOptions, attachedExtensions) else { return "" }
        defer { free(htmlCString) }

        return String(cString: htmlCString)
    }
}
