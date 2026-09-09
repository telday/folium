import Foundation
import Testing
@testable import Folium

/// Unit tests for `BenchMarker`. `write` and `now` are injected so these can
/// assert on the exact bytes that would go to stderr, rather than the
/// `#expect(true)` placeholders a real `FileHandle` would have forced.
struct BenchMarkerTests {
    @Test func isACompleteNoOpWhenBenchEnvIsUnset() {
        let sink = RecordingSink()
        let clockReads = Counter()
        let marker = BenchMarker(
            now: { clockReads.increment(); return 1.0 },
            getenv: { _ in nil },
            write: sink.record
        )

        marker.mark("first-paint")

        #expect(sink.writes.isEmpty)
        // No clock read either: an event that never gets written shouldn't
        // even pay for a timestamp.
        #expect(clockReads.total == 0)
    }

    @Test func writesAFormattedLineWhenBenchEnvIsSet() {
        let sink = RecordingSink()
        let marker = BenchMarker(
            now: { 1_700_000_000.123456 },
            getenv: { $0 == "FOLIUM_BENCH" ? "1" : nil },
            write: sink.record
        )

        marker.mark("first-paint")

        #expect(sink.writes.count == 1)
        let line = String(data: sink.writes[0], encoding: .utf8)
        #expect(line == "FOLIUM_BENCH first-paint 1700000000.123456\n")
    }

    @Test func looksUpExactlyTheFoliumBenchKey() {
        let lookups = StringLog()
        let marker = BenchMarker(
            now: { 0 },
            getenv: { lookups.record($0); return nil },
            write: { _ in }
        )

        marker.mark("render-start")

        #expect(lookups.entries == ["FOLIUM_BENCH"])
    }

    @Test func hasNoSharedStateAcrossCalls() {
        // BenchMarker used to latch a "launch already emitted" flag in a
        // global. Rewritten to be stateless, so calling it many times, in
        // any order, writes one line per call — nothing carries over.
        let sink = RecordingSink()
        let marker = BenchMarker(
            now: { 5.0 },
            getenv: { $0 == "FOLIUM_BENCH" ? "1" : nil },
            write: sink.record
        )

        marker.mark("render-start")
        marker.mark("render-start")
        marker.mark("render-end")

        #expect(sink.writes.count == 3)
    }

    @Test func formatMarkerLineEmbedsTheEventNameAndSixDecimalTimestamp() {
        let line = BenchMarker.formatMarkerLine(event: "reload-paint", timestamp: 12.5)

        #expect(line == "FOLIUM_BENCH reload-paint 12.500000\n")
    }

    @Test func isEnabledReflectsTheEnvVar() {
        #expect(BenchMarker(getenv: { $0 == "FOLIUM_BENCH" ? "1" : nil }).isEnabled)
        #expect(!BenchMarker(getenv: { _ in nil }).isEnabled)
    }

    @Test func writeLineIsACompleteNoOpWhenBenchEnvIsUnset() {
        let sink = RecordingSink()
        let marker = BenchMarker(getenv: { _ in nil }, write: sink.record)

        marker.writeLine("FOLIUM_BENCH_BUDGET cold-launch 500")

        #expect(sink.writes.isEmpty)
    }

    @Test func writeLineWritesTheLineVerbatimPlusANewline() {
        let sink = RecordingSink()
        let marker = BenchMarker(getenv: { $0 == "FOLIUM_BENCH" ? "1" : nil }, write: sink.record)

        marker.writeLine("FOLIUM_BENCH_BUDGET cold-launch 500")

        #expect(sink.writes.count == 1)
        let line = String(data: sink.writes[0], encoding: .utf8)
        #expect(line == "FOLIUM_BENCH_BUDGET cold-launch 500\n")
    }

    @Test func measureRunsTheBodyAndReturnsItsResultEvenWhenDisabled() {
        let marker = BenchMarker(getenv: { _ in nil })

        let result = marker.measure("render-start", "render-end", reportAs: "render") { 42 }

        #expect(result == 42)
    }

