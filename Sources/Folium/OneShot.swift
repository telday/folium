import Foundation

/// A claim that succeeds for exactly one caller, however many ask.
///
/// `MarkdownWebViewState` needs "do this once per process" for the scroll
/// probe, across state objects it neither owns nor can order: SwiftUI
/// creates a `MarkdownWebView` — and so a state — each time it re-evaluates
/// a document's scene, several times for one open document. A flag on the
/// instance would fire once per view; a bare `static var` would be a data
/// race the moment two scenes settle at once.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    /// `true` for the first caller, `false` for every caller after it.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}
