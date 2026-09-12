import Foundation
import XCTest
@testable import LumaCore

final class AlarmStopWindowTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)
  func testVoiceLengthDeterminesDeadline() throws {
    let window = try XCTUnwrap(AlarmStopWindow(startsAt: start, duration: 3.75))
    XCTAssertEqual(window.endsAt.timeIntervalSince(start), 3.75, accuracy: 0.001)
    XCTAssertFalse(window.hasExpired(at: start.addingTimeInterval(3.74)))
    XCTAssertTrue(window.hasExpired(at: start.addingTimeInterval(3.75)))
  }
  func testLateResumeNeverRestartsFullDuration() throws {
    let window = try XCTUnwrap(AlarmStopWindow(startsAt: start, duration: 28))
    XCTAssertEqual(window.remaining(at: start.addingTimeInterval(120)), 0)
    XCTAssertTrue(window.hasExpired(at: start.addingTimeInterval(120)))
  }
  func testInvalidDurationsAreRejected() {
    for duration in [0, -1, Double.nan, .infinity, 29, 1800] {
      XCTAssertNil(AlarmStopWindow(startsAt: start, duration: duration))
    }
  }
  func testPersistedWindowKeepsItsOriginalDeadline() throws {
    let original = try XCTUnwrap(AlarmStopWindow(startsAt: start, duration: 8))
    let restored = try JSONDecoder().decode(AlarmStopWindow.self, from: JSONEncoder().encode(original))
    XCTAssertEqual(original, restored)
    XCTAssertEqual(restored.remaining(at: start.addingTimeInterval(6)), 2)
  }
  func testCorruptedStoredDurationFailsDecoding() {
    let data = Data(#"{"startsAt":0,"duration":-2}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(AlarmStopWindow.self, from: data))
  }
  func testOneShotHistoryIsNotMovedToTomorrow() {
    var alarm = LumaAlarm(); alarm.onceAt = start
    XCTAssertNil(alarm.mostRecentOccurrence(at: start.addingTimeInterval(-1)))
    XCTAssertEqual(alarm.mostRecentOccurrence(at: start.addingTimeInterval(30)), start)
  }
  func testWeeklyPreviousAndNextOccurrenceStraddleNow() throws {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 7, minute: 1)))
    var alarm = LumaAlarm(); alarm.hour = 7; alarm.minute = 0; alarm.weekdays = [4]
    let previous = try XCTUnwrap(alarm.mostRecentOccurrence(at: now, calendar: cal))
    let next = try XCTUnwrap(alarm.next(after: now, calendar: cal))
    XCTAssertEqual(now.timeIntervalSince(previous), 60)
    XCTAssertEqual(next.timeIntervalSince(previous), 7 * 86400)
  }
  func testDisabledAlarmHasNoPreviousFiring() {
    var alarm = LumaAlarm(); alarm.onceAt = start; alarm.enabled = false
    XCTAssertNil(alarm.mostRecentOccurrence(at: start.addingTimeInterval(30)))
  }
}