    @Test func measureWritesNothingWhenBenchEnvIsUnset() {
        let sink = RecordingSink()
        let marker = BenchMarker(getenv: { _ in nil }, write: sink.record)

        _ = marker.measure("render-start", "render-end", reportAs: "render") { "x" }

        #expect(sink.writes.isEmpty)
    }

    @Test func measureWritesStartEndAndAFullReportLineWhenEnabled() {
        let sink = RecordingSink()
        // 0.125 is exact in binary floating point (1/8), so the elapsed
        // milliseconds land on a round number instead of tripping over
        // Double's usual rounding — the point of this test is the report
        // line's content, not float precision.
        let clock = SequentialClock([100.0, 100.125])
        let marker = BenchMarker(
            now: { clock.next() },
            getenv: { $0 == "FOLIUM_BENCH" ? "1" : nil },
            write: sink.record
        )

        let result = marker.measure("render-start", "render-end", reportAs: "render") { "rendered" }

        #expect(result == "rendered")
        let lines = sink.writes.compactMap { String(data: $0, encoding: .utf8) }
        #expect(lines.count == 3)
        #expect(lines[0] == "FOLIUM_BENCH render-start 100.000000\n")
        #expect(lines[1] == "FOLIUM_BENCH render-end 100.125000\n")
        #expect(lines[2].hasPrefix("FOLIUM_BENCH_REPORT "))
        #expect(lines[2].contains("125 ms"))
    }
}

/// Hands out fixed timestamps in order, so a test can control what `measure`
/// sees for its start and end reads without depending on the real clock.
/// Same `@unchecked Sendable` rationale as `RecordingSink`.
private final class SequentialClock: @unchecked Sendable {
    private var values: [Double]

    init(_ values: [Double]) {
        self.values = values
    }

    func next() -> Double {
        values.isEmpty ? 0 : values.removeFirst()
    }
}

/// Captures what a `BenchMarker` would have written, without touching the
/// real file descriptor. `@unchecked Sendable`: a stored `@Sendable`
/// property on `BenchMarker` needs a Sendable closure, and this test double
/// is only ever touched from one thread within a single test.
private final class RecordingSink: @unchecked Sendable {
    private(set) var writes: [Data] = []

    func record(_ data: Data) {
        writes.append(data)
    }
}

/// Records the strings a `getenv` stub was asked to look up. Same
/// `@unchecked Sendable` rationale as `RecordingSink`.
private final class StringLog: @unchecked Sendable {
    private(set) var entries: [String] = []

    func record(_ value: String) {
        entries.append(value)
    }
}

/// A plain call counter. Same `@unchecked Sendable` rationale as
/// `RecordingSink`.
private final class Counter: @unchecked Sendable {
    private(set) var total = 0

    func increment() {
        total += 1
    }

    /// Paints carry the size of the body they drew, which is what lets
    /// `scripts/bench.sh` tell a repaint from a view settling on the same
    /// content at the same moment.
    @Test func markAppendsADetailFieldWhenGivenOne() {
        let sink = RecordingSink()
        let marker = BenchMarker(
            now: { 7.0 },
            getenv: { $0 == "FOLIUM_BENCH" ? "1" : nil },
            write: sink.record
        )

        marker.mark("paint", detail: "4096")

        #expect(String(data: sink.writes[0], encoding: .utf8) == "FOLIUM_BENCH paint 7.000000 4096\n")
    }

    @Test func formatMarkerLineOmitsTheDetailFieldWhenThereIsNone() {
        #expect(BenchMarker.formatMarkerLine(event: "paint", timestamp: 7) == "FOLIUM_BENCH paint 7.000000\n")
        #expect(
            BenchMarker.formatMarkerLine(event: "paint", timestamp: 7, detail: "12")
                == "FOLIUM_BENCH paint 7.000000 12\n"
        )
    }
}
