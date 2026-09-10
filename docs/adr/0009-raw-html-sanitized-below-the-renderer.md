---
status: accepted
---

# Raw HTML in a document renders, and is made safe below the renderer rather than filtered at the parser

Issue #20. `MarkdownRenderer` renders with `CMARK_OPT_UNSAFE`, so raw HTML in
a Markdown file reaches the page as written. Nothing filters it on the way
there. What makes it harmless is the layer underneath: the page shell's
Content-Security-Policy (issue #17) and `NavigationPolicy`, both of which
refuse *behaviour* without deleting *content*.

## Why the default was wrong

Since cmark 0.29 safe mode is the default and `CMARK_OPT_SAFE` "no longer has
any effect" (`cmark-gfm.h`). `CMARK_OPT_DEFAULT` therefore replaced every raw
HTML span and block with an invisible `<!-- raw HTML omitted -->`. Measured
against this app's own renderer, that meant:

| Input | Was |
| --- | --- |
| `<p align="center">` + `<img>` | gone — the whole block |
| `<a name="install"></a>` | gone; every link to `#install` broke |
| `<details><summary>` | summary gone, body permanently expanded |
| `line one<br>line two` | `line oneline two` — two words joined into one |
| `H<sub>2</sub>O`, `<kbd>K</kbd>`, `<b>` | flattened to text |

This was never a decision, just an unexamined default, and it violated
`CONTEXT.md`'s first floor — the document says what the file says — in its
worst form: silently, with nothing on screen to say anything was missing. The
centred-logo / badge-row / collapsible-section trio is the opening screen of
most repo READMEs.

## The bargain

Rendering raw HTML means a document is arbitrary HTML, from a file the user
may not have written. The safety question does not go away; it moves. The
claim of this ADR is that it moves somewhere better:

- **The CSP refuses capability, not markup.** `script-src file:` admits no
  inline script, no event-handler attribute and no `javascript:` URL;
  `default-src 'none'` covers frames, objects and fonts; `img-src`/`media-src`
  admit only the local schemes. None of that cares which tag asked, so it does
  not have to be kept in step with HTML.
- **What survives is exactly the visible part.** A `<details>` still collapses,
  a `<kbd>` still draws, an `<img>` still loads — because CSP has no opinion
  about layout.

`CMARK_OPT_UNSAFE` also re-permits `javascript:` (and `data:`, `file:`) in
**plain Markdown link syntax**, not only in raw HTML. That is not a side
effect to be tolerated; it is the same bargain applied to the other syntax,
and it is covered by the same CSP directive.

## Considered options

**A hand-maintained allowlist replicating GitHub's sanitizer** — rejected.
Defence in depth, but it is a second definition of "safe" to maintain, it
drifts from GitHub's as GitHub's changes, and every gap in it is a piece of a
user's document silently deleted. The failure mode of the chosen option is a
tag that renders inertly; the failure mode of an allowlist is content that
vanishes — the floor-1 failure this change exists to end.

**DOMPurify or a similar JS sanitizer in the shell** — rejected for the same
reason plus a dependency, a parse of the whole body on every render (against
priority 2), and a third party's idea of the policy in place of the engine's.

**Leaving safe mode on and special-casing the popular tags** — rejected. It is
the allowlist above with a smaller list and the same drift.

## What the CSP does not cover, and what was done about it

Two vectors survive a policy built entirely out of fetch directives, because
neither is a fetch. Both were measured against a real `WKWebView` before being
closed, not reasoned about:

- **`<meta http-equiv="refresh">`.** Injected into the body, WebKit really does
  act on it, and it arrived at `decidePolicyFor` as a *non-link* activation —
  where `NavigationPolicy` was handing any `http(s)` URL to
  `NSWorkspace.open`. A document could therefore open the user's browser at a
  URL of its choosing simply by being opened. The policy now requires a click
  before it will hand a URL to another application at all: that covers
  `.openInBrowser` and, for the same reason, `.openDocument` — a meta refresh
  naming a `folium-doc:` URL would otherwise have opened a sibling `.md`
  unprompted. Both are gated in one place, so a submitted form or a scripted
  `window.location` is covered by construction rather than by a second copy of
  the check. This amends the policy issue #17 established; it is not a new
  mechanism.
- **`<link rel="dns-prefetch">`.** Not governed by any CSP directive. Left as
  is: WebKit's DNS prefetching is off unless a client turns it on, and
  `MarkdownWebView` does not. Recorded here because "the CSP covers it" is not
  the reason.

`javascript:` URLs are worth a note of their own. `NavigationPolicy` has a case
for them and it reads like the guard, but it never runs: WebKit evaluates a
clicked `javascript:` URL without consulting `decidePolicyFor` at all. Removing
the CSP `<meta>` turns `RawHTMLSafetyTests`'s test red. The CSP is not the belt here;
it is the only strap.

## Consequences

- **The shell's CSP is now load-bearing for document safety**, not only for the
  no-network floor. Weakening `script-src` — to allow an inline style, say —
  would hand a document arbitrary code execution. Both shells' CSP tags carry
  this warning.
- **`<style>` blocks and `style=` attributes in a document do not apply.**
  `style-src file:` refuses inline CSS, so a document that styles itself
  renders unstyled rather than styled its own way. A visible, contained
  fidelity gap against priority 3, and the price of the point above; widening
  `style-src` to `'unsafe-inline'` is not a trade this project should take
  without an ADR of its own.
- **`DocumentRelativeLinks` no longer sees only cmark-gfm's output.** Raw HTML
  quotes attributes however its author felt like, so the rewriter learned the
  single-quoted form. Unquoted values, and a `src=`/`href=` lookalike inside
  another attribute's value, stay unresolved — visibly broken, never silently
  wrong. Reaching those means rewriting against a real HTML parse instead of a
  pattern, which is a different design from [ADR 0007](0007-document-resources-via-url-scheme.md)'s.
- **`Resources/github.css` grew its first rules for elements Markdown syntax
  cannot produce** (`kbd`, `summary`). Expect more of these as documents in the
  wild exercise tags the stylesheet has never had to style.
- **`<a name="install"></a>` needed a second half.** Rendering the element is
  not what the reader wanted; a working `#install` link is. `FoliumScrollToAnchor`
  looked targets up by `id` only, so the anchor arrived inert. It now falls back
  to `getElementsByName`. Heading `id`s remain the separate gap they were —
  cmark-gfm emits none, and no fallback can invent an id nothing wrote.
- **Remote media became expressible, and is not yet offered.** A
  `<video src="https://…">` is blocked and raises no opt-in bar, because
  `page-remote.html` still relaxes `img-src` alone (ADR 0008). Not a
  regression — the tag used to be deleted outright — but it is the gap issue
  #49 exists to close.

## Latency

Per `CONTEXT.md` priority 2, which requires any change touching the render path
to state its impact and run `make bench`. Measured on the same machine, one run
each, against `scripts/make-bench-fixture.sh`'s fixture:

| | Baseline (049d923) | With this change | Δ |
| --- | --- | --- | --- |
| Cold launch → first paint | 1120 ms | 1113 ms | −7 |
| Warm open → painted | 544 ms | 534 ms | −10 |
| Live-reload → repainted | 327 ms | 314 ms | −13 |
| Tab switch | 51 ms | 63 ms | +12 |
| Markdown → HTML render | 15 ms | 14 ms | −1 |
| Scrolling | 0/179 dropped @ 63 Hz | 0/179 dropped @ 63 Hz | — |

The render figure is read from the marker dump (`BENCH_DUMP=…  make bench`)
rather than off the summary, which prints `0 ms`: `scripts/bench.sh` takes the
first `render` report of the run, and on some launches that is an empty
document rendering in 61 µs rather than the fixture. A reporting bug in the
harness, not a measurement of anything — issue #50.

Mixed in sign and small against single-run wall-clock noise: this shows
nothing moved by a large margin, not that anything improved. Expected —
`CMARK_OPT_UNSAFE` changes what `cmark_render_html` writes for a raw-HTML
node, not how much work it does, and the fixture is generated Markdown with
no raw HTML in it at all, so the render number is measuring the same work
either way. The same four budgets are over on both sides; issue #48 owns
that.
