import AppKit
import Testing
import WebKit
@testable import Folium

/// The other half of issue #20's seam: raw HTML in a document **renders**.
/// `<details>`, `<br>`, `<sub>`/`<sup>`, `<img>` and `<kbd>` do what a reader
/// of the file expects, instead of vanishing into an invisible
/// `<!-- raw HTML omitted -->` — `CONTEXT.md`'s first floor. See
/// [ADR 0009](../../docs/adr/0009-raw-html-sanitized-below-the-renderer.md);
/// `RawHTMLSafetyTests` is the half about what that same HTML may not do.
///
/// Every test here goes red with `CMARK_OPT_UNSAFE` reverted — confirmed,
/// which is the check `docs/agents/testing.md` asks for.
@MainActor
@Suite(.serialized)
struct RawHTMLRenderingTests {
    init() {
        AppKitHost.startIfNeeded()
    }

    /// `<details>` is the case that rendered *wrong* rather than vanishing:
    /// safe mode dropped the `<details>` and `<summary>` tags but kept the
    /// body between them, so a collapsed section arrived permanently
    /// expanded with its summary missing.
    ///
    /// Asserted on the element's own height rather than on the body's
    /// computed `display`, because collapsing is not done by a stylesheet
    /// rule an assertion could read: WebKit renders the closed state by
    /// leaving the non-summary content unslotted in the shadow tree. What a
    /// reader sees is that the section takes up one summary's worth of space
    /// until they click it, and that is what is measured.
    @Test func detailsSectionIsCollapsedUntilItsSummaryIsClicked() async throws {
        let webView = try await RawHTMLHarness.shell()

        try await RawHTMLHarness.render(
            """
            <details><summary>Click me</summary>

            The hidden body.

            </details>
            """,
            in: webView
        )

        #expect(try await RawHTMLHarness.boolean("document.querySelector('details').open", in: webView) == false)
        let collapsedHeight = try await RawHTMLHarness.height(of: "details", in: webView)
        #expect(try await RawHTMLHarness.height(of: "summary", in: webView) == collapsedHeight)

        _ = try await webView.evaluateJavaScript("document.querySelector('summary').click();")

        #expect(await RawHTMLHarness.waitUntil {
            try await RawHTMLHarness.height(of: "details", in: webView) > collapsedHeight
        })
        #expect(try await RawHTMLHarness.boolean("document.querySelector('details').open", in: webView))

        // The other half of the affordance, and this repo's stylesheet's
        // half: a summary the user is expected to click says so under the
        // pointer. Without the `summary` rule in `github.css` this resolves
        // to "auto".
        #expect(try await RawHTMLHarness.string(
            "getComputedStyle(document.querySelector('summary')).cursor",
            in: webView
        ) == "pointer")
    }

    /// `<br>` is the raw-HTML case that silently *corrupted*: omitted, the
    /// words on either side of it joined into one line — and into one word,
    /// where the author wrote no space at all. So the assertion is the one
    /// thing a `<br>` is for, measured in the engine: the same text occupies
    /// twice the height it does without the break.
    ///
    /// Two renders into the same page, so the comparison cannot be thrown
    /// off by a font or a width differing between two setups.
    @Test func lineBreakActuallyBreaksTheLine() async throws {
        let webView = try await RawHTMLHarness.shell()

        try await RawHTMLHarness.render("line one line two", in: webView)
        let unbrokenHeight = try await RawHTMLHarness.height(of: "#markdown-content > p", in: webView)

        try await RawHTMLHarness.render("line one<br>line two", in: webView)
        let brokenHeight = try await RawHTMLHarness.height(of: "#markdown-content > p", in: webView)

        #expect(unbrokenHeight > 0)
        #expect(brokenHeight == unbrokenHeight * 2)
    }

    /// `H<sub>2</sub>O` and `x<sup>2</sup>` reached the page as `H2O` and
    /// `x2` under safe mode — text that reads as something else entirely.
    ///
    /// The seam is that they arrive as *elements* at all; where the engine
    /// then puts them is the engine's business, so this asserts only that
    /// the two are placed differently from each other and from the text
    /// around them, not the offsets it chooses.
    @Test func subscriptAndSuperscriptArePositionedAsSuch() async throws {
        let webView = try await RawHTMLHarness.shell()

        try await RawHTMLHarness.render("H<sub>2</sub>O and x<sup>2</sup>", in: webView)

        #expect(try await RawHTMLHarness.boolean("!!document.querySelector('sub')", in: webView))
        #expect(try await RawHTMLHarness.boolean("!!document.querySelector('sup')", in: webView))
        let subAlignment = try await RawHTMLHarness.string(
            "getComputedStyle(document.querySelector('sub')).verticalAlign",
            in: webView
        )
        let supAlignment = try await RawHTMLHarness.string(
            "getComputedStyle(document.querySelector('sup')).verticalAlign",
            in: webView
        )
        #expect(subAlignment != "baseline")
        #expect(supAlignment != "baseline")
        #expect(subAlignment != supAlignment)
    }

    /// The first screen of nearly every repo README: a centred logo, written
    /// as raw HTML because Markdown has no way to say "centre this". Safe
    /// mode dropped the whole block — wrapper, image and all — with nothing
    /// on screen to say anything had been there.
    ///
    /// Driven off a real fixture through `LiveDocument`, the way
    /// `RelativePathTests` does, because the image only loads if raw HTML
    /// and issue #18's relative-path rewriting both work on the same tag.
    /// The fixture single-quotes its `src` precisely because cmark-gfm never
    /// emits that form: only raw HTML can produce it, and the rewriter had
    /// to learn it.
    @Test func centredLogoBlockRendersAndItsImageLoads() async throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "raw-html-image", withExtension: "md", subdirectory: "Fixtures"),
            "missing Fixtures/raw-html-image.md"
        )
        let webView = try await RawHTMLHarness.shell(documentDirectory: fixture.deletingLastPathComponent())

        let document = LiveDocument(text: try String(contentsOf: fixture, encoding: .utf8), fileURL: fixture)
        _ = try await webView.evaluateJavaScript(MarkdownPage.renderBodyScript(bodyHTML: document.bodyHTML))

        #expect(await RawHTMLHarness.waitUntil {
            try await RawHTMLHarness.number("document.querySelector('img')?.naturalWidth ?? 0", in: webView) > 0
        })
        // The wrapper is the other half of what disappeared: an image that
        // loads but is no longer centred is still not what the file says.
        #expect(try await RawHTMLHarness.boolean(
            "!!document.querySelector('#markdown-content p[align=\"center\"]')",
            in: webView
        ))
    }

    /// `<a name="install"></a>` is the row of issue #20's table whose
    /// symptom outlives the renderer: the element renders now, but the
    /// spec's complaint was "every link to `#install` breaks", and a link
    /// only stops breaking once something scrolls to it.
    ///
    /// `NavigationPolicy` resolves the click to `.scrollToAnchor` and
    /// `Resources/scroll.js` looks the target up — by `id`, which a
    /// name-only anchor does not have. Hence the `getElementsByName`
    /// fallback that this drove out. Heading `id`s are a separate gap:
    /// cmark-gfm emits none, and no `<a name>` fallback can invent them.
    ///
    /// The whole path is real — a click, the real `Coordinator`, the real
    /// policy, the real script — because every piece of it is somewhere the
    /// anchor could be lost.
    @Test func linkToANameAnchorScrollsToIt() async throws {
        let recorder = RawHTMLHarness.OpenedURLRecorder()
        let (webView, waiter) = try await RawHTMLHarness.shellWithCoordinator { recorder.record($0) }
        defer { webView.window?.close() }
        _ = waiter // kept alive: `navigationDelegate` is a weak reference

        // The gap between link and anchor is made of paragraphs rather than
        // a `<div style="height: …">`: the shell's `style-src` refuses an
        // inline style attribute, so the tidier spacer would have had no
        // height and nothing to scroll past.
        let spacer = Array(repeating: "Filler paragraph.", count: 120).joined(separator: "\n\n")
        try await RawHTMLHarness.render(
            """
            [go to install](#install)

            \(spacer)

            <a name="install"></a>

            ## Install
            """,
            in: webView
        )
        _ = try await webView.evaluateJavaScript("document.querySelector('#markdown-content a').click();")

        #expect(await RawHTMLHarness.waitUntil {
            try await RawHTMLHarness.number("window.scrollY", in: webView) > 0
        })
        // Cancelled, not navigated: the fragment never reaches the URL.
        #expect(webView.url?.fragment == nil)
    }

    /// `<kbd>` is the one raw-HTML element this repo's stylesheet had to
    /// grow a rule for — nothing in Markdown syntax emits one, so the
    /// selector would have matched nothing before now. The seam is that our
    /// CSS reaches the DOM raw HTML produces: *a* key cap border, not a
    /// particular width (`docs/agents/testing.md`).
    @Test func keyCapIsStyled() async throws {
        let webView = try await RawHTMLHarness.shell()

        try await RawHTMLHarness.render("Press <kbd>K</kbd>", in: webView)

        let width = try await RawHTMLHarness.string(
            "getComputedStyle(document.querySelector('kbd')).borderTopWidth",
            in: webView
        )
        let style = try await RawHTMLHarness.string(
            "getComputedStyle(document.querySelector('kbd')).borderTopStyle",
            in: webView
        )
        #expect(width != "0px")
        #expect(style == "solid")
    }
}
