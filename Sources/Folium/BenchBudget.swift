import Foundation

/// Budget thresholds and reporting for latency measurements.
///
/// Keyed by **report moment**, not by the raw event names `BenchMarker`
/// writes to stderr. "cold-launch" is `scripts/bench.sh`'s own wall-clock
/// reading (taken before it execs the app) subtracted from the `first-paint`
/// marker — a moment that only exists once the script combines the two, so
/// it needs its own name here.
struct BenchBudget {
    /// The budget for each moment, in milliseconds. Only moments with a budget
    /// are enforced; others are measured but not gated.
    static let budgets: [String: Double] = [
        "cold-launch": 500,      // Cold launch → first document painted
        "reload-paint": 100      // Live-reload: file written → repainted
        // "render" has no budget — it's informational
    ]

    /// The formatted name for each moment, for human-readable reports.
    static let names: [String: String] = [
        "cold-launch": "Cold launch → first document painted",
        "reload-paint": "Live-reload: file written → repainted",
        "render": "Markdown → HTML render (fixture)",
        "warm-open": "Warm open (app already running) → painted",
        "tab-switch": "Tab switch",
        "scrolling": "Scrolling / dropped frames"
    ]

    /// Why each permanently-unmeasured moment can't be measured.
    static let unmeasuredReasons: [String: String] = [
        "warm-open": "requires driving an already-running app's UI",
        "tab-switch": "requires driving an already-running app's UI",
        "scrolling": "out of scope for this fixture"
    ]

    /// Lookup the budget for an event in milliseconds, or nil if unmeasured.
    static func budget(for event: String) -> Double? {
        return budgets[event]
    }

    /// One line per budgeted moment, in the wire format `scripts/bench.sh`
    /// parses: `FOLIUM_BENCH_BUDGET <event> <milliseconds>`. `cold-launch`
    /// and `reload-paint` both need a wall-clock reading the script takes
    /// from outside this process, so the script — not this type — is what
    /// ends up comparing them to budget. Emitting this table under
    /// FOLIUM_BENCH is what lets the script read the numbers here instead of
    /// keeping a second, hand-synced copy of `budgets`.
    static func budgetTableLines() -> [String] {
        budgets.keys.sorted().map { event in
            "FOLIUM_BENCH_BUDGET \(event) \(Int(budgets[event] ?? 0))"
        }
    }

    /// Format a measurement line for the report, comparing measured vs budget.
    ///
    /// Returns a line like "  Cold launch....... 245 ms  ✓" or
    /// "  Cold launch....... 520 ms  ✗ (over by 20 ms)".
    static func reportLine(event: String, measuredMs: Double) -> String {
        let name = names[event] ?? event
        let status: String
        var suffix = ""

        if let budgetMs = budget(for: event) {
            if measuredMs <= budgetMs {
                status = "✓"
            } else {
                let overMs = measuredMs - budgetMs
                status = "✗"
                suffix = " (over by \(Int(overMs)) ms)"
            }
        } else {
            status = "–"
        }

        // Pad to align the status column.
        let dots = max(1, 60 - name.count - String(format: "%.0f", measuredMs).count)
        let padding = String(repeating: ".", count: dots)
        return "  \(name)\(padding) \(Int(measuredMs)) ms  \(status)\(suffix)"
    }

    /// Format a line for an unmeasured moment.
    static func reportLineUnmeasured(event: String, reason: String) -> String {
        let name = names[event] ?? event
        let dots = max(1, 60 - name.count - 12) // "not measured" is ~12 chars
        let padding = String(repeating: ".", count: dots)
        return "  \(name)\(padding) not measured (\(reason))"
    }

    /// The permanently-unmeasured moments, pre-formatted and prefixed for
    /// `BenchMarker.writeLine`: `FOLIUM_BENCH_REPORT <event> <line>` — the
    /// same wire format `BenchMarker.measure` uses for `render`, so
    /// `scripts/bench.sh` can look either kind up by event and fall back
    /// per-event if one is missing. Emitted at launch rather than
    /// hardcoded in the script: none of them depend on anything that
    /// happens at runtime.
    static func unmeasuredReportLines() -> [String] {
        unmeasuredReasons.keys.sorted().map { event in
            let line = reportLineUnmeasured(event: event, reason: unmeasuredReasons[event] ?? "")
            return "FOLIUM_BENCH_REPORT \(event) \(line)"
        }
    }
}
