import Testing
@testable import Folium

struct MarkdownRendererTests {
    @Test func heading() {
        let html = MarkdownRenderer.renderHTML(from: "# Hello")
        #expect(html.contains("<h1>Hello</h1>"))
    }

    @Test func paragraph() {
        let html = MarkdownRenderer.renderHTML(from: "Just a paragraph.")
        #expect(html.contains("<p>Just a paragraph.</p>"))
    }

    @Test func table() {
        let markdown = """
        | A | B |
        | - | - |
        | 1 | 2 |
        """
        let html = MarkdownRenderer.renderHTML(from: markdown)
        #expect(html.contains("<table>"))
        #expect(html.contains("<th>A</th>"))
        #expect(html.contains("<td>1</td>"))
    }

    @Test func taskListCheckboxes() {
        let markdown = """
        - [ ] todo
        - [x] done
        """
        let html = MarkdownRenderer.renderHTML(from: markdown)
        #expect(html.contains(#"<input type="checkbox" disabled="" />"#))
        #expect(html.contains(#"<input type="checkbox" checked="" disabled="" />"#))
    }

    @Test func strikethrough() {
        let html = MarkdownRenderer.renderHTML(from: "~~gone~~")
        #expect(html.contains("<del>gone</del>"))
    }

    @Test func autolink() {
        let html = MarkdownRenderer.renderHTML(from: "See https://example.com for more.")
        #expect(html.contains(#"<a href="https://example.com">https://example.com</a>"#))
    }

    // MARK: - Raw HTML (issue #20)
    //
    // cmark-gfm's own tests already cover what each of these tags parses
    // into. What is ours is the *option*: since cmark 0.29, safe mode is the
    // default, and `CMARK_OPT_DEFAULT` replaces every raw HTML span and
    // block with an invisible `<!-- raw HTML omitted -->`. These assert the
    // seam that decision lives on — that raw HTML reaches the page at all —
    // rather than re-asserting the shape of what arrives.

    @Test func rawHTMLBlockIsNotOmitted() {
        let html = MarkdownRenderer.renderHTML(from: "<details><summary>More</summary>\n\nBody\n\n</details>")
        #expect(!html.contains("raw HTML omitted"))
        #expect(html.contains("<details>"))
        #expect(html.contains("<summary>More</summary>"))
    }

    @Test func rawInlineHTMLIsNotOmitted() {
        // A `<br>` is the case that silently *corrupts* rather than merely
        // dropping: omitted, the words on either side of it join up.
        let html = MarkdownRenderer.renderHTML(from: "line one<br>line two")
        #expect(html.contains("line one<br>line two"))
    }

    @Test func rawHTMLImageAttributesSurvive() {
        // The centred-logo/badge-row opening of nearly every README: the
        // whole block disappears under safe mode, attributes and all.
        let markdown = #"<p align="center"><img src="logo.png" align="right"></p>"#
        let html = MarkdownRenderer.renderHTML(from: markdown)
        #expect(html.contains(#"<p align="center">"#))
        #expect(html.contains(#"<img src="logo.png" align="right">"#))
    }

    /// Unsafe mode re-permits `javascript:` in *plain Markdown link syntax*
    /// too, not only in raw HTML — safe mode used to rewrite it to an empty
    /// destination. Asserted here so the fact is visible at the layer that
    /// stopped filtering it: nothing downstream of the renderer may assume
    /// an href it receives carries a benign scheme. What actually stops it
    /// is the shell's CSP plus `NavigationPolicy`, proven in
    /// `RawHTMLSafetyTests`.
    @Test func javascriptSchemeSurvivesInPlainMarkdownLinkSyntax() {
        let html = MarkdownRenderer.renderHTML(from: "[click](javascript:window.PWNED=true)")
        #expect(html.contains(#"href="javascript:window.PWNED=true""#))
    }
}
