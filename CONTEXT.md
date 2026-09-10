# Folium — Context

Read this before making changes. It records **what Folium is for and what it
optimizes for**, so that decisions an issue doesn't explicitly cover can still
be made the way the project would make them.

The [ADRs](docs/adr/) record *what was decided*. The [issues](docs/agents/issue-tracker.md)
record *what to build*. This file records **what to optimize for when those two
conflict** — or when neither says anything.

## What Folium is

A native macOS viewer for Markdown files.

**For:** developers and technical writers on macOS, reading repo-resident
Markdown — READMEs, ADRs, design docs, specs, agent output. They already know
what GitHub's rendering looks like, they live in an editor and a terminal, and
they are comfortable with `brew`.

**This is a public product**, not a personal tool. Strangers' needs count when
breaking ties: edge-case documents, accessibility, error states, and migration
paths are real considerations, not hypotheticals.

**Why someone switches to it:** it is a real Mac app, not a browser in a window.
Plenty of tools render GFM adequately for free. None of them feel like a Mac
app. That is the wedge.

**The central tension of the product** is native-citizen versus
speed-and-lightness. Expect to keep resolving it; it does not go away.

## The floors

Not priorities — floors. They are not weighed against anything. A change that
breaks one is wrong no matter what it wins.

### 1. The document says what the file says

Folium's only job is showing a file's content faithfully. Silently dropping
content, showing wrong content, or crashing on valid input is the one
unforgivable class of failure. When rendering cannot be faithful, **fail
visibly** — never silently omit.

> Raw HTML is part of what a Markdown file says, so it renders
> (`CMARK_OPT_UNSAFE`, [ADR 0009](docs/adr/0009-raw-html-sanitized-below-the-renderer.md)).
> Filtering it at the parser would silently drop centered logos, badge rows,
> HTML tables and `<a name>` anchors, and render `<details>` permanently
> expanded — so the filtering happens below the renderer instead, where it
> can refuse *behaviour* without deleting *content*.

### 2. No network

**Folium originates no network requests.** Everything it needs ships in the app
bundle. This is a promise to a user reading confidential specs and internal
docs, and it is why highlight.js is vendored rather than pulled from a CDN.

- Enforced by Content-Security-Policy in the page shell, not by convention.
  Convention is not a guarantee; CSP is.
- Document-referenced remote content (`![](https://…)`) is blocked by default,
  with a visible per-document opt-in — the mail-client pattern.
- External links open in the user's default browser. They never navigate the
  web view, which would both leak a request and destroy the user's document
  view.
- No telemetry. No crash reporting. No update checks — Homebrew handles updates.

**Rule for review:** no code path may originate a network request.

### 3. The gates pass

[`make check`](docs/agents/definition-of-done.md) — lint, vet, unit tests,
integration tests, ≥97% logic-layer coverage. Never disabled, never skipped to
land a change.

Excluding a file from unit coverage **obliges** covering its behavior in
`FoliumIntegrationTests`. "Not unit-testable" must never come to mean
"untested" — the AppKit↔WebKit seam is where the bugs actually are.

## The priorities

Ordered. When two collide, **the higher one wins**.

### 1. Native Mac citizen

**No standard system affordance is missing or faked.** If macOS taught the user
a gesture, it works here, through the real system mechanism — not a lookalike
we drew.

That covers: window tabs (drag to reorder, drag out, Mission Control), ⌘F Find,
⌘P print, text zoom (⌘+/⌘−/⌘0), Services, Look Up, the Share menu, VoiceOver
and accessibility, state restoration including scroll position, system
appearance, and standard keyboard navigation.

- **Never reimplement what AppKit provides.** This is the general law behind
  ADR 0004's specific rejection of a custom tab strip.
- Accept the cost: a steady stream of unglamorous bridging work across the
  AppKit↔WebKit seam, most of it landing in coverage-excluded glue files. A
  `WKWebView` document is not natively a document; every affordance above has
  to be deliberately wired up.
- Reject custom UI that would be easier to build than its native equivalent.

### 2. Perceived latency

"Light" means **it responds instantly**, not that it wins a memory contest —
ADR 0001 already bought WebKit's multi-process footprint, and that is accepted.
What Folium owns absolutely is latency.

| Moment | Budget |
| --- | --- |
| Cold launch → first document painted | ≤ 500 ms |
| Warm open (app already running) → painted | ≤ 150 ms |
| Live-reload: file written → repainted | ≤ 100 ms |
| Tab switch | ≤ 50 ms, no re-render |
| Scrolling | no dropped frames, including 120 Hz ProMotion |

These are **binding design constraints**, not aspirations.

- Measured by `make bench` on real hardware, against the large-document
  fixture `scripts/make-bench-fixture.sh` generates — deterministically, so
  runs stay comparable, but regenerated rather than committed because the
  live-reload probe has to write to it. Wall-clock gates on shared CI runners
  measure noise, so CI records the numbers as an informational trend rather
  than failing on them.
- Any change touching the render path states its latency impact and runs
  `make bench`.
- Knowingly exceeding a budget requires an ADR. Not a shrug.
- The table says what the app owes, not what it does today: as of the first
  run of `make bench`, four of the five are over — see issue #48. Scrolling
  is the one within budget, and only at 63 Hz; the ProMotion half is
  untested.

### 3. GitHub fidelity, inside the document

**GitHub governs the document; macOS governs everything around it.**

- Inside the rendered body, GitHub's rendering is the contract. A user should
  never be surprised by what github.com does with the same file.
