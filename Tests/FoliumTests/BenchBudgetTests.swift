import Foundation
import Testing
@testable import Folium

/// Unit tests for benchmark budgets and reporting.
struct BenchBudgetTests {
    @Test func budgetLookupReturnsCorrectValues() {
        #expect(BenchBudget.budget(for: "cold-launch") == 500)
        #expect(BenchBudget.budget(for: "reload-paint") == 100)
        #expect(BenchBudget.budget(for: "render") == nil)
        #expect(BenchBudget.budget(for: "unknown") == nil)
    }

    @Test func reportLineShowsUnderBudgetAsSuccess() {
        let line = BenchBudget.reportLine(event: "cold-launch", measuredMs: 250)
        #expect(line.contains("250 ms"))
        #expect(line.contains("✓"))
        #expect(line.contains("Cold launch"))
        #expect(!line.contains("over by"))
    }

    @Test func reportLineShowsAtBudgetAsSuccess() {
        let line = BenchBudget.reportLine(event: "cold-launch", measuredMs: 500)
        #expect(line.contains("500 ms"))
        #expect(line.contains("✓"))
    }

    @Test func reportLineShowsOverBudgetAsFailure() {
        let line = BenchBudget.reportLine(event: "reload-paint", measuredMs: 120)
        #expect(line.contains("120 ms"))
        #expect(line.contains("✗"))
        #expect(line.contains("over by 20 ms"))
    }

    @Test func reportLineShowsDashForUnbudgetedEvents() {
        let line = BenchBudget.reportLine(event: "render", measuredMs: 150)
        #expect(line.contains("150 ms"))
        #expect(line.contains("–"))
    }

    @Test func reportLineForUnmeasuredIncludesReason() {
        let reason = "requires driving an already-running app's UI"
        let line = BenchBudget.reportLineUnmeasured(event: "warm-open", reason: reason)
        #expect(line.contains("not measured"))
        #expect(line.contains(reason))
    }

    @Test func reportLinesAlignProperlyWithDots() {
        let line = BenchBudget.reportLine(event: "cold-launch", measuredMs: 250)
        // The line should have dots between the event name and the measurement.
        #expect(line.contains("..."))
    }

    @Test func budgetTableLinesCoverEveryBudgetedEvent() {
        let lines = BenchBudget.budgetTableLines()
        #expect(lines.contains("FOLIUM_BENCH_BUDGET cold-launch 500"))
        #expect(lines.contains("FOLIUM_BENCH_BUDGET reload-paint 100"))
        // "render" has no budget, so it must not appear here — scripts/bench.sh
        // treats an event with no budget line as unbudgeted, informational only.
        #expect(!lines.contains { $0.contains("render") })
    }

    /// Tab switch is the only moment left that the harness cannot reach:
    /// warm open is driven by Launch Services from `scripts/bench.sh`, and
    /// scrolling by `MarkdownPage.scrollProbeScript` inside the page.
    @Test func unmeasuredReportLinesCoverEveryPermanentlyUnmeasuredMoment() {
        let lines = BenchBudget.unmeasuredReportLines()
        #expect(lines.count == 1)
        // Event-prefixed, like BenchMarker.measure's FOLIUM_BENCH_REPORT
        // lines, so scripts/bench.sh can look either kind up by event.
        #expect(lines.contains { $0.hasPrefix("FOLIUM_BENCH_REPORT tab-switch ") && $0.contains("Tab switch") })
        #expect(lines.allSatisfy { $0.contains("not measured") })
    }

    // MARK: - Scrolling

    /// Scrolling's budget is a frame count, not a duration, so it formats
    /// itself rather than going through `reportLine`.
    @Test func scrollReportLineMarksACleanRunAsPassing() {
        let line = BenchBudget.scrollReportLine(dropped: 0, measured: 179, refreshHz: 120)

        #expect(line.contains("0/179 frames dropped @ 120 Hz"))
        #expect(line.hasSuffix("✓"))
    }

    @Test func scrollReportLineMarksAnyDroppedFrameAsFailing() {
        let line = BenchBudget.scrollReportLine(dropped: 1, measured: 179, refreshHz: 120)

        #expect(line.contains("1/179 frames dropped"))
        #expect(line.hasSuffix("✗"))
    }

    /// A pass at 60 Hz is not the same claim as a pass at 120 Hz — CONTEXT.md
    /// budgets scrolling "including 120 Hz ProMotion" — so the rate the run
    /// actually held has to appear in the line.
    @Test func scrollReportLineNamesTheRefreshRateItHeld() {
        #expect(BenchBudget.scrollReportLine(dropped: 0, measured: 10, refreshHz: 60).contains("@ 60 Hz"))
        #expect(BenchBudget.scrollReportLine(dropped: 0, measured: 10, refreshHz: 120).contains("@ 120 Hz"))
    }

    @Test func scrollReportLineReadsTheProbesReturnedValues() {
        let line = BenchBudget.scrollReportLine(from: ["measured": 179, "dropped": 3, "hz": 120])

        #expect(line?.contains("3/179 frames dropped @ 120 Hz") == true)
    }

    /// JavaScript numbers arrive as `NSNumber`, including ones that came back
    /// as JS floats, so the parse must not depend on an exact Swift `Int`.
    @Test func scrollReportLineAcceptsValuesThatCameBackAsJavaScriptDoubles() {
        let line = BenchBudget.scrollReportLine(from: ["measured": 179.0, "dropped": 0.0, "hz": 62.0])

        #expect(line?.contains("0/179 frames dropped @ 62 Hz") == true)
    }

    @Test func scrollReportLineIsNilWhenTheProbeReturnedSomethingElse() {
        #expect(BenchBudget.scrollReportLine(from: [:]) == nil)
        #expect(BenchBudget.scrollReportLine(from: ["measured": 1, "dropped": 0]) == nil)
        #expect(BenchBudget.scrollReportLine(from: ["measured": "lots", "dropped": 0, "hz": 60]) == nil)
    }

    // MARK: - Which moments are measured at all

    /// Warm open and scrolling both moved from "can't be measured" to
    /// measured; leaving them in `unmeasuredReasons` would print a
    /// "not measured" line alongside the real number.
    @Test func warmOpenAndScrollingAreNoLongerReportedAsUnmeasurable() {
        #expect(BenchBudget.unmeasuredReasons["warm-open"] == nil)
        #expect(BenchBudget.unmeasuredReasons["scrolling"] == nil)
        #expect(BenchBudget.unmeasuredReasons["tab-switch"] != nil)
    }

    @Test func warmOpenCarriesTheBudgetContextDeclares() {
        #expect(BenchBudget.budget(for: "warm-open") == 150)
    }
}
