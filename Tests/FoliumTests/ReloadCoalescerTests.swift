import Testing
@testable import Folium

/// The debounce that keeps an autosave from turning into a reload storm
/// (issue #7).
///
/// The scheduler is injected, so these close the window by hand instead of
/// sleeping through it. Timing is what's under test, and a test that slept
/// would be both slow and only probably right.
@MainActor
struct ReloadCoalescerTests {
    @Test func nothingReloadsUntilTheWindowElapses() {
        let scheduler = ManualScheduler()
        let reloads = Counter()
        let coalescer = ReloadCoalescer(scheduler: scheduler, reload: reloads.increment)

        coalescer.noteChange()

        #expect(reloads.total == 0)
    }

    @Test func aSingleChangeReloadsOnceTheWindowElapses() {
        let scheduler = ManualScheduler()
        let reloads = Counter()
        let coalescer = ReloadCoalescer(scheduler: scheduler, reload: reloads.increment)

        coalescer.noteChange()
        scheduler.elapse()

        #expect(reloads.total == 1)
    }

    @Test func aBurstOfChangesCollapsesIntoOneReload() {
        let scheduler = ManualScheduler()
        let reloads = Counter()
        let coalescer = ReloadCoalescer(scheduler: scheduler, reload: reloads.increment)

        for _ in 0..<10 { coalescer.noteChange() }
        scheduler.elapse()

        // The whole point: ten notifications, one re-read and one repaint.
        #expect(scheduler.scheduledDelays.count == 1)
        #expect(reloads.total == 1)
    }

    @Test func theWindowRunsFromTheFirstChangeSoASteadyStreamStillReloads() {
        let scheduler = ManualScheduler()
        let reloads = Counter()
        let coalescer = ReloadCoalescer(scheduler: scheduler, reload: reloads.increment)

        // A file being written continuously. A debounce that restarted on
        // every notification would never reload this at all.
        for _ in 0..<3 {
            coalescer.noteChange()
            coalescer.noteChange()
            scheduler.elapse()
        }

        #expect(reloads.total == 3)
    }

    @Test func aChangeAfterAReloadOpensAFreshWindow() {
        let scheduler = ManualScheduler()
        let reloads = Counter()
        let coalescer = ReloadCoalescer(scheduler: scheduler, reload: reloads.increment)

        coalescer.noteChange()
        scheduler.elapse()
        coalescer.noteChange()
        scheduler.elapse()

        #expect(reloads.total == 2)
    }

    @Test func aChangeThatLandsDuringTheReloadIsNotSwallowed() {
        // The race a save can genuinely lose: the file is written again while
        // the previous version is being read. If the window closed only after
        // the reload, that write would never be picked up.
        let scheduler = ManualScheduler()
        let reloads = Counter()
        var coalescer: ReloadCoalescer?
        coalescer = ReloadCoalescer(scheduler: scheduler) {
            reloads.increment()
            if reloads.total == 1 { coalescer?.noteChange() }
        }

        coalescer?.noteChange()
        scheduler.elapse()
        scheduler.elapse()

        #expect(reloads.total == 2)
    }

    @Test func aWindowThatOutlivesTheCoalescerDoesNothing() {
        // The window closing after the document itself has gone away — the
        // window closed while the file's own document window was closing.
        // `[weak self]` is what keeps that from touching a deallocated
        // instance; this proves the closure gives up cleanly instead.
        let scheduler = ManualScheduler()
        let reloads = Counter()
        var coalescer: ReloadCoalescer? = ReloadCoalescer(scheduler: scheduler, reload: reloads.increment)

        coalescer?.noteChange()
        coalescer = nil
        scheduler.elapse()

        #expect(reloads.total == 0)
    }

    @Test func theRealSchedulerDefersTheWorkAndThenRunsIt() async {
        // The one thing the manual scheduler can't show: the real one waits,
        // and then actually fires.
        let ran = Counter()

        SleepingReloadScheduler().schedule(after: .milliseconds(10), run: ran.increment)
        #expect(ran.total == 0)

        try? await Task.sleep(for: .milliseconds(300))
        #expect(ran.total == 1)
    }

    @Test func theWindowDefaultsToTheLiveReloadPolicy() {
        let scheduler = ManualScheduler()
        let coalescer = ReloadCoalescer(scheduler: scheduler, reload: {})

        coalescer.noteChange()

        #expect(scheduler.scheduledDelays == [LiveReload.coalescingWindow])
    }
}

/// A clock the test advances. `elapse()` runs whatever was scheduled, which is
/// what "the window closed" means.
@MainActor
private final class ManualScheduler: ReloadScheduler {
    private(set) var scheduledDelays: [Duration] = []
    private var pending: [@MainActor () -> Void] = []

    func schedule(after delay: Duration, run body: @escaping @MainActor () -> Void) {
        scheduledDelays.append(delay)
        pending.append(body)
    }

    func elapse() {
        let due = pending
        pending = []
        for body in due { body() }
    }
}

@MainActor
private final class Counter {
    private(set) var total = 0

    func increment() {
        total += 1
    }
}
