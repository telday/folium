---
status: accepted
---

# The remote-content opt-in swaps in a second page shell, rather than relaxing the policy of the one already loaded

Issue #19 asks for a per-document opt-in to remote content that the CSP
(issue #17) blocks by default. Folium ships **two** page shells —
`Resources/page.html` and `Resources/page-remote.html` — identical but for
their Content-Security-Policy `<meta>` tag, and opting a document in loads
the second in place of the first.

This **amends [ADR 0001](0001-wkwebview-rendering.md)**, whose consequence
reads: "`MarkdownWebView` loads one static shell (`Resources/page.html`) per
`WKWebView` and pushes content updates via `evaluateJavaScript` instead of
reloading." That still governs every *content* update. What changes is that a
shell is no longer loaded exactly once per web view: a document whose user
takes the offer loads a second one, once. `CONTEXT.md`'s glossary entry for
**Page shell** is amended to match.

## Why the policy cannot be relaxed in place

A CSP delivered by `<meta>` is fixed from the moment the parser reads the tag.
Removing or rewriting the element afterwards does nothing, and a second
`<meta>` policy can only *intersect* with the first — policies compose by
taking the most restrictive, so no in-page edit can ever widen one. Whatever
grants the relaxed policy therefore has to be a fresh document load.

## Considered options

**A second shell file, reloaded on opt-in (chosen).** Keeps CSP as the single
enforcement mechanism, which is what `CONTEXT.md`'s no-network floor names:
"Enforced by Content-Security-Policy in the page shell, not by convention.
Convention is not a guarantee; CSP is."

The real cost is two near-identical files kept in step by hand. Anything added
to one and not the other would work for every document until its user clicked
"Load", and then quietly stop. `MarkdownPageTests
.theTwoShellsDifferOnlyInTheirContentSecurityPolicy` compares them line by
line and names the line that drifted; that guard is what makes this option
acceptable rather than merely convenient. It is not optional maintenance.

**`WKContentRuleList` instead of CSP.** A content-blocker rule list can be
added to and removed from a live web view's user content controller with no
reload at all, which would make the opt-in instant. Rejected: it moves
enforcement of the no-network floor off CSP and onto a second, WebKit-specific
mechanism, and the floor names CSP specifically. Reopening this means
reopening the floor, not just this ADR.

**`loadSimulatedRequest(_:response:responseHTML:)`**, which can carry a real
`Content-Security-Policy` *header* and so would need only one shell file.
Rejected: it does not grant the page read access to sibling files the way
`loadFileURL` does, which ADR 0001 established is the only API that will —
the shell's own CSS and JS would stop loading.

**Generating the second shell at runtime** into a temporary directory, from
the first. Rejected: the shell's assets are referenced by relative URL
(`github.css`, `../HighlightJS/…`), so they would have to exist beside the
generated copy, and the bundle's own copies cannot be written next to it — a
signed `.app` in `/Applications` is read-only.

## Consequences

- **The opt-in costs a full shell reload**, which re-parses every stylesheet
  and re-parses/recompiles all of highlight.js — precisely the cost ADR 0001's
  2026-08-13 amendment cites as the reason content updates are injected rather
  than reloaded. Paid at most once per document, on an explicit click, because
  `RemoteContentState.allow()` is one-way. `MarkdownWebViewState` re-queues
  the body across the swap so the document is restored into the new shell
  rather than lost.
- **`NavigationPolicy` treats either shell as "the shell"** (`MarkdownPage
  .shellURLs`). Comparing against whichever one is loaded right now would be
  one more thing to keep in step with the swap; an in-page anchor link has to
  keep scrolling on both sides of it.
- **Only `img-src` is relaxed** — never `script-src` or `style-src`. Nothing a
  document references is executed or cascaded as code, opt-in or not.
  `RemoteContent.isLoadable` therefore refuses to raise the offer for a
  blocked remote stylesheet: an offer that does nothing when taken is worse
  than no offer.
- **Both `http:` and `https:` are admitted** once the user opts in. "Load"
  means this document's remote references may load; a shell that kept
  refusing the cleartext half would leave those images missing with the offer
  already dismissed and no way to ask again — the silent omission the feature
  exists to prevent.

## Latency

Per `CONTEXT.md` priority 2, which requires any change touching the render
path to state its impact and run `make bench`. Measured on the same machine,
one run each, against `scripts/make-bench-fixture.sh`'s fixture:

| | Baseline (16149b3) | With this change | Δ |
| --- | --- | --- | --- |
| Cold launch → first paint | 1066 ms | 945 ms | −121 |
| Warm open → painted | 550 ms | 516 ms | −34 |
| Live-reload → repainted | 292 ms | 306 ms | +14 |
| Tab switch | 60 ms | 63 ms | +3 |
| Markdown → HTML render | 15 ms | 14 ms | −1 |
| Scrolling | 0/179 dropped @ 67 Hz | 0/179 dropped @ 67 Hz | — |

Mixed in sign and small against single-run wall-clock noise: this shows
nothing moved by a large margin, not that anything improved. The same four
budgets are over on both sides — see issue #48, which owns that.

What the change adds to the render path is one `postMessage` to native per
render, from `FoliumRenderBody`. What it removes is larger and was a bug:
`MarkdownWebViewState.render` re-injected the body on *every* `updateNSView`,
without checking whether it had changed. Combined with `@Published`
announcing assignments rather than changes, that formed a loop — the page
reported on every render, the report was state the view observed, and
observing it scheduled another render. Measured at **8,924 injections in 6 s**
for a document with remote content and **59,288 in 6 s** for one without,
before the guards; one injection each afterwards.