- Outside it — window, tabs, menus, scrollbars, selection highlight, find
  highlighting, context menus, dialogs — the system wins, always.
- **Semantic fidelity outranks pixel fidelity.** That GFM behaves the way
  GitHub behaves (tables, task lists, autolinks, raw-HTML handling) matters far
  more than matching an exact spacing value. This is also why
  [`testing.md`](docs/agents/testing.md) tells you to assert the seam, not
  upstream's values.

### 4. Scope restraint

The app grows toward completeness on OS integration and **stays flat on
invented features**.

- Heavy renderers **lazy-load or don't ship**. Mermaid loads only for documents
  that actually contain a `mermaid` fence; a document without one pays nothing —
  no download, no parse, no memory. Same rule for anything similar later.
- Configuration covers **input and behavior only** — keybindings, scroll
  behavior, remote-content policy. Document appearance is not configurable.
- Prefer deleting a feature to adding a preference that makes it optional.

## How to use this

The single sentence that resolves most arguments:

> **The app grows toward completeness on OS integration, and stays flat on
> invented features.**

Priorities 1 and 4 are the pair that actually fight, and the order settles it:

- *"⌘F doesn't work."* → Priority 1 beats 4. Build it, even though it's scope.
- *"Users want a theme picker."* → Priority 4 wins. It's an invented feature,
  and it dilutes priority 3's contract.
- *"State restoration costs us 80 ms of launch time."* → Priority 1 beats 2.
  Pay it, and note the budget impact.
- *"Matching GitHub's exact font stack costs a webfont load."* → Priority 2
  beats 3, and the network floor forbids the load outright.
- *"This custom scroll view feels nicer than NSScrollView."* → Priority 1.
  Never reimplement what AppKit provides.

When a change contradicts an ADR, **say so explicitly** rather than silently
overriding it — and if it contradicts this file, that is a conversation to have
before writing the code, not after.

## Non-goals

Stated so they can be rejected quickly and without re-litigation:

- **Editing, of any kind.** Folium is a viewer, permanently. Live-reload plus
  the user's real editor is the workflow; a built-in editor would be a worse
  version of the one they already have, and under priority 1 it could not be
  "rudimentary" — it would owe undo, autosave, Versions, encoding handling,
  find-and-replace, and unsaved-state indication. Supersedes ADR 0001's
  editing consequence. Reopening requires a new ADR.
- **PlantUML.** It is a Java program, not a JS library. Rendering it needs a
  remote server (violates the network floor and ships private diagrams to a
  third party), a bundled JVM, or a user-installed binary. Corrects ADR 0001,
  which grouped it with Mermaid.
- **Themes, custom CSS, font pickers.** Priority 3 makes GitHub's rendering the
  contract, not a default. Text zoom is exempt — it is a system affordance
  under priority 1, not a theme.
- **Telemetry, analytics, crash reporting, update checks.** Network floor.
- **Notes/PKM features** — vaults, wikilinks, backlinks, a file-tree sidebar.
  Different product; would also break ADR 0004's one-window-per-document model.
- **App Store distribution and sandboxing.** See ADR 0003.

## Glossary

Use these terms; don't drift to synonyms.

- **Document** — one Markdown file open in Folium. One document per window/tab
  (ADR 0004).
- **Chrome** — everything outside the rendered document body: window, tabs,
  menus, scrollbars, dialogs. Governed by macOS, never by GitHub's stylesheet.
- **Page shell** — `Resources/page.html`, loaded per `WKWebView` via
  `loadFileURL`. Never reloaded to show new content; content updates are
  injections. A document whose user opts into remote content loads the
  second shell, `Resources/page-remote.html`, once — the only reload there
  is (ADR 0008).
- **Body HTML** — the rendered HTML for one document, injected into the shell
  by `window.FoliumRenderBody` via `evaluateJavaScript`. Content updates are
  injections, never reloads.
- **Logic layer** — plain types with no SwiftUI/AppKit/WebKit dependency.
  Coverage-gated at ≥97%.
- **Host glue** — the thin SwiftUI/AppKit/WebKit-dependent files. Excluded from
  unit coverage, and therefore obliged to have integration coverage.
- **Affordance** — a standard macOS behavior the user already expects. Priority
  1 is defined in terms of these.
- **Live-reload** — an open document re-reading and re-rendering itself when
  something else writes its file. Not "refresh": there is no refresh command,
  because there is nothing for one to do (ADR 0006).
- **Vendored asset** — third-party code committed as a real file in the bundle
  (highlight.js), never fetched at runtime.
- **Linked dependency** — third-party code compiled into the executable rather
  than shipped as a file beside it (cmark-gfm). Redistributed to users exactly
  as a vendored asset is, so its notice belongs in `THIRD_PARTY_LICENSES.md`
  too.
- **First-party asset** — CSS/JS/HTML authored here, living as real files under
  `Sources/Folium/Resources/`, never as Swift string literals.

## Open questions

Deliberately unresolved. Decide them when they come up — and record the answer
here or in an ADR.

- Preferences migration policy across versions.
- Which file extensions Folium claims (`.md`, `.markdown`, `.mdx`, `.txt`?).
- Behavior on very large documents, and on files that fail to decode.

Answered, and no longer open:

- *Versioning and release cadence.* Semantic versioning against user-visible
  behavior, released when there is a reason to install one — see
  [ADR 0010](docs/adr/0010-semantic-versioning-against-user-visible-behavior.md),
  which also names the first public version and what gates a `1.0.0`.
