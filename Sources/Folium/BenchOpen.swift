import Foundation

/// Parsing for FOLIUM_BENCH_OPEN, the env var `scripts/bench.sh` uses to
/// tell `FoliumAppDelegate` to open a document the instant launch finishes
/// — see that file for why. Pulled out of the delegate itself so the env
/// lookup, C-string decode, and URL construction are unit-testable; the
/// delegate is only ever run by AppKit, at launch.
enum BenchOpen {
    /// The document to open at launch, or `nil` if FOLIUM_BENCH_OPEN is unset.
    static func url(
        getenv: (String) -> String? = { name in
            guard let cString = Foundation.getenv(name) else { return nil }
            return String(cString: cString)
        }
    ) -> URL? {
        guard let path = getenv("FOLIUM_BENCH_OPEN") else { return nil }
        return URL(fileURLWithPath: path)
    }
}
