import Foundation

/// Instrumentation for the latency budgets in `CONTEXT.md`. Emits a
/// timestamped marker line to stderr, but only when the FOLIUM_BENCH
/// environment variable is set — a release user must never see this.
///
/// A marker carries a wall-clock timestamp (seconds since the Unix epoch),
/// not a duration. A duration measured entirely inside this process cannot
/// see process spawn, dyld linking, or AppKit start-up — the part of cold
/// launch a user actually feels happens before any of our code runs.
/// `scripts/bench.sh` takes its own wall-clock reading immediately before it
/// execs the app, so subtracting that reading from a marker's timestamp
/// yields a duration that includes launch itself. Both readings come from
/// the same clock (`Date`'s epoch, matched in the script by Python's
/// `time.time()`), which is what makes the subtraction valid across the two
/// processes.
struct BenchMarker: Sendable {
    /// Injected so tests can supply a fixed timestamp instead of the real
    /// wall clock.
    private let now: @Sendable () -> Double

    /// Injected lookup of FOLIUM_BENCH so tests can simulate it being set or
    /// unset without touching the real environment.
    private let getenv: @Sendable (String) -> String?

    /// Injected so tests can capture what would have gone to stderr instead
    /// of writing to the real file descriptor.
    private let write: @Sendable (Data) -> Void

    init(
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
        getenv: @escaping @Sendable (String) -> String? = {
            guard let cString = Foundation.getenv($0) else { return nil }
            return String(cString: cString)
        },
        write: @escaping @Sendable (Data) -> Void = { FileHandle.standardError.write($0) }
    ) {
        self.now = now
        self.getenv = getenv
        self.write = write
    }

    /// Whether FOLIUM_BENCH is set. Exposed so a caller can skip work that
    /// only exists to be measured — not just the write `mark` already skips,
    /// but the cost of *producing* something to write, which for a paint
    /// confirmation is an extra `WKWebView` round trip a real user must
    /// never pay for. See `MarkdownWebViewState.paintEventToConfirm`.
    var isEnabled: Bool {
        getenv("FOLIUM_BENCH") != nil
    }

    /// Emit a marker line if FOLIUM_BENCH is set. A complete no-op
    /// otherwise: no clock read, no formatting, nothing written.
    ///
    /// Deliberately stateless — there is no "first call" special case and
    /// no shared mutable state, so calling this from several places
    /// concurrently is never a data race, and unit tests can call it in any
    /// order without one leaking into another.
    /// `detail`, when given, is appended as a fourth field. Paints carry the
    /// size of the body they drew there, which is what lets
    /// `scripts/bench.sh` tell the repaint it asked for from an unrelated
    /// view settling at the same moment — both are paints, but only one
    /// drew different content.
    func mark(_ event: String, detail: String? = nil) {
        guard isEnabled else { return }
        writeRaw(Self.formatMarkerLine(event: event, timestamp: now(), detail: detail))
    }

    /// Writes `line` verbatim, gated the same way `mark` is. For output that
    /// isn't a `FOLIUM_BENCH <event> <timestamp>` marker — a pre-formatted
    /// report line, or the budget table `scripts/bench.sh` reads instead of
    /// keeping its own copy of `BenchBudget.budgets`.
    func writeLine(_ line: String) {
        guard isEnabled else { return }
        writeRaw(line + "\n")
    }

    /// Marks `startEvent` and `endEvent` around `body`, and — only under
    /// FOLIUM_BENCH — also writes the full budget report line for
    /// `reportEvent`, computed from the real gap between the two marks.
    /// `render` is the only budgeted moment that starts and ends entirely
    /// inside this process: cold launch and live-reload both need a
    /// wall-clock reading from outside it (`scripts/bench.sh` takes that
    /// reading), so this is the one moment that can report its own
    /// comparison against `BenchBudget` rather than handing raw numbers to
    /// the shell to compare itself.
    @discardableResult
    func measure<T>(_ startEvent: String, _ endEvent: String, reportAs reportEvent: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = now()
        let result = body()
        let end = now()
        writeRaw(Self.formatMarkerLine(event: startEvent, timestamp: start))
        writeRaw(Self.formatMarkerLine(event: endEvent, timestamp: end))
        let report = BenchBudget.reportLine(event: reportEvent, measuredMs: (end - start) * 1000)
        writeRaw("FOLIUM_BENCH_REPORT \(reportEvent) \(report)\n")
        return result
    }

    private func writeRaw(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        write(data)
    }

    /// Formats one marker line. Pure, and kept separate from `mark` so the
    /// wire format can be unit-tested without an environment or a clock.
    static func formatMarkerLine(event: String, timestamp: Double, detail: String? = nil) -> String {
        let suffix = detail.map { " \($0)" } ?? ""
        return "FOLIUM_BENCH \(event) \(String(format: "%.6f", timestamp))\(suffix)\n"
    }
}
