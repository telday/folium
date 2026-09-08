# Folium build & install.
#
# `make install` builds a release binary, assembles a Folium.app bundle,
# ad-hoc signs it, and copies it to /Applications. See ADR 0002 (SPM build)
# and ADR 0003 (unsandboxed, direct distribution).

APP_NAME    := Folium
BUNDLE_ID   := com.telday.Folium
CONFIG      := release
# The version a user sees in Finder's Get Info and in the About box. Pass it
# on the command line (`make bundle VERSION=1.2.0`) or from the environment.
# The default is stamped like any other value, so a plain `make install`
# exercises the same path a tagged release build takes.
#
# `override` with `$(or ...)`, rather than `?=`, because a variable set to the
# empty string counts as set: `VERSION= make bundle` — the shape a CI template
# produces when its input is blank — would otherwise stamp an empty version.
# A non-empty value from the command line still wins, since it is what
# `$(VERSION)` expands to here.
override VERSION  := $(or $(strip $(VERSION)),0.0.0-dev)
# macOS compares CFBundleVersion — the build number — between two copies of
# the same app, so it has to grow. The commit count grows with every commit,
# and unlike a timestamp it is the same for everyone building a given commit.
# Counting needs the whole history; a shallow clone has none, which the bundle
# recipe warns about.
override BUILD_NUM := $(or $(strip $(BUILD_NUM)), \
                           $(shell git rev-list --count HEAD 2>/dev/null),1)
# Universal, so one bundle runs natively on Apple Silicon and on Intel rather
# than under Rosetta on one of them. Asking for a second architecture hands
# the build to Xcode's build system, which needs Xcode itself installed and
# selected — the Command Line Tools alone do not carry it (see ADR 0002's
# 2026-08-16 amendment).
ARCH_FLAGS  := --arch arm64 --arch x86_64
# Ask the Swift Package Manager where the products landed instead of
# hardcoding it. Xcode's build system puts them somewhere else entirely
# (.build/apple/Products/Release, against .build/arm64-apple-macosx/release),
# so the path follows the flags above. Deferred (`=`, not `:=`) so only the
# recipes that use it pay for the extra swift invocation.
BUILD_DIR    = $(or $(shell swift build -c $(CONFIG) $(ARCH_FLAGS) --show-bin-path), \
                    $(error could not read the products directory from swift build))
# Assemble the bundle under .build/ so the build artifact isn't left in the
# project directory, where Spotlight would index it as a second Folium app.
APP_BUNDLE  := .build/$(APP_NAME).app
CONTENTS    := $(APP_BUNDLE)/Contents
SOURCE_DIR  := Sources/$(APP_NAME)
INSTALL_DIR := /Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app

.PHONY: all build bundle verify-bundle install uninstall clean vendor \
        check lint vet test test-unit test-integration coverage bench

all: bundle

## Run every Definition-of-Done gate: lint, vet, unit + integration tests, coverage.
## See docs/agents/definition-of-done.md.
check: lint vet test-unit test-integration coverage
	@echo "All quality gates passed."

## Style/convention linting (fails on any violation).
lint:
	@command -v swiftlint >/dev/null 2>&1 || { \
		echo "swiftlint not found. Install it with: brew install swiftlint"; exit 1; }
	swiftlint lint --strict

## Static analysis: compile all targets with warnings treated as errors
## (the closest Swift equivalent of `go vet`).
vet: vendor
	swift build --build-tests -Xswiftc -warnings-as-errors

## Run both test suites.
test: test-unit test-integration

## Fast, isolated unit tests.
test-unit: vendor
	swift test --filter FoliumTests

## Integration tests that exercise the file-to-render pipeline end to end.
test-integration: vendor
	swift test --filter FoliumIntegrationTests

## Enforce >=97% unit-test line coverage on the logic layer. Prints the
## excluded UI/host-glue files on every run. See scripts/coverage.sh.
coverage: vendor
	./scripts/coverage.sh

