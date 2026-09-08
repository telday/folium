import Foundation

/// Which in-app probe this bench run has armed, from FOLIUM_BENCH_PROBE.
///
/// One per run, chosen by `scripts/bench.sh`, because the probes cannot
/// share an app session. Measured: with the scroll and tab-switch probes
/// both armed alongside the live-reload measurement, live-reload reported a
/// number in 2 runs of 6 and scrolling in 2 of 6 — the scroll probe holds
/// the animation frames a repaint needs, and a repaint landing mid-scroll
/// counts against the frame budget. Run one at a time, each measurement gets
/// an app that is doing nothing else.
///
/// An earlier version tried to sequence them inside one session by watching
/// for the paint that drew different content. That inferred from app
/// behaviour what the script already knew, and SwiftUI settling a document
/// through a varying number of web views kept breaking the inference. The
/// script says which probe to run instead.
enum BenchProbe: String {
    /// Nothing armed: the moments `scripts/bench.sh` drives entirely from
    /// outside the process — cold launch, live-reload — need no help.
    case none
    /// `MarkdownPage.scrollProbeScript`, after the document paints.
    case scroll
    /// `DocumentWindowTabber`'s switch, once a second document is open.
    case tabSwitch = "tab-switch"

    static func current(
        getenv: (String) -> String? = { name in
            guard let cString = Foundation.getenv(name) else { return nil }
            return String(cString: cString)
        }
    ) -> BenchProbe {
        guard let raw = getenv("FOLIUM_BENCH_PROBE") else { return .none }
        return BenchProbe(rawValue: raw) ?? .none
    }
}
