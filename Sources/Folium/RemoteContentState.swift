import Combine
import Foundation

/// One open document's remote-content policy (issue #19).
///
/// Deliberately per-document and never persisted: one `@StateObject` per
/// document window, backed by nothing. Trusting one file must not weaken the
/// no-network floor anywhere else, and closing a document forgets the choice
/// — the same bargain a mail client's "Load Remote Content" makes.
///
/// `allow()` is one-way. Nothing turns remote content back off, because the
/// requests it permitted have already gone out by then; an "unload" button
/// would only pretend otherwise.
///
/// Every method here checks whether it is about to change anything before it
/// writes. `@Published` announces an assignment, not a change, so publishing
/// `false` over `false` still redraws every view watching this object — and
/// one of those views is the web view whose page produced the report.
@MainActor
final class RemoteContentState: ObservableObject {
    /// Whether the document on screen has remote content the user could
    /// load. Drives the offer bar in `FoliumApp`'s `DocumentView`.
    @Published private(set) var hasBlockedContent = false

    /// Whether the user has opted this document in. `MarkdownWebView` reads
    /// this to choose which shell to load.
    @Published private(set) var isAllowed = false

    /// Records a Content-Security-Policy refusal reported by
    /// `Resources/remote-content.js`.
    func noteViolation(directive: String, blockedURI: String) {
        guard !isAllowed, !hasBlockedContent else { return }
        guard RemoteContent.isLoadable(directive: directive, blockedURI: blockedURI) else { return }
        hasBlockedContent = true
    }

    /// Called as the web view is about to replace the document's content —
    /// a live reload, or the first render. What was blocked belongs to the
    /// content coming off screen, so the offer starts again from nothing.
    func documentWillRender() {
        clearOffer()
    }

    /// Opts this document in, for as long as its window stays open.
    func allow() {
        guard !isAllowed else { return }
        isAllowed = true
        clearOffer()
    }

    /// The one place `hasBlockedContent` is lowered, so the check that it
    /// needs lowering at all cannot be forgotten at one of the call sites.
    private func clearOffer() {
        guard hasBlockedContent else { return }
        hasBlockedContent = false
    }
}
