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

    @Test func doesNotConfirmPaintsWhenBenchIsDisabled() {
        // A real user's launch and every one of their live-reloads must
        // never pay for the paint-confirmation round trip.
        let state = MarkdownWebViewState()
        state.benchMarker = BenchMarker(getenv: { _ in nil })

        #expect(!state.shouldConfirmPaint())
    }

    @Test func confirmsEveryPaintUnderBench() {
        let state = MarkdownWebViewState()
        state.benchMarker = BenchMarker(getenv: { $0 == "FOLIUM_BENCH" ? "1" : nil })

        // Every paint, not just the first: naming them per view is what
        // broke the live-reload measurement, because a reload whose
        // injection landed in a newly created view called itself the first
        // paint. `scripts/bench.sh` matches paints to requests instead.
        #expect(state.shouldConfirmPaint())
        #expect(state.shouldConfirmPaint())
    }

    /// The probe a run armed decides this, not anything the app infers from
    /// its own paints. An earlier version watched for the paint that drew
    /// different content, to place itself after the live-reload measurement;
    /// SwiftUI settling a document through a varying number of web views
    /// kept breaking that inference, so `scripts/bench.sh` — which knows
    /// what it asked for — says which probe to run instead.
    ///
    /// One test, not several: the claim is process-wide by design, so a
    /// second test exercising it would race this one for the single claim.
    @Test func runsTheScrollProbeOnlyForTheRunThatArmedItAndOnlyOnce() {
        #expect(!MarkdownWebViewState.shouldRunScrollProbe(probe: .none))
        #expect(!MarkdownWebViewState.shouldRunScrollProbe(probe: .tabSwitch))

        #expect(MarkdownWebViewState.shouldRunScrollProbe(probe: .scroll))
        // Once per process, however many views paint afterwards.
        #expect(!MarkdownWebViewState.shouldRunScrollProbe(probe: .scroll))
        #expect(!MarkdownWebViewState.shouldRunScrollProbe(probe: .scroll))
    }
}
