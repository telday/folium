import Foundation
import Testing
@testable import Folium

struct MarkdownPageTests {
    // MARK: - resourceBaseURL

    @Test func resourceBaseURLPointsAtFoliumsOwnBundle() {
        // MarkdownWebView must resolve the shell's relative <link>/<script
        // src> references — and the loadFileURL read-access grant — against
        // this. Drift here (e.g. back to the wrong `resourceURL` property,
        // which points at a nonexistent path) would silently unstyle the
        // whole app. Under the test runner the resolution takes its fallback
        // branch, so this also proves the fallback yields a usable base.
        #expect(MarkdownPage.resourceBaseURL.isFileURL)
        #expect(MarkdownPage.resourceBaseURL.lastPathComponent.hasSuffix(".bundle"))
    }

    @Test func pageURLPointsAtTheRealShellFile() {
        #expect(MarkdownPage.pageURL.lastPathComponent == "page.html")
        #expect(FileManager.default.fileExists(atPath: MarkdownPage.pageURL.path))
    }

    @Test func shellReferencesEveryAssetByURLWithNoCDNReference() throws {
        let shell = try String(contentsOf: MarkdownPage.pageURL, encoding: .utf8)

        #expect(shell.contains(#"<link rel="stylesheet" href="github.css">"#))
        #expect(shell.contains(#"href="../HighlightJS/styles/github.min.css" media="(prefers-color-scheme: light)""#))
        let darkThemeLink = #"href="../HighlightJS/styles/github-dark.min.css" media="(prefers-color-scheme: dark)""#
        #expect(shell.contains(darkThemeLink))
        #expect(shell.contains(#"<link rel="stylesheet" href="code-block.css">"#))
        #expect(shell.contains(#"<script src="../HighlightJS/highlight.min.js"></script>"#))
        #expect(shell.contains(#"<script src="code-block.js"></script>"#))
        // Defines window.FoliumScrollBy, which scrollScript calls.
        #expect(shell.contains(#"<script src="scroll.js"></script>"#))
        // The container renderBodyScript's window.FoliumRenderBody targets.
        #expect(shell.contains(#"<article class="markdown-body" id="markdown-content"></article>"#))
        // Vendored locally, loaded from the app's own bundle: every asset
        // reference is a bundle-relative path, never an absolute http(s) URL.
        #expect(!shell.contains("http://"))
        #expect(!shell.contains("https://"))
        #expect(!shell.contains("cdn"))
    }

    @Test func shellDeclaresSystemColorScheme() throws {
        let shell = try String(contentsOf: MarkdownPage.pageURL, encoding: .utf8)
        // WKWebView needs this to report the system light/dark setting.
        #expect(shell.contains(#"<meta name="color-scheme" content="light dark">"#))
    }

    @Test func shellDeclaresACSPThatEnforcesTheNoNetworkFloor() throws {
        let shell = try String(contentsOf: MarkdownPage.pageURL, encoding: .utf8)

        let openTag = #"<meta http-equiv="Content-Security-Policy" content=""#
        guard let cspOpen = shell.range(of: openTag),
              let cspClose = shell.range(of: "\">", range: cspOpen.upperBound..<shell.endIndex) else {
            Issue.record("No CSP meta tag found in page.html")
            return
        }
        // Isolated to just the directive string, not the whole file: the
        // surrounding doc comment quotes CSP fragments like `script-src file:`
        // by name while explaining the choice, and a whole-file substring
        // check would trip over its own explanation.
        let cspContent = String(shell[cspOpen.upperBound..<cspClose.lowerBound])

        // Every asset tag must load under a policy that's already in force —
        // a CSP appended after them would leave a window where nothing
        // polices the very tags issue #17 exists to police. Searched only
        // after the meta tag closes, not from the top of the file: the doc
        // comment above the meta tag itself quotes `<link rel="stylesheet">`
        // by name, and a whole-file search would match that mention instead.
        let firstAssetTag = shell.range(of: "<link rel=\"stylesheet\"", range: cspClose.upperBound..<shell.endIndex)
        #expect(firstAssetTag != nil)

        // Every fetch directive uses the unquoted scheme-source `file:`, not
        // `'self'` — see the comment in page.html: `'self'` was measured to
        // still admit a cross-origin `https://` load on this `file://` page,
        // which `file:` does not. Verified in `ContentSecurityPolicyTests.swift`.
        let directives = [
            "default-src 'none'",
            "script-src file:",
            "style-src file:",
            "img-src file:",
            "font-src file:",
            "media-src file:",
            "base-uri 'none'",
            "form-action 'none'"
        ]
        for directive in directives {
            #expect(cspContent.contains(directive), "missing CSP directive: \(directive)")
        }
        // The whole point of this CSP: no directive may use 'self', which
        // was found not to restrict http(s) sources on this file:// page.
        #expect(!cspContent.contains("'self'"))
    }

    // MARK: - renderBodyScript

    @Test func rendersToAFoliumRenderBodyCall() {
        let script = MarkdownPage.renderBodyScript(bodyHTML: "<p>hi</p>")

        #expect(script.hasPrefix(#"window.FoliumRenderBody(""#))
        #expect(script.hasSuffix(#"")"#))
        // JSONEncoder also escapes "/" as "\/" (a JSON convention, harmless
        // here, that avoids "</script>" prematurely closing an embedding
        // <script> tag) — closing tags come through with an escaped slash.
        #expect(script.contains(#"<p>hi<\/p>"#))
    }

