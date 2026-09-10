# Folium

A native macOS Markdown viewer. Open a `.md` file and Folium renders it in a
tabbed window using a `WKWebView` (see [`docs/adr/`](docs/adr/) for the design
decisions behind the app).

## Requirements

- macOS 14 (Sonoma) or later
- Swift toolchain with the Swift Package Manager (`swift build`), from Xcode 16
  or the matching Command Line Tools
- Xcode itself — installed and selected (`xcode-select -p`) — to run
  `make bundle` / `make install`, which build universal (see below). The
  Command Line Tools alone cover everything else, including `make check`.

## Install from source

From a clean checkout:

```sh
make install
```

This builds a universal release binary (`swift build -c release --arch arm64
--arch x86_64`, so one bundle runs natively on both Apple Silicon and Intel
Macs), assembles a `Folium.app` bundle with its `Info.plist` and app icon,
ad-hoc signs it so it launches without Gatekeeper complaints on the machine
that built it, and copies it to `/Applications`.

Only the packaged build is universal. `swift build` / `swift test` /
`swift run` stay single-architecture, so the development loop doesn't pay for
compiling everything twice. Asking for two architectures also hands the build
to Xcode's build system, which is why the packaged build needs Xcode installed
and selected — see [ADR 0002](docs/adr/0002-spm-build-system.md)'s amendment.

Launch it from Spotlight, Launchpad, or:

```sh
open /Applications/Folium.app
```

### The version in the bundle

`make bundle` and `make install` stamp a version into the assembled bundle's
`Info.plist`, which is where Finder's Get Info and the About box read it from:

```sh
make install VERSION=1.2.0
# or from the environment:
VERSION=1.2.0 make install
```

With no `VERSION`, the bundle carries `0.0.0-dev`. `packaging/Info.plist` is a
template: the stamping happens on the copy inside the bundle, so a build never
modifies the checkout.

The build number (`CFBundleVersion`, which macOS compares between two copies of
the same app) comes from the commit count. Counting needs the whole history, so
build from a full clone — in a shallow one every build gets the same number, and
`make bundle` says so. `BUILD_NUM=` overrides it where that isn't possible.

### Other make targets

- `make bundle` — build and assemble `Folium.app` under `.build/` without
  installing.
