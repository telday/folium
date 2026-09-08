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
        "warm-open": 150,        // Warm open (app already running) → painted
        "reload-paint": 100,     // Live-reload: file written → repainted
        "tab-switch": 50         // Tab switch (and no re-render)
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

    /// Lookup the budget for an event in milliseconds, or nil if unmeasured.
    static func budget(for event: String) -> Double? {
        return budgets[event]
    }

    /// One line per budgeted moment, in the wire format `scripts/bench.sh`
    /// parses: `FOLIUM_BENCH_BUDGET <event> <milliseconds>`. `cold-launch`,
    /// `reload-paint`, and `warm-open` all need a wall-clock reading the
    /// script takes from outside this process, so the script — not this
    /// type — is what ends up comparing them to budget. Emitting this table under
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

    /// Format the scrolling line. Scrolling is the one budgeted moment whose
    /// budget is not a duration — `CONTEXT.md` asks for "no dropped frames,
    /// including 120 Hz ProMotion" — so it passes on a count, not a
    /// comparison against `budgets`, and reports the refresh rate it held
    /// the run to so a pass at 60 Hz can't be mistaken for a pass at 120.
    static func scrollReportLine(dropped: Int, measured: Int, refreshHz: Int) -> String {
        let name = names["scrolling"] ?? "scrolling"
        let detail = "\(dropped)/\(measured) frames dropped @ \(refreshHz) Hz"
        let status = dropped == 0 ? "✓" : "✗"
        let dots = max(1, 60 - name.count - detail.count)
        return "  \(name)\(String(repeating: ".", count: dots)) \(detail)  \(status)"
    }

    /// Builds the scrolling line from `MarkdownPage.scrollProbeScript`'s
    /// return value, or `nil` if it isn't shaped as expected. JavaScript
    /// numbers cross into Swift as `NSNumber`, not `Int`, so a direct
    /// `as? Int` would fail on values that are perfectly good integers.
    static func scrollReportLine(from result: [String: Any]) -> String? {
        guard let measured = (result["measured"] as? NSNumber)?.intValue,
              let dropped = (result["dropped"] as? NSNumber)?.intValue,
              let refreshHz = (result["hz"] as? NSNumber)?.intValue else { return nil }
        return scrollReportLine(dropped: dropped, measured: measured, refreshHz: refreshHz)
    }

}
