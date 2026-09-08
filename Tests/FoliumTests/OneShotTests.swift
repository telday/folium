import Foundation
import Testing
@testable import Folium

struct OneShotTests {
    @Test func firstClaimSucceedsAndEveryLaterOneFails() {
        let oneShot = OneShot()

        #expect(oneShot.claim())
        #expect(!oneShot.claim())
        #expect(!oneShot.claim())
    }

    @Test func separateInstancesDoNotShareTheClaim() {
        #expect(OneShot().claim())
        #expect(OneShot().claim())
    }

    /// The reason this type exists rather than a `Bool` on the caller:
    /// SwiftUI can settle two document scenes at once, so the claim has to
    /// hold when several threads ask together. Exactly one wins.
    @Test func exactlyOneCallerWinsUnderConcurrentClaims() async {
        let oneShot = OneShot()
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask { oneShot.claim() }
            }
            return await group.reduce(into: 0) { count, won in count += won ? 1 : 0 }
        }

        #expect(winners == 1)
    }
}