- `make verify-bundle` — check that the assembled bundle is shippable (see
  [below](#the-shippability-gate)).
- `make uninstall` — remove `/Applications/Folium.app`.
- `make clean` — remove build artifacts and the local bundle.

## Development

### The rendered page: a real webpage, not an inlined string

`MarkdownWebView` loads a static shell (`Sources/Folium/Resources/page.html`)
once per `WKWebView` via `loadFileURL(_:allowingReadAccessTo:)`, and the
shell references its CSS/JS with ordinary `<link>`/`<script src>` URLs —
the way any webpage loads its assets — rather than inlining their content
into a Swift string. Every Markdown file open/change after that first load
is a `window.FoliumRenderBody(...)` call via `evaluateJavaScript`
(`MarkdownPage.renderBodyScript`, driven by `MarkdownWebViewState`), not a
page reload: a reload would re-parse every stylesheet and re-parse/recompile
all of highlight.js on every single change, which matters because live reload
(see [issue #7](https://github.com/telday/markdown-viewer/issues/7)) makes that
happen on every save while the user edits in another app — against a 100 ms
repaint budget (see [`CONTEXT.md`](CONTEXT.md)).

`loadHTMLString(_:baseURL:)` — the more obvious-looking API — does **not**
work for this: WebKit gives every `file://` resource its own origin, and a
plain `baseURL` only resolves relative URLs, it doesn't grant read access to
what they point at (confirmed by testing: referencing a sibling local CSS
file throws `SecurityError: Not allowed to access cross-origin stylesheet`
and the styles silently don't apply). `loadFileURL` is the API that actually
grants that access.

Two kinds of asset, handled differently:

- **Third-party, vendored**: highlight.js (see
  [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)), so there's no CDN
  dependency at runtime. The actual files aren't committed: `make vendor` — a
  prerequisite of `build`/`vet`/`test-unit`/`test-integration`/`coverage`, so
  `make build` and `make check` handle it automatically — regenerates
  `Sources/Folium/Vendor/` from the pinned version in
  [`vendor/package.json`](vendor/package.json) (a real npm manifest Dependabot
  tracks for version bumps and security advisories). Requires `npm` (e.g.
  `brew install node`), but only hits the network on the first run or after a
  version bump; otherwise it's a no-op.
- **First-party, authored here**: the shell itself, the base GitHub-matching
  stylesheet, the code-block chrome, and the copy-button script live as
  ordinary committed files under `Sources/Folium/Resources/` — no build
  step, just real CSS/JS/HTML editor tooling instead of Swift string
  literals.

Both are declared as `.copy` resources in `Package.swift`, so they exist as
real files in the app's resource bundle at runtime — nothing reads their
contents into a Swift `String`.

**A bare `swift build` / `swift test` / `swift run` (bypassing `make`) needs
`make vendor` run at least once first**, since the vendored (not first-party)
resource files won't exist yet.

**`make bundle`/`make install` copy both sets of files into
`Contents/Resources/` before code-signing**, at the same relative paths SPM's
generated bundle uses (`Resources/page.html`, `HighlightJS/…`), so the
signature seals them: `ls` on the assembled `.app` shows `Contents` and
nothing else, and `codesign --verify --strict` passes. The app finds them
through its own `Bundle.main.resourceURL` (`MarkdownPage.resourceBaseURL`),
which is why `Folium.app` runs correctly after being dragged to
`/Applications` or onto a machine that never built it. The copy comes from the
source tree rather than from SPM's generated bundle, so the `.app` doesn't
inherit whichever name and layout the SPM build system in use produces.

`Bundle.module` is the fallback, used only by `swift run`/`swift test`, which
assemble no `.app`. Don't make it the primary: its accessor resolves the
resource bundle as a sibling of the `.app`, which puts resources at the bundle
root — where `codesign` refuses to seal them (see ADR 0003).

**The app icon is committed as PNGs, not as an `.icns`.** `packaging/Folium.iconset/`
holds the ten sizes macOS asks for and `packaging/Folium.svg` is the vector
master; `make bundle` runs `iconutil` to pack them into
`Contents/Resources/Folium.icns`. To change the icon, re-export the PNGs from
the SVG — the `.icns` is a build artifact and reviewing a binary blob is not.

### Quality gates

`make check` runs the four gates that make up the Definition of Done for any
code change (see [`docs/agents/definition-of-done.md`](docs/agents/definition-of-done.md)):

- `make lint` — SwiftLint (`--strict`); requires `brew install swiftlint`.
- `make vet` — compiles all targets with warnings treated as errors (the Swift
  equivalent of `go vet`).
- `make test-unit` — fast, isolated unit tests.
- `make test-integration` — end-to-end file-to-render pipeline tests.
- `make coverage` — enforces ≥97% unit-test line coverage on the logic layer
  (UI/host-glue files are excluded and listed on every run).

CI runs `make check` on every pull request (`.github/workflows/ci.yml`).

### The shippability gate

`make check` says the *code* is good. `make verify-bundle` says the *artifact*
is: it takes an assembled bundle and asserts what a user (and, eventually,
Apple's notary service) would see.

```sh
make bundle && make verify-bundle
# or against a bundle stamped with a specific version:
make bundle verify-bundle VERSION=1.2.0
```

It checks that every first-party and vendored asset is at the path the app
resolves it from, that **nothing sits at the bundle root except `Contents/`**
(codesign refuses to seal files there, so anything else ships unsigned),
that `codesign --verify --strict --deep` passes, that the executable carries
both `arm64` and `x86_64`, and that the `Info.plist` claims the identifier,
executable, document type, and version it should. It prints each check and
stops at the first failure. Assertions that need a Developer ID — hardened
runtime, notarization — are skipped on an ad-hoc signature, so the gate is
useful on a contributor's machine today (see
[issue #31](https://github.com/telday/markdown-viewer/issues/31)).

It builds nothing: run `make bundle` first. Verifying a bundle older than
`Sources/`, `packaging/`, or the `Makefile` fails rather than reporting on a
stale artifact. Pointed at a bundle from outside the checkout — `/Applications`,
a downloaded release — it skips the two checks that compare against this
checkout's sources and verifies the artifact on its own contents.

**It is deliberately not part of `make check`**, which stays the fast
code-change loop and never builds a release bundle. CI runs
`make bundle && make verify-bundle` as its own step on every pull request.

## License

Folium is released under the [MIT License](LICENSE).

The third-party code that ships inside the app bundle — highlight.js and
cmark-gfm, both permissive and attribution-only — is recorded with its
copyright notices in [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

## Versioning

Versions are semantic, applied to **user-visible behavior** rather than to the
source tree — a refactor nobody can see moves no version component. Releases
are cut when there is a reason to install one, rather than on a schedule.
[ADR 0010](docs/adr/0010-semantic-versioning-against-user-visible-behavior.md)
has the rest: which component moves when, what the first public version is, and
what gates a `1.0.0`.
