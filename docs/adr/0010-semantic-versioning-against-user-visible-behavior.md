---
status: accepted
---

# Semantic versioning against user-visible behavior, released when ready — starting at 0.1.0

`CONTEXT.md` listed "versioning and release cadence for public users" as an
open question. Issue #52 closes it, because [issue #31](https://github.com/telday/markdown-viewer/issues/31)
is about to publish a binary and a version number is the first thing a stranger
sees.

The decision, in three parts:

1. **Versions are semantic, against user-visible behavior** — not against the
   source tree.
2. **Releases happen when there is a reason to install one.** No calendar.
3. **The first public version is `0.1.0`**, and `1.0.0` is gated on
   [issue #48](https://github.com/telday/markdown-viewer/issues/48).

## What "user-visible" means here

SemVer's contract is normally about an API. Folium has no API: nobody links
against it, and its public surface is *what a person sees and does in front of
a document*. So that is what the version number describes.

**Visible surface** — changes here move a version component:

- The rendered output for a given file, and the styling of it.
- Affordances: menu items, keyboard shortcuts, gestures, the Share/Services
  integrations, state restoration.
- Which file extensions Folium claims, and how it behaves on files it opens.
- Preferences: their keys, their defaults, and what they do.
- The minimum macOS version.

**Not visible** — changes here move nothing on their own:

- Refactors, renames, file moves, test changes, coverage work.
- Swapping an implementation for one that behaves identically.
- Documentation, CI, and build-system changes that leave the shipped bundle
  behaving the same.

A change of the second kind does not get a release of its own. It rides along
in whatever release the next visible change earns.

### Which component moves

- **MAJOR** — a person's existing habit stops working, or their existing state
  stops being honored. Removing an affordance, changing what a shortcut does,
  dropping a file extension, raising the minimum macOS version, or invalidating
  saved preferences or restored state without migrating them.
- **MINOR** — new visible behavior that takes nothing away. A new affordance,
  a newly supported extension, a new preference with a default that preserves
  today's behavior.
- **PATCH** — the app doing what it already claimed, but correctly. Bug fixes,
  crash fixes, and performance work.

One project-specific rule makes most rendering changes unambiguous: **moving
the rendered output closer to GitHub is always a PATCH, never a MAJOR.**
`CONTEXT.md` priority 3 makes GitHub's rendering the contract, so a document
that renders differently *after* a fidelity fix was rendering wrongly before.
The output changed; the contract did not. A rendering change that moves *away*
from GitHub is a different thing entirely — it needs its own ADR before it
needs a version component.

Performance is PATCH for the same reason, from the other direction: the latency
table in `CONTEXT.md` is what the app already owes, so paying down issue #48
is fixing a defect, not adding a feature.

## Cadence: when there is a reason to install

There is no release schedule. A tag is cut when the branch holds a user-visible
change worth someone's download, and not otherwise. No minimum, no maximum, no
release train to fall behind on.

What follows from that, and is being decided here rather than discovered later:

- **Only the newest version is supported.** No maintenance branches, no
  backports, no LTS. Homebrew upgrades in place and there is no in-app update
  check to strand anyone on an old build (network floor), so "upgrade" is the
  entire support policy.
- **A security-relevant fix is still not a schedule**, but it is the one case
  where a release is cut for a single change rather than batched.
- **No release frequency is published.** The README describes the rhythm —
  releases happen when there is a reason to install one — but names no
  interval, because a cadence a solo maintainer commits to and then misses is
  worse than no cadence.

## Where the number actually lives

The git tag is the source of truth, `v`-prefixed: `v0.1.0`. Nothing derives it
automatically yet — that is issue #31's job:

- `make bundle VERSION=0.1.0` stamps `CFBundleShortVersionString` — the version
  in Finder's Get Info and the About box. Today that value is typed by hand;
  the release workflow issue #31 describes will pass the tag it was triggered
  by, which is why the tag format is pinned here rather than left to whoever
  types the first one. The `v` belongs to the tag, not to the version, so it is
  dropped at that boundary.
- `CFBundleVersion` stays the commit count and is **not** a semantic version.
  macOS requires it to increase monotonically between two copies of the same
  app, which a SemVer string does not do reliably (`0.10.0` follows `0.9.0` in
  SemVer and precedes it in a plain string comparison). The two numbers answer
  different questions and are deliberately not the same number.

## The first version is 0.1.0

`1.0.0` says the visible surface is one a stranger can build a habit on.
Folium's is not there yet, and there is a specific reason on record: issue #48
measured four of the five latency budgets over, three of them by 3–4×. Priority
2 of `CONTEXT.md` calls those "binding design constraints, not aspirations" and
says knowingly exceeding one requires an ADR.

Shipping `1.0.0` on top of that open issue would answer the question by
accident. Either the budgets are binding — in which case `1.0.0` waits — or
they are aspirational, which is a change to `CONTEXT.md` that nobody has
argued for. Starting at `0.1.0` needs neither: below `1.0.0` the project is
openly making no stability promise, which is the truth today.

**`1.0.0` requires:**

- Issue #48 resolved — either the budgets are met, or an ADR knowingly accepts
  the overage. Both are legitimate; silence is not.
- Scrolling measured on a 120 Hz ProMotion display, which `CONTEXT.md` budgets
  and issue #48 could not test.

Nothing else here gates `1.0.0`. In particular, feature completeness does not:
priority 4 keeps the feature surface flat on purpose, so "more features" is
not a thing `1.0.0` is waiting for.

Between now and then, `0.x` follows the same MAJOR/MINOR/PATCH rules described
above — the components carry their normal meaning, they just sit behind a
leading `0` that says the whole surface is still allowed to move.

## Considered options

**Ship `1.0.0` immediately.** Rejected for the reason above. It is also the
harder position to walk back: `2.0.0` is the only way out of a `1.0.0` that
turned out to be premature, and it would spend the one signal that means "your
habits broke" on "we were early".

**Calendar versioning (`2026.9.0`).** Rejected. CalVer tells a user when a
build was cut, not whether upgrading will break their habits — and this app's
whole promise is that it behaves the way macOS taught them. The one thing
CalVer is good at, conveying staleness, is handled by Homebrew keeping everyone
current.

**Stay on `0.x` permanently (ZeroVer).** Rejected as dishonest once the app is
stable: it would reserve the right to break the user's habits forever while
never intending to use it.

**Version against the source tree** — bumping MAJOR for large refactors.
Rejected: it makes the version number a measure of how much work happened,
which is exactly the information a user does not need, and it would make the
render-path work behind issue #48 look like a breaking change.

## Consequences

- **`CONTEXT.md`'s open-questions list loses its first entry**, replaced by a
  pointer here.
- **The `0.0.0-dev` default in the `Makefile` stays**, and stays outside this
  scheme. It marks a bundle nobody released; sorting below every real version
  is the point.
- **[ADR 0003](0003-distribution-homebrew-unsandboxed.md)'s "v1" is not
  `1.0.0`.** It calls `make install` from source "the v1 path", written before
  a version meant anything here: it names the first way anyone installs Folium,
  not the version number this ADR defines. Shipping `0.1.0` first contradicts
  nothing in it.
- **The preferences-migration policy stays open.** MAJOR above turns on whether
  saved preferences and restored state are migrated, and `CONTEXT.md` still
  lists that policy as an open question. This ADR fixes what breaking them
  *costs* in version terms — not when breaking them is allowed.
- **Issue #31's release workflow inherits a tag format** (`v0.1.0`) and a first
  version (`0.1.0`) rather than choosing them under time pressure at tagging
  time.
- **The "is this user-visible?" question now has to be answered per change.**
  In practice it is answered by whether the change touches the visible surface
  listed above — and the honest default for a borderline case is that it is
  visible, since the cost of an unnecessary PATCH is nothing and the cost of a
  silent behavior change is a user's trust.
