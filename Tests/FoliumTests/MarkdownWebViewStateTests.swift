import Testing
@testable import Folium

struct MarkdownWebViewStateTests {
    @Test func queuesContentRequestedBeforeTheShellFinishesLoading() {
        let state = MarkdownWebViewState()
        #expect(state.render(bodyHTML: "<p>one</p>") == nil)
    }

    @Test func shellFinishingDeliversTheQueuedContent() {
        let state = MarkdownWebViewState()
        _ = state.render(bodyHTML: "<p>one</p>")
        #expect(state.shellDidFinishLoading() == "<p>one</p>")
    }

    @Test func shellFinishingWithNothingQueuedReturnsNil() {
        let state = MarkdownWebViewState()
        #expect(state.shellDidFinishLoading() == nil)
    }

    @Test func onlyTheMostRecentlyQueuedContentSurvivesUntilTheShellLoads() {
        let state = MarkdownWebViewState()
        _ = state.render(bodyHTML: "<p>stale</p>")
        _ = state.render(bodyHTML: "<p>latest</p>")
        #expect(state.shellDidFinishLoading() == "<p>latest</p>")
    }

    @Test func rendersImmediatelyOnceTheShellHasLoaded() {
        let state = MarkdownWebViewState()
        _ = state.shellDidFinishLoading()
        #expect(state.render(bodyHTML: "<p>two</p>") == "<p>two</p>")
    }

    @Test func consumingTheQueueClearsItForNextTime() {
        let state = MarkdownWebViewState()
        _ = state.render(bodyHTML: "<p>one</p>")
        _ = state.shellDidFinishLoading()
        // Nothing new was queued since the shell loaded, and it's already
        // loaded, so a bare re-check delivers nothing stale.
        #expect(state.shellDidFinishLoading() == nil)
    }

    @Test func paintEventToConfirmIsNilWhenBenchIsDisabled() {
        // A real user's launch and every one of their live-reloads must
        // never pay for the paint-confirmation round trip.
        let state = MarkdownWebViewState()
        state.benchMarker = BenchMarker(getenv: { _ in nil })

        #expect(state.paintEventToConfirm() == nil)
        #expect(state.paintEventToConfirm() == nil)
    }

    @Test func paintEventToConfirmIsFirstPaintOnceThenReloadPaint() {
        let state = MarkdownWebViewState()
        state.benchMarker = BenchMarker(getenv: { $0 == "FOLIUM_BENCH" ? "1" : nil })

        #expect(state.paintEventToConfirm() == "first-paint")
        #expect(state.paintEventToConfirm() == "reload-paint")
        #expect(state.paintEventToConfirm() == "reload-paint")
    }

    @Test func doesNotRunTheScrollProbeWhenBenchIsDisabled() {
        let state = MarkdownWebViewState()
        state.benchMarker = BenchMarker(getenv: { _ in nil })

        #expect(!state.shouldRunScrollProbe(after: "reload-paint"))
    }

    /// The first paint is immediately followed by the live-reload
    /// measurement, and a scroll probe running through it would spoil both.
    @Test func doesNotRunTheScrollProbeOnTheFirstPaint() {
        let state = MarkdownWebViewState()
        state.benchMarker = BenchMarker(getenv: { $0 == "FOLIUM_BENCH" ? "1" : nil })

        #expect(!state.shouldRunScrollProbe(after: "first-paint"))
    }

    /// One probe per process, not per view: SwiftUI settles a single document
    /// through several web views, each with its own state.
    @Test func runsTheScrollProbeForOnlyOneStateInTheProcess() {
        let enabled = { BenchMarker(getenv: { $0 == "FOLIUM_BENCH" ? "1" : nil }) }
        let first = MarkdownWebViewState()
        first.benchMarker = enabled()
        let second = MarkdownWebViewState()
        second.benchMarker = enabled()

        let claims = [
            first.shouldRunScrollProbe(after: "reload-paint"),
            first.shouldRunScrollProbe(after: "reload-paint"),
            second.shouldRunScrollProbe(after: "reload-paint")
        ]

        #expect(claims.filter { $0 }.count <= 1)
    }
}
