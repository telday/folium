import Foundation
import Testing
@testable import Folium

struct BenchProbeTests {
    @Test func noProbeIsArmedWhenTheEnvVarIsUnset() {
        #expect(BenchProbe.current(getenv: { _ in nil }) == .none)
    }

    @Test func readsEachProbeByName() {
        #expect(BenchProbe.current(getenv: { _ in "scroll" }) == .scroll)
        #expect(BenchProbe.current(getenv: { _ in "tab-switch" }) == .tabSwitch)
        #expect(BenchProbe.current(getenv: { _ in "none" }) == .none)
    }

    /// An unrecognised value arms nothing rather than failing the run: a
    /// bench run that measures less is recoverable, one that refuses to
    /// start measures nothing at all.
    @Test func anUnknownProbeNameArmsNothing() {
        #expect(BenchProbe.current(getenv: { _ in "wobble" }) == .none)
        #expect(BenchProbe.current(getenv: { _ in "" }) == .none)
    }

    @Test func looksUpExactlyTheFoliumBenchProbeKey() {
        var lookedUp: [String] = []
        _ = BenchProbe.current(getenv: { lookedUp.append($0); return nil })

        #expect(lookedUp == ["FOLIUM_BENCH_PROBE"])
    }
}
