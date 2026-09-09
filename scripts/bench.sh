#!/usr/bin/env bash
# Orchestrates the latency-budget measurements: launches the app with the
# fixture, waits for its markers, writes real new content to trigger a
# live-reload, and prints measured vs budgeted latency. Exits 0 regardless;
# CI records the numbers as an informational trend, not a gate (see issue #21
# and CONTEXT.md's perceived-latency priority).
#
# BenchMarker inside the app emits absolute wall-clock timestamps (seconds
# since the Unix epoch, gated on FOLIUM_BENCH) rather than elapsed durations.
# Cold launch has to be timed from OUTSIDE the process: dyld and AppKit
# start-up happen before any of our Swift code runs, so an in-process
# baseline can never see them. This script takes its own wall-clock reading
# immediately before it execs the app and subtracts that from the
# first `paint` marker instead.
set -euo pipefail

FIXTURE="${1:-.build/bench/fixture.md}"
BUNDLE="${2:?usage: bench.sh <fixture> <app-bundle> — the Makefile passes \$(APP_BUNDLE)}"

if [[ ! -f "$FIXTURE" ]]; then
    echo "Error: fixture not found at $FIXTURE" >&2
    exit 1
fi
if [[ ! -d "$BUNDLE" ]]; then
    echo "Error: app bundle not found at $BUNDLE" >&2
    exit 1
fi
# Absolute, because the warm-open probe hands this to `open`, which resolves
# a bare relative path as an application *name* to look up rather than a
# path on disk, and fails.
BUNDLE="$(cd "$(dirname "$BUNDLE")" && pwd)/$(basename "$BUNDLE")"

# The bundle, not just the executable, because the warm-open probe below
# hands the .app to `open`. The executable name comes from the Info.plist
# rather than being assumed to match the bundle's, which is the same source
# Launch Services reads.
BINARY="$BUNDLE/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$BUNDLE/Contents/Info.plist")"
if [[ ! -x "$BINARY" ]]; then
    echo "Error: bundle executable not found at $BINARY" >&2
    exit 1
fi

# Warm open has to open a *different* document: asking Launch Services to
# open a file that is already open just brings its window forward, with no
# new document, no render, and no paint. Copied before the live-reload probe
# below appends to $FIXTURE, so the two documents are byte-identical and the
# two measurements are comparable.
WARM_FIXTURE="${FIXTURE%.md}-warm.md"
cp "$FIXTURE" "$WARM_FIXTURE"
# A line of its own, of a different length than the live-reload probe's, so
# the three documents this run paints — the fixture, the fixture after the
# reload probe, and this one — all render to different body sizes. That is
# what `paint_after` matches on; identical copies would be indistinguishable.
printf '\nBench warm-open probe: a second, separate document.\n' >> "$WARM_FIXTURE"

MARKERS=$(mktemp)
APP_PID=""
cleanup() {
    [[ -n "$APP_PID" ]] && kill -9 "$APP_PID" 2>/dev/null || true
    cp "$MARKERS" "${BENCH_DUMP:-/dev/null}" 2>/dev/null || true
    rm -f "$MARKERS"
}
trap cleanup EXIT

# Same clock `BenchMarker` uses (seconds since the Unix epoch, microsecond
# precision) so a reading taken here and a marker's timestamp can be
# subtracted directly, even though they come from different processes.
wall_clock() {
    python3 -c 'import time; print(f"{time.time():.6f}")'
}

