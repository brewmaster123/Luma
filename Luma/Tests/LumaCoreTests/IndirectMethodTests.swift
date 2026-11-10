import XCTest
@testable import LumaCore

final class IndirectMethodTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  func testIntervalBoundsAndDefault() {
    XCTAssertEqual(IndirectMethodSettings().intervalMinutes, 30)
    XCTAssertEqual(IndirectMethodSettings(intervalMinutes: -1).intervalMinutes, 10)
    XCTAssertEqual(IndirectMethodSettings(intervalMinutes: 90).intervalMinutes, 60)
  }

  func testEveryIntegerIntervalBetweenTenAndSixtyIsAvailable() {
    for minutes in 10...60 {
      let settings = IndirectMethodSettings(intervalMinutes: minutes)
      XCTAssertEqual(settings.intervalMinutes, minutes)
      XCTAssertEqual(settings.nextSignal(startedAt: start, after: start),
        start.addingTimeInterval(Double(minutes * 60)))
    }
  }

  func testCadenceDoesNotDriftWithSoundDuration() {
    let settings = IndirectMethodSettings(intervalMinutes: 15)
    let first = settings.nextSignal(startedAt: start, after: start)
    XCTAssertEqual(first, start.addingTimeInterval(15 * 60))
    let second = settings.nextSignal(startedAt: start, after: first.addingTimeInterval(4))
    XCTAssertEqual(second, start.addingTimeInterval(30 * 60))
    XCTAssertEqual(settings.nextSignal(startedAt: start, after: second.addingTimeInterval(28)),
      start.addingTimeInterval(45 * 60))
  }

  func testMissedSignalsAreSkippedRatherThanReplayedTogether() {
    let settings = IndirectMethodSettings(intervalMinutes: 15)
    XCTAssertEqual(settings.nextSignal(startedAt: start, after: start.addingTimeInterval(70 * 60)),
      start.addingTimeInterval(75 * 60))
    XCTAssertEqual(settings.nextSignal(startedAt: start, after: start.addingTimeInterval(15 * 60)),
      start.addingTimeInterval(30 * 60))
  }

  func testOldStateAndSavedSelectionRemainReadable() throws {
    let old = LumaState()
    let oldDecoded = try JSONDecoder().decode(LumaState.self, from: JSONEncoder().encode(old))
    XCTAssertNil(oldDecoded.indirectMethod)
    var updated = old
    updated.indirectMethod = IndirectMethodSettings(intervalMinutes: 43)
    let decoded = try JSONDecoder().decode(LumaState.self, from: JSONEncoder().encode(updated))
    XCTAssertEqual(decoded.indirectMethod?.intervalMinutes, 43)
    let malformed = try JSONDecoder().decode(IndirectMethodSettings.self,
      from: Data("{\"intervalMinutes\":999}".utf8))
    XCTAssertEqual(malformed.validated.intervalMinutes, 60)
  }
}
