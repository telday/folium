---
status: accepted
---

# Document-relative resources load through a private `folium-doc:` scheme, not a widened read-access grant

Issue #18 (`![](./screenshot.png)` rendering as a broken image) is fixed by
registering a `WKURLSchemeHandler` for a private scheme, `folium-doc:`, rather
than by widening `loadFileURL`'s `allowingReadAccessTo` grant to cover the
opened document's directory. `DocumentRelativeLinks` rewrites a
document-relative `src`/`href` to a `folium-doc://doc/<relative path>` URL;
`DocumentResourceSchemeHandler` — running in the app's own, unsandboxed
process (ADR 0003) — resolves that request against the document's directory
through `DocumentResourceResolver`, reads the file itself, and hands the bytes
back to the web content process. That process never receives a filesystem
read grant for the document's directory at all.

## The grant constraint that forces this

`loadFileURL(_:allowingReadAccessTo:)` requires the loaded document itself —
the page shell, `Resources/page.html` — to be a real file inside the granted
directory (ADR 0001). `MarkdownWebView` loads that shell from
`Folium.app/Contents/Resources`. Widening the grant to also cover an opened
document's directory therefore requires a single directory that contains
*both* the shell and the document.

In production there is no such directory: the shell lives inside the app
bundle, and a document can be anywhere under the user's home folder. Two
experiments against the real integration suite confirmed this is the actual
blocker, not a red herring:

- Widening the grant to a synthetic common ancestor of both paths made the
  sibling-image integration test pass in 0.27 s.
- Granting *only* the document's directory — leaving the shell itself outside
  the grant — made `loadFileURL` never fire `didFinish` at all; the shell
  failed to load and the test hung.

An earlier spike had claimed an out-of-grant `file://` image loads anyway.
That measurement was confounded: it ran in a temp tree where the shell and
the fixture both happened to sit under one root, which satisfied the grant
without the spike's author intending it to. Re-running it against the real
app bundle and a document elsewhere on disk reproduced the broken image
instead.

## Considered options

- **Widen the read-access grant to a common ancestor** — rejected for the
  reason above: no such ancestor exists once the app is actually installed
  and a document is opened from an arbitrary location. It would also hand
  the *entire* web content process — every script a malicious or merely
  buggy document's raw HTML could run, which issue #20 is about to allow —
  read access to a whole directory tree, not just the specific files
  `DocumentRelativeLinks` rewrote a reference to.
- **Inline referenced resources as `data:` URIs** — rejected. It bloats the
  rendered document itself against `CONTEXT.md` priority 2 (perceived
  latency): a document with several screenshots would re-encode and
  re-transmit their bytes into the DOM on every render, including live-reload
  re-renders that change nothing about the images. It also does nothing for
  a link to a sibling `.md` file, which isn't a resource to inline at all —
  issue #18 also has to cover that case.
- **A private URL scheme with a `WKURLSchemeHandler`** — adopted. The handler
  runs in the app's own process (already unsandboxed, ADR 0003), so it can
  read anything the app's user could read from Finder, without WebKit ever
  being told a directory is broadly readable. The set of files a document can
  actually reach becomes `DocumentResourceResolver`'s containment check —
  ordinary, unit-tested Swift — rather than a grant WebKit enforces on our
  behalf with no finer control than a whole directory.

## Consequences

- **Document resources now flow through code this app owns**, not through a
  WebKit-enforced grant. That is strictly more policy than a directory grant
  could express: `DocumentResourceResolver.fileURL(for:documentDirectory:)`
  canonicalises the request (`standardized`, `resolvingSymlinksInPath`) before
  checking containment, so both a literal `../../../etc/passwd` reference and
  a symlink inside the document's own directory that points outside it are
  refused — neither is visible in the request string until it's resolved.
  Only a plain regular file is ever served, never a directory. This matters
  more, not less, once issue #20 lets a document's raw HTML reach the DOM
  directly: the resource-reachability policy no longer has to trust the CSP
  and the navigation policy alone.
- **A document's resources are now scoped to its own directory and
  subdirectories.** A relative reference that walks upward with `..` past the
  document's own directory is rewritten by `DocumentRelativeLinks` exactly as
  before (it doesn't decide reachability), but `DocumentResourceResolver`
  refuses to serve anything the containment check finds outside that
  directory. This is a narrower guarantee than "any relative reference a
  browser could resolve," traded deliberately for not trusting an
  arbitrary, possibly-untrusted document with reads anywhere the grant
  allowed. It still satisfies `CONTEXT.md`'s first floor: a refused resource
  is a visibly broken image or dead link, never a silent omission.
- **One `WKURLSchemeHandler` per open document**, registered on that
  document's `WKWebViewConfiguration` before its `WKWebView` is created —
  `setURLSchemeHandler(_:forURLScheme:)` cannot be called afterwards. Each
  carries only that document's own directory, so one open document's handler
  cannot answer a request naming another document's files even though both
  run in the same, unsandboxed app process.
- **The CSP's `img-src`/`media-src` directives now also allow the
  `folium-doc:` scheme** (`Resources/page.html`), alongside the existing
  `file:` used for the shell's own bundled assets. `script-src`/`style-src`
  deliberately do not: nothing a rendered document references through this
  scheme is ever treated as code.
- `DocumentResourceSchemeHandler` cannot be unit-tested — `WKURLSchemeTask`
  only exists inside a live `WKWebView` — so it is excluded from the
  logic-layer coverage requirement (`scripts/coverage.sh`) and its behavior,
  including the traversal and symlink-escape refusals, is instead asserted
  end-to-end in `Tests/FoliumIntegrationTests/RelativePathTests.swift`.