# Polls $MARKERS for a line starting "PREFIX ", up to $2 tenths of a second.
# FileWatcher's coalescing window and WebKit's own scheduling mean a marker
# can arrive anywhere from a few milliseconds to a couple of seconds after
# the thing that triggers it, so this is a wait loop rather than a fixed
# sleep.
wait_for_line() {
    local prefix="$1" timeout_tenths="$2"
    for ((i = 0; i < timeout_tenths; i++)); do
        if grep -q "^${prefix} " "$MARKERS" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# Prints the timestamp field of a "FOLIUM_BENCH <event> <ts>" marker's first
# occurrence. First rather than last: an event can legitimately repeat
# (rendering happens once for the initial open and again for the live-reload
# probe below), and the first occurrence is always the one this script is
# asking about.
marker_timestamp() {
    grep -m1 "^FOLIUM_BENCH $1 " "$MARKERS" | awk '{print $3}'
}

# Prints the timestamp of the first paint at or after $2 whose body size is
# none of the sizes listed in $3 (space separated). A paint marker's fourth
# field is the size of the body it drew — see BenchMarker.mark — so this is
# "the first paint after I asked that actually drew something new".
#
# Needed because a paint alone does not mean the paint being waited for:
# SwiftUI settles a document through several web views, and those views
# repaint the *same* body moments after the write. Matching on time alone
# picked one of those up as the live-reload repaint and reported 21 ms for
# work that took 280.
paint_after() {
    awk -v t0="$1" -v excluded=" $2 " \
        '$1 == "FOLIUM_BENCH" && $2 == "paint" && $3 + 0 >= t0 \
         && index(excluded, " " $4 " ") == 0 { print $3; exit }' "$MARKERS"
}

# The body size a paint drew, for the first paint at or after $1.
paint_signature_after() {
    awk -v t0="$1" \
        '$1 == "FOLIUM_BENCH" && $2 == "paint" && $3 + 0 >= t0 { print $4; exit }' "$MARKERS"
}

# Polls for a paint matching paint_after's rule, up to $3 tenths of a second.
wait_for_paint_after() {
    local after="$1" excluded="$2" timeout_tenths="$3"
    for ((i = 0; i < timeout_tenths; i++)); do
        if [[ -n "$(paint_after "$after" "$excluded")" ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# Prints the timestamp of the first "FOLIUM_BENCH <event> <ts>" marker at or
# after $2. The warm-open probe needs this rather than marker_timestamp: by
# the time it runs, the cold document has already painted,
# and the question is which paint came after the request, not which came
# first.
marker_timestamp_after() {
    awk -v ev="$1" -v t0="$2" \
        '$1 == "FOLIUM_BENCH" && $2 == ev && $3 + 0 >= t0 { print $3; exit }' "$MARKERS"
}

# Polls for a marker of $1 at or after $2, up to $3 tenths of a second.
wait_for_marker_after() {
    local event="$1" after="$2" timeout_tenths="$3"
    for ((i = 0; i < timeout_tenths; i++)); do
        if [[ -n "$(marker_timestamp_after "$event" "$after")" ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# Waits until no new marker has arrived for $1 tenths of a second, giving up
# after $2. SwiftUI re-evaluates a document's view tree several times while a
# window settles, and each new web view paints — so a warm-open reading taken
# while that is still happening would attribute the cold document's trailing
# paint to the warm open and understate it. Waiting for quiet first is what
# makes "the next paint after the request" mean the document just requested.
wait_for_quiet() {
    local quiet_tenths="$1" timeout_tenths="$2" last="" stable=0
    for ((i = 0; i < timeout_tenths; i++)); do
        local count
        count=$(wc -l < "$MARKERS" 2>/dev/null || echo 0)
        if [[ "$count" == "$last" ]]; then
            stable=$((stable + 1))
            [[ $stable -ge $quiet_tenths ]] && return 0
        else
            stable=0
            last="$count"
        fi
        sleep 0.1
    done
    return 1
}

# $1 - $2, in whole milliseconds. Both are wall-clock seconds since the Unix
# epoch. Kept as plain arithmetic, not policy — see BenchBudget.swift for the
# budget comparison and report formatting this script hands the result to.
elapsed_ms() {
    python3 -c "print(round(($1 - $2) * 1000))"
}

# Reads a budget in milliseconds from the app's own "FOLIUM_BENCH_BUDGET
# <event> <ms>" line — see BenchBudget.budgetTableLines, emitted once at
# launch — instead of a hardcoded number. Empty if the app never emitted one
# for $1: this script still treats that the way BenchBudget.reportLine treats
# an unbudgeted event, as informational rather than a hard error.
budget_ms() {
    printf '%s\n' "$BUDGET_TABLE" | grep -m1 "^FOLIUM_BENCH_BUDGET $1 " | awk '{print $3}'
}

# Mirrors BenchBudget.reportLine's format so cold launch and live-reload —
# the two moments whose start can only be timed from outside the process —
# read the same way as the lines the app prints for itself (`render`, and
# the permanently-unmeasured moments; see FOLIUM_BENCH_REPORT below). The
# budget numbers come from budget_ms, not a hardcoded copy.
report_line() {
    local name="$1" measured_ms="$2" budget_ms="$3"
    if [[ -z "$measured_ms" ]]; then
        local reason="$4"
        local dots=$((60 - ${#name} - 12))  # "not measured" is 12 characters
        [[ $dots -lt 1 ]] && dots=1
        printf '  %s%s not measured (%s)\n' "$name" "$(printf '.%.0s' $(seq 1 "$dots"))" "$reason"
        return
    fi
    local dots=$((60 - ${#name} - ${#measured_ms}))
    [[ $dots -lt 1 ]] && dots=1
    local dotted
    dotted=$(printf '.%.0s' $(seq 1 "$dots"))
    if [[ -z "$budget_ms" ]]; then
        printf '  %s%s %s ms  –\n' "$name" "$dotted" "$measured_ms"
    elif [[ "$measured_ms" -le "$budget_ms" ]]; then
        printf '  %s%s %s ms  \xE2\x9C\x93\n' "$name" "$dotted" "$measured_ms"
    else
        printf '  %s%s %s ms  \xE2\x9C\x97 (over by %s ms)\n' \
            "$name" "$dotted" "$measured_ms" "$((measured_ms - budget_ms))"
    fi
}

echo "Benchmark Results"
echo "================="
echo ""

# Each phase below launches its own app. The probes cannot share a session:
# with the scroll and tab-switch probes armed alongside the live-reload
# measurement, live-reload reported a number in 2 runs of 6 and scrolling in
# 2 of 6, because the scroll probe holds the animation frames a repaint needs
# and a repaint landing mid-scroll counts against the frame budget. One
# launch per probe costs three app starts and buys measurements that do not
# interfere.
#
# $MARKERS is reset per phase so a later phase never matches an earlier
# phase's markers.
start_app() {
    : > "$MARKERS"
    FOLIUM_BENCH=1 FOLIUM_BENCH_PROBE="${2:-none}" FOLIUM_BENCH_OPEN="$1" \
        "$BINARY" 2>"$MARKERS" &
    APP_PID=$!
}

stop_app() {
    [[ -n "$APP_PID" ]] || return 0
    kill -9 "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
    # Launch Services routes the warm-open `open` to whatever Folium is
    # running; a leftover process from the previous phase would take it.
    sleep 1
}

# ---------------------------------------------------------------------------
# Phase 1 — cold launch, Markdown render, live-reload. No in-app probe.
# ---------------------------------------------------------------------------
LAUNCH_T0=$(wall_clock)
start_app "$FIXTURE"

COLD_LAUNCH_MS=""
COLD_SIGNATURE=""
if wait_for_line "FOLIUM_BENCH paint" 100; then
    COLD_LAUNCH_MS=$(elapsed_ms "$(marker_timestamp "paint")" "$LAUNCH_T0")
    COLD_SIGNATURE=$(paint_signature_after 0)
fi

# `LiveDocument` deliberately treats a rewrite with unchanged rendered output
# as a no-op — `touch`, or a save of identical bytes, must not repaint — so
# this has to change the document's actual content, not just its mtime. Plain
# text, not an HTML comment: cmark's safe mode is what currently makes an
# HTML comment render differently, and issue #20 turning that off would make
# an HTML-comment probe render byte-identically, silently breaking this.
# $RELOAD_T0 is taken before the write so the measured window cannot
# understate the time the write itself takes.
RELOAD_MS=""
if [[ -n "$COLD_LAUNCH_MS" ]]; then
    wait_for_quiet 8 100 || true
    RELOAD_T0=$(wall_clock)
    printf '\nBench live-reload probe.\n' >> "$FIXTURE"
    if wait_for_paint_after "$RELOAD_T0" "$COLD_SIGNATURE" 100; then
        RELOAD_MS=$(elapsed_ms "$(paint_after "$RELOAD_T0" "$COLD_SIGNATURE")" "$RELOAD_T0")
    fi
fi

# Kept before the app is stopped: the budget table and the render report are
# emitted by the app, and $MARKERS is about to be reused by the next phase.
APP_REPORTS=$(grep "^FOLIUM_BENCH_REPORT " "$MARKERS" 2>/dev/null || true)
BUDGET_TABLE=$(grep "^FOLIUM_BENCH_BUDGET " "$MARKERS" 2>/dev/null || true)
stop_app

# ---------------------------------------------------------------------------
# Phase 2 — warm open, then tab switch. Both need a second document, and the
# switch has to happen after the open it follows, so they share a phase.
# ---------------------------------------------------------------------------
WARM_MS=""
TAB_SWITCH_MS=""
TAB_SWITCH_RERENDERED=""
start_app "$FIXTURE" tab-switch
if wait_for_line "FOLIUM_BENCH paint" 100; then
    WARM_SIGNATURE=$(paint_signature_after 0)
    # Wait for the marker stream to go quiet first: SwiftUI repaints a
    # settling document, and a trailing paint from the cold one would
    # otherwise be read as the warm open and understate it.
    wait_for_quiet 8 100 || true
    # Launch Services delivers this to the process already running —
    # verified, the PID is unchanged and the new document's markers arrive on
    # the same stderr — which is what makes it a warm open and not a second
    # cold launch. `open` returns as soon as the event is dispatched, so
    # $WARM_T0 is taken before the call.
    #
    # Retried because the delivery is not guaranteed on the first ask: this
    # phase's app was started seconds earlier by exec'ing the bundle's
    # executable, and until Launch Services has registered that process an
    # `open` can be answered by starting a *second* copy instead — one whose
    # stderr this script never sees, so no paint ever arrives. Measured: one
    # ask landed in 2 runs of 6, three asks in 6 of 6.
    for _ in 1 2 3; do
        WARM_T0=$(wall_clock)
        open -a "$BUNDLE" "$WARM_FIXTURE"
        if wait_for_paint_after "$WARM_T0" "$WARM_SIGNATURE" 60; then
            WARM_MS=$(elapsed_ms "$(paint_after "$WARM_T0" "$WARM_SIGNATURE")" "$WARM_T0")
            break
        fi
        # A copy Launch Services started separately would answer the next
        # ask itself, so close it — by PID, sparing this phase's own app,
        # which shares its executable path and would otherwise be killed too.
        for stray in $(pgrep -f "$BUNDLE/Contents/MacOS/" 2>/dev/null || true); do
            [[ "$stray" == "$APP_PID" ]] || kill -9 "$stray" 2>/dev/null || true
        done
        kill -0 "$APP_PID" 2>/dev/null || break
    done

    # The switch is triggered inside the app once the second document joins
    # the tab group — see DocumentWindowTabber for why a shell script cannot
    # ask for one.
    if wait_for_line "FOLIUM_BENCH tab-switch-end" 150; then
        TAB_T0=$(marker_timestamp "tab-switch-start")
        TAB_T1=$(marker_timestamp "tab-switch-end")
        if [[ -n "$TAB_T0" && -n "$TAB_T1" ]]; then
            TAB_SWITCH_MS=$(elapsed_ms "$TAB_T1" "$TAB_T0")
            # "no re-render" is the other half of CONTEXT.md's tab-switch
            # budget: switching tabs must reveal an already-rendered
            # document, not build one.
            if awk -v t0="$TAB_T0" -v t1="$TAB_T1" \
                '$1 == "FOLIUM_BENCH" && $2 == "render-start" && $3 + 0 >= t0 && $3 + 0 <= t1 { found = 1 }
                 END { exit !found }' "$MARKERS"; then
                TAB_SWITCH_RERENDERED="yes"
            fi
        fi
    fi
fi
stop_app

# ---------------------------------------------------------------------------
# Phase 3 — scrolling. Alone, because it holds every animation frame it can
# get for the duration of the run.
# ---------------------------------------------------------------------------
SCROLL_REPORT=""
start_app "$FIXTURE" scroll
if wait_for_line "FOLIUM_BENCH paint" 100 \
    && wait_for_line "FOLIUM_BENCH_REPORT scrolling" 200; then
    SCROLL_REPORT=$(grep -m1 "^FOLIUM_BENCH_REPORT scrolling " "$MARKERS" \
        | sed -E 's/^FOLIUM_BENCH_REPORT [^ ]+ //')
fi
stop_app

echo "Measurements"
echo "============"
echo ""

if [[ -n "$COLD_LAUNCH_MS" ]]; then
    report_line "Cold launch → first document painted" "$COLD_LAUNCH_MS" "$(budget_ms cold-launch)"
else
    report_line "Cold launch → first document painted" "" "" "app never confirmed a paint"
fi

if [[ -n "$WARM_MS" ]]; then
    report_line "Warm open (app already running) → painted" "$WARM_MS" "$(budget_ms warm-open)"
else
    report_line "Warm open (app already running) → painted" "" "" \
        "app did not paint a second document"
fi

if [[ -n "$RELOAD_MS" ]]; then
    report_line "Live-reload: file written → repainted" "$RELOAD_MS" "$(budget_ms reload-paint)"
else
    report_line "Live-reload: file written → repainted" "" "" "no paint followed the write"
fi

if [[ -n "$TAB_SWITCH_MS" ]]; then
    report_line "Tab switch" "$TAB_SWITCH_MS" "$(budget_ms tab-switch)"
    if [[ -n "$TAB_SWITCH_RERENDERED" ]]; then
        echo "      ^ re-rendered during the switch — the budget says it must not"
    fi
else
    report_line "Tab switch" "" "" "app did not complete a tab-switch probe"
fi

# The render timing is the one moment the app computes and formats for
# itself — `BenchMarker.measure` has both ends of it in-process — so this
# prints what it said rather than recomputing it. Taken from phase 1, which
# is the phase that opens a document with nothing else going on. The wire
# format is "FOLIUM_BENCH_REPORT <event> <pretty line>"; the event token is
# there so a line can be looked up by event, not for display, so it is
# stripped along with the prefix. `render` fires more than once per phase —
# the initial open, then the live-reload — and the first is the one being
# asked about.
RENDER_REPORT=$(printf '%s\n' "$APP_REPORTS" | grep -m1 "^FOLIUM_BENCH_REPORT render " \
    | sed -E 's/^FOLIUM_BENCH_REPORT [^ ]+ //' || true)
if [[ -n "$RENDER_REPORT" ]]; then
    printf '%s\n' "$RENDER_REPORT"
else
    report_line "Markdown → HTML render (fixture)" "" "" "renderer did not emit timing"
fi

if [[ -n "$SCROLL_REPORT" ]]; then
    printf '%s\n' "$SCROLL_REPORT"
else
    report_line "Scrolling / dropped frames" "" "" "probe did not finish"
fi

echo ""
echo "Notes"
echo "====="
echo "- Cold launch is timed from this script's own wall-clock reading, taken"
echo "  immediately before exec, to the app's first paint — the only"
echo "  baseline that includes process spawn, dyld, and AppKit start-up."
echo "- Live-reload appends a line of text to the fixture (a no-op rewrite"
echo "  would never repaint, by design) and times from that write to"
echo "  the paint that follows it."
echo "- Warm open asks Launch Services to open a second, identical document in"
echo "  the already-running process, and times that request to the next paint."
echo "- Tab switch is triggered inside the app once the warm-open document"
echo "  joins the tab group, and timed to a frame drawn in the revealed tab."
echo "  It also checks that nothing re-rendered during the switch."
echo "- Scrolling scrolls the real document for ~180 animation frames and"
echo "  counts frames that missed the display's own interval, inferred from"
echo "  the run rather than assumed to be 60 Hz. It scrolls by script, so it"
echo "  measures drawing the moving document, not the input pipeline."
echo "- Measured against the executable inside the real signed .app that"
echo "  \`make bundle\`/\`make install\` produce, run directly so this script"
echo "  can read its stderr — see the Makefile's bench recipe."
echo ""

# Always exit 0. CI records these numbers as an informational trend, not a
# gate — see CONTEXT.md.
exit 0
