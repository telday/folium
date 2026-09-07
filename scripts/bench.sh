#!/bin/bash
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
# `first-paint` marker instead.
set -euo pipefail

FIXTURE="${1:-.build/bench/fixture.md}"
BINARY="${2:?usage: bench.sh <fixture> <binary> — the Makefile passes the executable inside \$(APP_BUNDLE)}"

if [[ ! -f "$FIXTURE" ]]; then
    echo "Error: fixture not found at $FIXTURE" >&2
    exit 1
fi
if [[ ! -x "$BINARY" ]]; then
    echo "Error: binary not found at $BINARY" >&2
    exit 1
fi

MARKERS=$(mktemp)
APP_PID=""
cleanup() {
    [[ -n "$APP_PID" ]] && kill -9 "$APP_PID" 2>/dev/null || true
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
    grep -m1 "^FOLIUM_BENCH_BUDGET $1 " "$MARKERS" | awk '{print $3}'
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

# Cold launch. FOLIUM_BENCH_OPEN tells FoliumAppDelegate to open the fixture
# as soon as AppKit finishes launching — see that file for why a plain
# command-line argument isn't enough to make a SwiftUI DocumentGroup app open
# a document.
LAUNCH_T0=$(wall_clock)
FOLIUM_BENCH=1 FOLIUM_BENCH_OPEN="$FIXTURE" "$BINARY" 2>"$MARKERS" &
APP_PID=$!

COLD_LAUNCH_MS=""
if wait_for_line "FOLIUM_BENCH first-paint" 100; then
    COLD_LAUNCH_MS=$(elapsed_ms "$(marker_timestamp "first-paint")" "$LAUNCH_T0")
fi

# Live-reload. `LiveDocument` deliberately treats a rewrite with unchanged
# rendered output as a no-op — `touch`, or a save of identical bytes, must
# not repaint — so the probe below has to change the document's actual
# content, not just its mtime, or `reload-paint` will never fire. Plain
# text, not an HTML comment: cmark's safe mode is what currently makes an
# HTML comment render differently (substituted for a fixed placeholder), and
# issue #20 turning that off would make an HTML-comment probe render
# byte-identically, silently breaking this. $RELOAD_T0 is taken before the
# write, not after, so the measured window can't understate the time the
# write itself takes.
RELOAD_MS=""
if [[ -n "$COLD_LAUNCH_MS" ]]; then
    RELOAD_T0=$(wall_clock)
    printf '\nBench live-reload probe.\n' >> "$FIXTURE"
    if wait_for_line "FOLIUM_BENCH reload-paint" 50; then
        RELOAD_MS=$(elapsed_ms "$(marker_timestamp "reload-paint")" "$RELOAD_T0")
    fi
fi

kill -9 "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

echo "Measurements"
echo "============"
echo ""

if [[ -n "$COLD_LAUNCH_MS" ]]; then
    report_line "Cold launch → first document painted" "$COLD_LAUNCH_MS" "$(budget_ms cold-launch)"
else
    report_line "Cold launch → first document painted" "" "" "app did not emit a first-paint marker"
fi

if [[ -n "$RELOAD_MS" ]]; then
    report_line "Live-reload: file written → repainted" "$RELOAD_MS" "$(budget_ms reload-paint)"
else
    report_line "Live-reload: file written → repainted" "" "" "app did not emit a reload-paint marker"
fi

# render, and the permanently-unmeasured moments (warm open, tab switch,
# scrolling), are moments the app can fully compute and format for itself —
# see BenchMarker.measure and BenchBudget.unmeasuredReportLines — so this
# script prints what it said verbatim rather than recomputing any of it. The
# wire format is "FOLIUM_BENCH_REPORT <event> <pretty line>": the event token
# is there so this script could look a line up by event if it ever needed to
# (the same shape budget_ms already reads), not for display, so it has to be
# stripped along with the literal prefix or it leaks into the printed report.
# `render` fires twice per run — once for the initial open, again for the
# live-reload probe — so this keeps only the first line per event (awk
# `!seen[$2]++`, keyed on the still-present event token before it's
# stripped), the same "first occurrence is the one being asked about" rule
# marker_timestamp already applies to FOLIUM_BENCH markers.
if grep -q "^FOLIUM_BENCH_REPORT " "$MARKERS" 2>/dev/null; then
    grep "^FOLIUM_BENCH_REPORT " "$MARKERS" | awk '!seen[$2]++' | sed -E 's/^FOLIUM_BENCH_REPORT [^ ]+ //'
else
    report_line "Markdown → HTML render (fixture)" "" "" "renderer did not emit timing"
    report_line "Warm open (app already running) → painted" "" "" "requires driving an already-running app's UI"
    report_line "Tab switch" "" "" "requires driving an already-running app's UI"
    report_line "Scrolling / dropped frames" "" "" "out of scope for this fixture"
fi

echo ""
echo "Notes"
echo "====="
echo "- Cold launch is timed from this script's own wall-clock reading, taken"
echo "  immediately before exec, to the app's first-paint marker — the only"
echo "  baseline that includes process spawn, dyld, and AppKit start-up."
echo "- Live-reload appends a line of text to the fixture (a no-op rewrite"
echo "  would never repaint, by design) and times from that write to"
echo "  reload-paint."
echo "- Warm open and tab switch need an already-running app's UI driven from"
echo "  outside, which a shell script cannot do honestly."
echo "- Scrolling / dropped frames is out of scope for this fixture."
echo "- Measured against the executable inside the real signed .app that"
echo "  \`make bundle\`/\`make install\` produce, run directly so this script"
echo "  can read its stderr — see the Makefile's bench recipe."
echo ""

# Always exit 0. CI records these numbers as an informational trend, not a
# gate — see CONTEXT.md.
exit 0
