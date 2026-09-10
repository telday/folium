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
    ///
    /// The `isAllowed` check guards a narrow window rather than the common
    /// case: once the opt-in shell is loaded it permits the images that were
    /// refused, so there is normally nothing left to report. But `allow()`
    /// returns before the reload finishes, and the strict shell is still
    /// live until it does — a live reload landing in that gap would
    /// otherwise raise an offer the user has already taken.
    func note(_ violation: RemoteContentViolation) {
        guard !isAllowed, !hasBlockedContent, violation.isLoadable else { return }
        hasBlockedContent = true
    }

    /// Called as the web view is about to replace the document's content —
    /// a live reload, or the first render. What was blocked belongs to the
    /// content coming off screen, so the offer starts again from nothing.
    func documentWillRender() {
        clearOffer()
    }

    /// Opts this document in, for as long as its window stays open.
    ///
    /// The choice outlives a live reload: the document is still the same
    /// file, and re-asking on every save would make the app unusable beside
    /// the editor that `CONTEXT.md` names as the workflow. It does not
    /// outlive the window — see the type comment.
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
