---
status: accepted
---

# Distribute directly (Homebrew), not through the App Store — run unsandboxed

The app is planned to ship via Homebrew (a Cask, once there's a signed/
notarized release artifact), with `make install` from source as the v1 path,
rather than through the Mac App Store. Given that, the app runs outside the
App Sandbox.

## Considered options

- **App Sandbox** — rejected for now. The app doesn't need App Store
  distribution's constraints, and this is a local Markdown file viewer, not a
  process handling untrusted network content — the usual case for wanting
  sandboxing's blast-radius reduction is weaker here. Sandboxing would also
  require security-scoped bookmarks for every file opened via the Open
  dialog, drag-and-drop, or Recent Documents, plus care around how a
  `WKWebView` loads local resources (relative image/link paths from a
  Markdown file) under sandbox restrictions — real plumbing for a benefit
  that's unclear in this threat model.

## Consequences

- This forecloses a clean App Store submission later without revisiting this
  decision (sandboxing would need to be added retroactively).
- Homebrew Cask distribution doesn't require sandboxing, but will eventually
  need Developer ID code signing + notarization for the app to launch
  cleanly under Gatekeeper once it's downloaded rather than built locally
  from source (locally-built binaries aren't quarantined, so this isn't
  blocking the v1 `make install` path).

## Amendments

### 2026-08-16 — the bundle is sealable: resources live in `Contents/Resources`

The second consequence above — that Developer ID signing and notarization are
eventually needed — was until now blocked by a compromise in `make bundle`.
It copied the resource bundle the Swift Package Manager (SPM) generates,
`Folium_Folium.bundle`, to the `.app`'s *root*, after `codesign` ran. SPM's
generated `Bundle.module` accessor resolves that bundle as a sibling of
`Bundle.main.bundleURL`; its only other candidate is an absolute `.build` path
on the build machine. `codesign` refuses to sign a
bundle with anything outside `Contents/` at its root, so the copy had to come
last, and `codesign --verify --strict` reported the result as unsealed.

`make bundle` now copies the first-party and vendored assets from the source
tree into `Contents/Resources/` before signing, and the app resolves them
against its own `Bundle.main.resourceURL` rather than `Bundle.module`
(`MarkdownPage.resourceBaseURL`). The signature seals every resource, `ls` on
the `.app` shows `Contents` and nothing else, and the bundle launches wherever
it is copied to.

**Do not "simplify" the resource lookup back to `Bundle.module`.** It is not
a redundant indirection: it is what keeps the resources inside `Contents/`,
and therefore what makes the bundle signable at all. `Bundle.module` remains
the fallback only for `swift run`/`swift test`, which assemble no `.app`.

### 2026-08-13 — "relative links/images work simply and directly" is not yet true

The rejected-options section argues that sandboxing would require "care around
how a `WKWebView` loads local resources (relative image/link paths from a
Markdown file)". Being unsandboxed is necessary for that to work, but it is not
sufficient, and it does not work today: `MarkdownWebView` calls
`loadFileURL(_:allowingReadAccessTo:)` with `MarkdownPage.resourceBaseURL` —
the app's own resource bundle — so a page has no read access to the opened
document's directory. `![](./screenshot.png)` next to the document renders as a
broken image.

Fixing it means widening the read-access grant to the document's directory,
which also widens what any script injected via a malicious document could
reach. That interacts directly with the no-network floor and the
Content-Security-Policy work in [`CONTEXT.md`](../../CONTEXT.md): CSP has to be
in force before the grant is widened. Tracked as its own issue.

This does not change the decision — unsandboxed remains the right call, and
sandboxing would make the fix strictly harder (security-scoped bookmarks per
document).

### 2026-08-22 — fixed, but not by widening the grant

The paragraph above predicted the fix correctly needed CSP in force first,
but guessed wrong about the shape of the fix itself: widening the grant
turned out to be impossible, not just risky. `loadFileURL` requires the
loaded shell to sit inside the granted directory, the shell lives inside
`Folium.app/Contents/Resources`, and a document can be anywhere under the
user's home folder — there is no single directory a real installation could
grant that contains both. See
[ADR 0007](0007-document-resources-via-url-scheme.md) for the fix that
shipped instead: a private `folium-doc:` URL scheme, handled entirely in the
app's own (still unsandboxed) process, so the web content process never
receives a directory grant at all.