    @Test func safelyEscapesContentForJSInjection() {
        // JSON-encoded, so an embedded quote is escaped rather than
        // terminating the JS string literal early — a real injection risk
        // if a Markdown document's rendered HTML happened to contain one.
        let script = MarkdownPage.renderBodyScript(bodyHTML: #"<p>She said "hi"</p>"#)

        #expect(script.contains(#"She said \"hi\""#))
        #expect(!script.contains(#"said "hi""#))
    }

    @Test func decoratesCodeBlocksBeforeInjecting() {
        let bodyHTML = #"<pre><code class="language-swift">let x = 1\n</code></pre>"#
        let script = MarkdownPage.renderBodyScript(bodyHTML: bodyHTML)

        // The full pipeline runs the body through CodeBlockDecorator, not
        // just a literal pass-through — drift here would silently ship
        // fenced code with no chrome at all. Quotes are JSON-escaped (this
        // is embedded in a JS string literal) and closing tags carry a
        // JSON-escaped "\/" — see rendersToAFoliumRenderBodyCall.
        #expect(script.contains(#"class=\"code-block\""#))
        #expect(script.contains(#"<span class=\"code-block-lang\">swift<\/span>"#))
        #expect(script.contains(#"<button type=\"button\" class=\"copy-button\">Copy<\/button>"#))
    }

    // MARK: - paintConfirmationScript

    @Test func paintConfirmationScriptWaitsForTwoAnimationFrames() {
        // The double requestAnimationFrame is the entire mechanism this
        // relies on — see the doc comment on why one frame isn't enough. It
        // has to run via `callAsyncJavaScript`, not `evaluateJavaScript`,
        // which is why this is a function body (`await` + `return`) rather
        // than a bare expression — `LiveReloadTests` (integration) proves
        // `callAsyncJavaScript` actually waits on an `await` before its
        // callback fires.
        let script = MarkdownPage.paintConfirmationScript
        #expect(script.contains("await"))
        #expect(script.contains("Promise"))
        #expect(script.components(separatedBy: "requestAnimationFrame").count - 1 == 2)
    }

    // MARK: - scrollScript

    @Test func scrollsTheDocumentTheWayTheKeyPointed() {
        // Sign is the whole contract between Swift and window.FoliumScrollBy:
        // the two are otherwise indistinguishable, and getting it backwards is
        // the kind of bug nothing else here would catch.
        #expect(MarkdownPage.scrollScript(.downward) == "window.FoliumScrollBy(3)")
        #expect(MarkdownPage.scrollScript(.upward) == "window.FoliumScrollBy(-3)")
    }

    @Test func scrollJSTakesItsStepInLinesSoTextZoomCarriesThrough() throws {
        let scrollJS = try String(
            contentsOf: MarkdownPage.resourceBaseURL.appendingPathComponent("Resources/scroll.js"),
            encoding: .utf8
        )

        // A pixel step baked into the Swift side would stop meaning "a few
        // lines" the moment the user pressed ⌘+.
        #expect(scrollJS.contains("lineHeight"))
        // Smooth motion is an acceptance criterion of issue #6, and it is one
        // option string away from being a jump.
        #expect(scrollJS.contains(#"behavior: "smooth""#))
        // Native capture, not a page-side listener — also an acceptance
        // criterion, and cheap to regress by "just adding a listener here".
        #expect(!scrollJS.contains("addEventListener"))
    }

    // MARK: - scrollToAnchorScript

    @Test func rendersToAFoliumScrollToAnchorCall() {
        let script = MarkdownPage.scrollToAnchorScript("usage")

        #expect(script == #"window.FoliumScrollToAnchor("usage")"#)
    }

    @Test func safelyEscapesAFragmentContainingQuotesAndBackslashesForJSInjection() {
        // The fragment comes straight off a URL in rendered document content,
        // so it's attacker-controlled the same way renderBodyScript's HTML
        // is — an unescaped quote or backslash must not be able to break out
        // of the JS string literal it's injected into.
        let script = MarkdownPage.scrollToAnchorScript(#"a"b\c"#)

        #expect(script.contains(#"a\"b\\c"#))
        #expect(!script.contains(#""a"b\c""#))
    }

    /// The probe has to report all three fields `BenchBudget
    /// .scrollReportLine(from:)` reads, and infer the frame interval from
    /// the run rather than assuming 60 Hz — otherwise a 120 Hz display would
    /// pass while dropping every other frame.
    @Test func scrollProbeScriptReportsFramesDroppedAgainstAnObservedInterval() {
        let script = MarkdownPage.scrollProbeScript

        #expect(script.contains("requestAnimationFrame"))
        #expect(script.contains("measured:"))
        #expect(script.contains("dropped:"))
        #expect(script.contains("hz:"))
        // The interval comes from the sorted samples, not a literal 16.67.
        #expect(script.contains("sorted[Math.floor(sorted.length * 0.1)]"))
        #expect(!script.contains("16.67"))
    }

    /// A document scrolled past its end stops painting new content, so idle
    /// frames would dilute the count.
    @Test func scrollProbeScriptWrapsBackToTheTopAtTheEndOfTheDocument() {
        #expect(MarkdownPage.scrollProbeScript.contains("window.scrollTo(0, 0)"))
    }
}
