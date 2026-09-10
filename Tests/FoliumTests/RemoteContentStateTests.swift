import Combine
import Testing
@testable import Folium

/// One document's remote-content policy (issue #19): what raises the offer,
/// what clears it, and what opting in does.
@MainActor
struct RemoteContentStateTests {
    @Test func blocksAndOffersNothingBeforeAnythingIsReported() {
        let state = RemoteContentState()
        #expect(!state.hasBlockedContent)
        #expect(!state.isAllowed)
    }

    @Test func aBlockedRemoteImageRaisesTheOffer() {
        let state = RemoteContentState()
        state.noteViolation(directive: "img-src", blockedURI: "https://example.com/badge.svg")
        #expect(state.hasBlockedContent)
    }

    @Test func aRefusalTheOptInCouldNotFixRaisesNothing() {
        let state = RemoteContentState()
        state.noteViolation(directive: "style-src-elem", blockedURI: "https://example.com/theme.css")
        #expect(!state.hasBlockedContent)
    }

    /// What was blocked belongs to the document coming off screen. A live
    /// reload that removes the last remote image has to take the offer with
    /// it, or the bar goes on claiming something the file no longer says.
    @Test func aNewRenderClearsWhatTheLastOneBlocked() {
        let state = RemoteContentState()
        state.noteViolation(directive: "img-src", blockedURI: "https://example.com/badge.svg")
        state.documentWillRender()
        #expect(!state.hasBlockedContent)
    }

    @Test func optingInDismissesTheOffer() {
        let state = RemoteContentState()
        state.noteViolation(directive: "img-src", blockedURI: "https://example.com/badge.svg")
        state.allow()
        #expect(state.isAllowed)
        #expect(!state.hasBlockedContent)
    }

    /// After opting in, the opt-in shell is what refuses anything still
    /// blocked — a remote stylesheet, say. Raising the offer again would
    /// show a "Load" button that has already been pressed and cannot help.
    @Test func aRefusalAfterOptingInDoesNotRaiseTheOfferAgain() {
        let state = RemoteContentState()
        state.allow()
        state.noteViolation(directive: "img-src", blockedURI: "https://example.com/badge.svg")
        #expect(!state.hasBlockedContent)
    }

    @Test func optingInStaysOn() {
        let state = RemoteContentState()
        state.allow()
        state.documentWillRender()
        state.allow()
        #expect(state.isAllowed)
    }

    /// The regression guard for the render loop this feature first shipped
    /// with. `@Published` announces an assignment, not a change, so writing
    /// `false` over `false` still redraws every observer — and one of them
    /// is the web view whose page sends these reports on every render.
    /// Measured at ~10,000 injections a second before the setters were
    /// guarded.
    @Test func reportingNothingNewAnnouncesNothing() {
        let state = RemoteContentState()
        var announcements = 0
        let subscription = state.objectWillChange.sink { _ in announcements += 1 }
        defer { subscription.cancel() }

        // A render with nothing blocked, three times over: the shape of an
        // ordinary document being re-rendered.
        state.documentWillRender()
        state.documentWillRender()
        state.documentWillRender()
        #expect(announcements == 0)

        // A refusal already reported is not news either.
        state.noteViolation(directive: "img-src", blockedURI: "https://example.com/badge.svg")
        state.noteViolation(directive: "img-src", blockedURI: "https://example.com/other.svg")
        #expect(announcements == 1)
    }

    @Test func realChangesAreStillAnnounced() {
        let state = RemoteContentState()
        var announcements = 0
        let subscription = state.objectWillChange.sink { _ in announcements += 1 }
        defer { subscription.cancel() }

        state.noteViolation(directive: "img-src", blockedURI: "https://example.com/badge.svg")
        state.documentWillRender()
        state.allow()
        #expect(announcements == 3)
    }
}