## Regenerate vendored third-party JS/CSS (Sources/Folium/Vendor/, gitignored)
## from vendor/package.json's pinned versions. A no-op once already current,
## so this is cheap to list as a prerequisite everywhere `swift build`/`swift
## test` runs. A bare `swift build` (bypassing make) needs this run first.
## See scripts/vendor-highlightjs.sh.
vendor:
	./scripts/vendor-highlightjs.sh

## Compile the release binary, universal for both Mac architectures.
build: vendor
	swift build -c $(CONFIG) $(ARCH_FLAGS)

## Assemble and ad-hoc sign $(APP_BUNDLE) from the release binary.
bundle: build
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	cp packaging/Info.plist "$(CONTENTS)/Info.plist"
	# The version goes into the copy, never into packaging/Info.plist, so a
	# build leaves the checkout alone. plutil ships with macOS and edits a
	# plist in place.
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(CONTENTS)/Info.plist"
	plutil -replace CFBundleVersion -string "$(BUILD_NUM)" "$(CONTENTS)/Info.plist"
	@[ "$$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ] && \
		echo "warning: shallow clone — CFBundleVersion is $(BUILD_NUM) for every build; pass BUILD_NUM=" \
		|| true
	# The Finder/Dock icon. `.icns` is a multi-resolution container, and
	# iconutil is the only supported way to produce one — it packs the ten
	# PNGs whose names encode the sizes macOS asks for (16pt through 512pt,
	# each @1x and @2x). Built here rather than committed so the PNGs stay
	# the reviewable source of truth.
	iconutil --convert icns --output "$(CONTENTS)/Resources/$(APP_NAME).icns" \
		packaging/$(APP_NAME).iconset
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	# The page shell and its CSS/JS, at the paths MarkdownPage.resourceBaseURL
	# resolves against. Taken from the source tree, not from the resource
	# bundle the Swift Package Manager generates, so the .app doesn't inherit
	# that bundle's name and layout. See ADR 0003's 2026-08-16 amendment.
	cp -R "$(SOURCE_DIR)/Resources" "$(CONTENTS)/Resources/Resources"
	cp -R "$(SOURCE_DIR)/Vendor/HighlightJS" "$(CONTENTS)/Resources/HighlightJS"
	# Signing comes last: a signature seals the files present when it runs.
	codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

## Verify that the assembled $(APP_BUNDLE) is shippable: resources present,
## bundle root clean, signature valid, universal, stamped with $(VERSION).
## Builds nothing — run `make bundle` first. See scripts/verify-bundle.sh.
verify-bundle:
	./scripts/verify-bundle.sh "$(APP_BUNDLE)" "$(VERSION)"

## Measure and report latency budgets: cold launch, live-reload, Markdown
## render. Regenerates the fixture on every run — scripts/bench.sh mutates it
## in place for the live-reload probe, so a stale one would start already
## probed. Exits 0 regardless; CI records this as a trend, not a gate. See
## issue #21.
##
## Measures $(APP_BUNDLE), the same artifact `make install` puts in
## /Applications, rather than the bare binary `swift build` leaves in
## .build. Not a preference for realism: an unbundled executable has no
## Info.plist, never becomes a regular activatable app, and so never puts a
## window on screen for WebKit to paint into — 0 of 6 such runs produced a
## first-paint marker, against 3 of 4 for the bundle. scripts/bench.sh runs
## the executable inside the bundle directly, rather than going through
## `open`, because it has to read that process's own stderr.
bench: bundle
	./scripts/make-bench-fixture.sh
	./scripts/bench.sh .build/bench/fixture.md "$(APP_BUNDLE)"

## Install the bundle to /Applications.
install: bundle
	rm -rf "$(INSTALLED)"
	cp -R "$(APP_BUNDLE)" "$(INSTALLED)"
	@echo "Installed $(INSTALLED)"

## Remove the installed bundle from /Applications.
uninstall:
	rm -rf "$(INSTALLED)"

## Remove build artifacts and the local bundle.
clean:
	swift package clean
	rm -rf "$(APP_BUNDLE)"
