import Foundation
import XCTest
@testable import LumaCore

final class AlarmKitWaveMigrationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)
  private func record(_ key: String, seconds: Double, owner: UUID) -> SystemAlarmRecord {
    .init(request: .init(key: key, ownerID: owner, kind: .indirect,
      fireAt: now.addingTimeInterval(seconds), title: "Luma",
      source: URL(fileURLWithPath: "/original.caf")), soundName: "luma-cue4-old.caf")
  }
  func testBothEarlierTransportsRetainSessionOriginAndFutureEligibility() {
    for schema in [1, 2] {
      var ledger = SystemAlarmLedger(); ledger.schema = schema
      var signal = SignalSettings(); signal.voiceID = UUID()
      let session = IndirectAlarmSession(settings: .init(intervalMinutes: 30),
        signal: signal, startedAt: now.addingTimeInterval(-600))
      ledger.indirectSession = session
      ledger.records = [record("past", seconds: -30, owner: session.id),
        record("future", seconds: 1200, owner: session.id)]
      XCTAssertTrue(ledger.migrateToAlarmKitWave(now: now))
      XCTAssertEqual(ledger.schema, 3)
      XCTAssertEqual(ledger.indirectSession, session)
      XCTAssertEqual(ledger.handledKeys, ["past"])
      XCTAssertTrue(ledger.records.isEmpty)
      XCTAssertEqual(session.dates(after: now).first, now.addingTimeInterval(1200))
      XCTAssertFalse(ledger.handledKeys.contains("future"))
    }
  }
  func testPersistedCancellationCannotReviveAnIntervalSession() {
    for schema in [1, 2] {
      for stopAll in [false, true] {
        var ledger = SystemAlarmLedger(); ledger.schema = schema
        let session = IndirectAlarmSession(settings: .init(), signal: .init(), startedAt: now)
        ledger.indirectSession = session
        if stopAll { ledger.cancelAllRequested = true } else { ledger.cancelledOwners = [session.id] }
        XCTAssertTrue(ledger.migrateToAlarmKitWave(now: now))
        XCTAssertNil(ledger.indirectSession)
        XCTAssertNil(ledger.cancelAllRequested)
        XCTAssertNil(ledger.cancelledOwners)
      }
    }
  }
  func testCurrentQueueSurvivesRepeatedMigrationCalls() throws {
    let owner = UUID()
    var ledger = SystemAlarmLedger()
    var current = record("future", seconds: 300, owner: owner)
    current.soundName = "luma-alarm-4.wav"; current.pending = false
    ledger.records = [current]
    let before = ledger
    XCTAssertFalse(ledger.migrateToAlarmKitWave(now: now))
    XCTAssertEqual(ledger, before)
    XCTAssertEqual(try JSONDecoder().decode(SystemAlarmLedger.self,
      from: JSONEncoder().encode(ledger)), before)
  }
  func testAlarmKitSnapshotConfirmsOnlyIdentityAndObservedState() {
    let record = record("one", seconds: 300, owner: UUID())
    var snapshot = FiniteCueSnapshot(identifier: record.notificationID,
      metadataVisible: false, alerting: true)
    XCTAssertTrue(snapshot.matches(record))
    XCTAssertTrue(snapshot.alerting)
    XCTAssertFalse(snapshot.hasSound, "Do not invent sound metadata not exposed by AlarmKit")
    snapshot.identifier = FiniteCuePolicy.identifier(for: UUID())
    XCTAssertFalse(snapshot.matches(record))
  }
}
