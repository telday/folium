---
status: accepted
---

# Render Markdown via WKWebView, not native AppKit/SwiftUI

> **Amended 2026-08-13 — see [Amendments](#amendments) below.** Two of the
> future features cited as justification here have since changed: editing is
> now a permanent non-goal, and PlantUML is dropped. The decision stands; parts
> of its reasoning no longer do.

The core renderer displays Markdown as HTML/CSS/JS inside a `WKWebView`, rather than
building a native view tree (`NSAttributedString` / hand-built SwiftUI views) from a
parsed Markdown AST.

We built and compared a throwaway prototype of both (`prototypes/rendering-approach-poc/`,
see git history — dropped from `main` once the decision was made) against the same
sample document, with real vim-style `j`/`k` scroll handling wired into each. The
WKWebView variant looked better and required substantially less hand-built styling
to approach GitHub's code block fidelity, and it's the only realistic path to two
planned future features: Mermaid/PlantUML diagram rendering (both are JS libraries
that render to SVG in a DOM — trivial to embed in a web view, no native Swift
equivalent exists) and syntax highlighting (can reuse existing JS highlighters
instead of hand-rolling one).

## Considered options

- **Native AppKit/SwiftUI rendering** — rejected. Feels more "Mac native" and gives
  more direct control over scrolling and future editing, but GitHub-quality code
  blocks and diagram rendering would both have to be built (or, for diagrams,
  would end up embedding a WKWebView anyway just for those blocks — a hybrid that
  gets the downsides of both approaches without the benefits of either).

## Consequences

- Planned future rudimentary editing will be source-text-with-live-preview (a
  native `NSTextView`/`TextEditor` for the raw Markdown source, feeding the
  WKWebView preview on change) rather than in-place WYSIWYG editing of the
  rendered view. This sidesteps `contenteditable` + HTML↔Markdown round-tripping,
  which is where WKWebView would otherwise be a real liability. If in-place
  WYSIWYG editing is wanted later, revisit this ADR.
- Vim-style scroll keys are implemented via JS (`window.scrollBy` /
  `scroll-behavior: smooth`) rather than native `NSScrollView` handling.
- Loading is `loadFileURL(_:allowingReadAccessTo:)`, not the more obvious
  `loadHTMLString(_:baseURL:)`: WebKit gives every `file://` resource its own
  origin, and a plain `baseURL` only resolves relative URLs — it doesn't
  grant read access to what they point at, so CSS/JS referenced from a
  `loadHTMLString`-loaded page silently fail to apply (confirmed by testing:
  `SecurityError: Not allowed to access cross-origin stylesheet`). Only
  `loadFileURL` actually grants that access, but it requires the loaded
  document itself to be a real file within the granted directory — so
  `MarkdownWebView` loads one static shell (`Resources/page.html`) per
  `WKWebView` and pushes content updates via `evaluateJavaScript` instead of
  reloading (see `MarkdownWebViewState` and the README). Any future
  Mermaid/PlantUML embedding will hit this exact same constraint.

## Amendments

### 2026-08-13 — editing is a permanent non-goal

The "planned future rudimentary editing" consequence above is **superseded**.
Folium is a viewer, permanently; see [`CONTEXT.md`](../../CONTEXT.md). Live
reload beside the user's real editor is the workflow instead.

This does not change the decision. It does change one stated reason: the
argument for pushing content via `evaluateJavaScript` rather than reloading the
shell was partly that editing would re-render on every keystroke. Live reload
alone still justifies it — a reload would re-parse every stylesheet and
re-parse/recompile all of highlight.js on every file change.

Reopening editing requires a new ADR, which would also have to revisit this
one: source-with-live-preview was the shape that made WKWebView tolerable for
editing, and in-place WYSIWYG remains a genuine liability here.

### 2026-09-10 — a second shell, loaded once, for the remote-content opt-in

The consequence above — one static shell per `WKWebView`, content pushed by
`evaluateJavaScript` instead of reloading — is **amended**, not superseded.
Content updates are still injections, always. But a document whose user opts
into remote content (issue #19) loads a second shell, `page-remote.html`,
whose Content-Security-Policy admits remote images. A `<meta>` CSP is fixed
once parsed, so there is no way to relax the loaded page's policy in place.

See [ADR 0008](0008-remote-content-opt-in-via-a-second-shell.md) for the
options weighed and the cost accepted.

### 2026-08-13 — PlantUML dropped; Mermaid lazy-loaded

The claim above that Mermaid and PlantUML are alike "JS libraries that render
to SVG in a DOM — trivial to embed in a web view" is **wrong about PlantUML**.
PlantUML is a Java program. Rendering it requires a remote server (which would
violate the no-network floor, and would ship the user's private diagrams to a
third party), a bundled JVM, or a user-installed binary. It is now a stated
non-goal.

Mermaid remains planned, but **lazy-loaded**: it is fetched from the bundle and
parsed only for documents that actually contain a `mermaid` fence, so
diagram-free documents pay nothing. Its full distribution is roughly an order
of magnitude larger than the 127 KB highlight.js bundle, which the latency
priority will not absorb unconditionally.

The decision to use WKWebView stands, but with diagrams reduced to Mermaid
alone, its strongest remaining justification is GitHub-quality code-block
rendering and the ability to reuse existing JS highlighters.
