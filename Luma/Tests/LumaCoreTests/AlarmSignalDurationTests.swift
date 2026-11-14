import Foundation
import XCTest
@testable import LumaCore

final class AlarmSignalDurationTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)
  private func record(seconds: Int = 4) -> SystemAlarmRecord {
    .init(request: .init(key: "duration", ownerID: UUID(), kind: .smart, fireAt: start,
      title: "Luma", source: URL(fileURLWithPath: "/tone.wav"), stopAfterSeconds: seconds),
      soundName: "luma-alarm-4.wav")
  }
  func testDefaultAndInvalidSettingsRemainFourSeconds() {
    XCTAssertEqual(AlarmSignalDuration.defaultSeconds, 4)
    for value: Int? in [nil, Int.min, -1, 0, 2, 11, Int.max] {
      XCTAssertEqual(AlarmSignalDuration.validated(value), 4)
    }
  }
  func testEverySupportedDurationHasItsOwnAbsoluteDeadline() {
    for seconds in 3...10 {
      let value = record(seconds: seconds)
      XCTAssertEqual(value.stopDurationSeconds, seconds)
      XCTAssertEqual(value.stopAt.timeIntervalSince(start), Double(seconds))
      XCTAssertEqual(SystemAlarmPolicy.stopAction(record: value, alerting: true,
        now: start.addingTimeInterval(Double(seconds) - 0.01)), .wait(until: value.stopAt))
      XCTAssertEqual(SystemAlarmPolicy.stopAction(record: value, alerting: true,
        now: value.stopAt), .stop(lateBy: 0))
    }
  }
  func testLateUpdateDoesNotRestartTenSecondSignal() {
    XCTAssertEqual(SystemAlarmPolicy.stopAction(record: record(seconds: 10), alerting: true,
      now: start.addingTimeInterval(14)), .stop(lateBy: 4))
  }
  func testLegacySchemaThreeRecordWithoutDurationDefaultsToFour() throws {
    let data = try JSONEncoder().encode(record())
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "stopAfterSeconds")
    let oldData = try JSONSerialization.data(withJSONObject: object)
    let restored = try JSONDecoder().decode(SystemAlarmRecord.self, from: oldData)
    XCTAssertNil(restored.stopAfterSeconds)
    XCTAssertEqual(restored.stopAt.timeIntervalSince(start), 4)
  }
  func testNewLedgerRoundTripKeepsEachOccurrenceDuration() throws {
    var ledger = SystemAlarmLedger()
    ledger.records = [record(seconds: 3), record(seconds: 10)]
    let restored = try JSONDecoder().decode(SystemAlarmLedger.self, from: JSONEncoder().encode(ledger))
    XCTAssertEqual(restored.schema, 3)
    XCTAssertEqual(restored.records.map(\.stopDurationSeconds), [3, 10])
    XCTAssertEqual(restored.records.map(\.stopAt), ledger.records.map(\.stopAt))
  }
  func testInvalidStoredDurationUsesSafeDefault() throws {
    var value = record(seconds: 10); value.stopAfterSeconds = 600
    let restored = try JSONDecoder().decode(SystemAlarmRecord.self, from: JSONEncoder().encode(value))
    XCTAssertEqual(restored.stopDurationSeconds, 4)
  }
  func testOldRecordDecoderCanReadNewAdditiveField() throws {
    // Matches 0.9.6's stored record, without the new optional property.
    struct OldRecord: Decodable {
      var id: UUID; var key: String; var ownerID: UUID; var kind: SystemAlarmKind
      var fireAt: Date; var title: String; var soundName: String; var pending: Bool
    }
    let value = record(seconds: 10)
    let old = try JSONDecoder().decode(OldRecord.self, from: JSONEncoder().encode(value))
    XCTAssertEqual(old.id, value.id)
    XCTAssertEqual(old.fireAt, start)
    XCTAssertEqual(old.soundName, "luma-alarm-4.wav")
  }
  func testDefaultInterruptionBudgetIsUnchangedAndTenSecondsIsProtected() {
    let standard = AlarmInterruptionWindow(now: start, stopAt: start.addingTimeInterval(4))
    XCTAssertEqual(standard.recoveryDelay, 8); XCTAssertEqual(standard.leaseDelay, 10)
    let longest = AlarmInterruptionWindow(now: start, stopAt: start.addingTimeInterval(10))
    XCTAssertEqual(longest.recoveryDelay, 14); XCTAssertEqual(longest.leaseDelay, 16)
  }
  func testInterruptionBudgetsStayFiniteAndBounded() {
    for deadline in [nil, start.addingTimeInterval(-100), start.addingTimeInterval(10_000),
      Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
      let window = AlarmInterruptionWindow(now: start, stopAt: deadline)
      XCTAssertTrue((8.0...14.0).contains(window.recoveryDelay))
      XCTAssertTrue((10.0...16.0).contains(window.leaseDelay))
    }
  }
}
