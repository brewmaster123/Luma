import XCTest
@testable import LumaCore

final class WatchCuePlanTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)
  func testPlanRetainsIndependentOccurrencesAndExcludesElapsedOnes() throws {
    let cues = [-2.0, 1800, 3600].map { WatchCue(id: UUID(), fireAt: now.addingTimeInterval($0), title: "Luma") }
    let plan = WatchCuePlan(revision: 2, createdAt: now, cues: cues)
    XCTAssertEqual(plan.validated(after: now)?.map(\.id), Array(cues.dropFirst()).map(\.id))
    XCTAssertEqual(try JSONDecoder().decode(WatchCuePlan.self, from: JSONEncoder().encode(plan)), plan)
  }
  func testDelayedOlderPlanCannotResurrectCancelledWatchSignals() {
    let earlier = WatchCuePlan(revision: 1, createdAt: now,
      cues: [.init(id: UUID(), fireAt: now.addingTimeInterval(60), title: "Luma")])
    let cancelled = WatchCuePlan(revision: 2, createdAt: now, cues: [])
    XCTAssertFalse(WatchCuePlan.shouldReplace(current: cancelled, incoming: earlier))
    XCTAssertTrue(WatchCuePlan.shouldReplace(current: earlier, incoming: cancelled))
    XCTAssertTrue(WatchCuePlan.shouldReplace(current: cancelled, incoming: cancelled))
  }
  func testDuplicateIDsOverlargeHorizonAndOversizedPlansAreRejected() {
    let cue = WatchCue(id: UUID(), fireAt: now.addingTimeInterval(1800), title: "Luma")
    XCTAssertNil(WatchCuePlan(revision: 1, createdAt: now, cues: [cue, cue]).validated(after: now))
    XCTAssertNil(WatchCuePlan(revision: 1, createdAt: now,
      cues: [.init(id: UUID(), fireAt: now.addingTimeInterval(43201), title: "Luma")]).validated(after: now))
    XCTAssertNil(WatchCuePlan(revision: 1, createdAt: now,
      cues: (0..<61).map { _ in .init(id: UUID(), fireAt: cue.fireAt, title: "Luma") }).validated(after: now))
  }
}
