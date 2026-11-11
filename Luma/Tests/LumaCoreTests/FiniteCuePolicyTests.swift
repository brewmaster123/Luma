import XCTest
@testable import LumaCore

final class FiniteCuePolicyTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)
  private func record(_ seconds: Double, key: String) -> SystemAlarmRecord {
    .init(request: .init(key: key, ownerID: UUID(), kind: .smart,
      fireAt: now.addingTimeInterval(seconds), title: "Luma", source: URL(fileURLWithPath: "/sound.wav")),
      soundName: "luma-cue4-test.caf")
  }
  func testMigrationDoesNotLoseFutureOccurrencesOrReplayElapsedCues() {
    var ledger = SystemAlarmLedger(); ledger.schema = 1
    let past = record(-30, key: "past"), future = record(1800, key: "future")
    ledger.records = [past, future]
    let session = IndirectAlarmSession(settings: .init(intervalMinutes: 30), signal: .init(), startedAt: now)
    ledger.indirectSession = session
    XCTAssertTrue(ledger.migrateToFiniteNotifications(now: now))
    XCTAssertEqual(ledger.schema, 2); XCTAssertTrue(ledger.records.isEmpty)
    XCTAssertEqual(ledger.handledKeys, ["past"])
    XCTAssertEqual(ledger.indirectSession, session)
    XCTAssertEqual(ledger.indirectSession?.dates(after: now).first, now.addingTimeInterval(1800))
    XCTAssertFalse(ledger.migrateToFiniteNotifications(now: now))
  }
  func testMigrationHonorsPersistedStopAllAndOwnerCancellation() {
    for stopAll in [true, false] {
      var ledger = SystemAlarmLedger(); ledger.schema = 1
      let session = IndirectAlarmSession(settings: .init(), signal: .init(), startedAt: now)
      ledger.indirectSession = session
      if stopAll { ledger.cancelAllRequested = true } else { ledger.cancelledOwners = [session.id] }
      XCTAssertTrue(ledger.migrateToFiniteNotifications(now: now))
      XCTAssertNil(ledger.indirectSession); XCTAssertNil(ledger.cancelAllRequested)
      XCTAssertNil(ledger.cancelledOwners)
    }
  }
  func testFiniteLedgerSurvivesRoundTripWithoutTouchingAcceptedIDs() throws {
    var ledger = SystemAlarmLedger(); ledger.records = [record(300, key: "future")]
    let restored = try JSONDecoder().decode(SystemAlarmLedger.self, from: JSONEncoder().encode(ledger))
    XCTAssertEqual(restored, ledger); XCTAssertEqual(restored.schema, 2)
  }
  func testNotificationBudgetReservesRoomAndAccountsForOtherFeatures() {
    XCTAssertEqual(FiniteCuePolicy.capacity(otherPending: 0), 60)
    XCTAssertEqual(FiniteCuePolicy.capacity(otherPending: 4), 60)
    XCTAssertEqual(FiniteCuePolicy.capacity(otherPending: 10), 54)
    XCTAssertEqual(FiniteCuePolicy.capacity(otherPending: 64), 0)
    XCTAssertEqual(FiniteCuePolicy.capacity(otherPending: 100), 0)
  }
  func testEachOccurrenceHasItsOwnNotificationIdentity() {
    let first = record(1800, key: "first"), next = record(3600, key: "next")
    XCTAssertNotEqual(first.notificationID, next.notificationID)
    XCTAssertTrue(first.notificationID.hasPrefix(FiniteCuePolicy.prefix))
  }
  func testRepetitionAndMissingSoundCannotMasqueradeAsAcceptedCue() {
    let record = record(60, key: "one")
    var snapshot = FiniteCueSnapshot(identifier: record.notificationID, key: record.key,
      fireAt: record.fireAt, title: record.title, soundName: record.soundName, hasSound: true)
    XCTAssertTrue(snapshot.matches(record))
    snapshot.repeats = true; XCTAssertFalse(snapshot.matches(record))
    snapshot.repeats = false; snapshot.hasSound = false; XCTAssertFalse(snapshot.matches(record))
    snapshot.hasSound = true; snapshot.fireAt.addTimeInterval(0.0000002)
    XCTAssertTrue(snapshot.matches(record), "Unix timestamp rounding must not reject an accepted cue")
    snapshot.fireAt.addTimeInterval(1); XCTAssertFalse(snapshot.matches(record))
  }
  func testDefaultAndCustomSoundNamesAreBoundedToSafeResources() {
    XCTAssertTrue(FiniteCuePolicy.validSoundName("luma-tone-4.wav"))
    XCTAssertTrue(FiniteCuePolicy.validSoundName("luma-cue4-abc.caf"))
    for value in ["default", "luma-tone-15.wav", "luma-ak4-old.caf", "../luma-cue4-x.caf",
      "luma-cue4-../x.caf", "luma-cue4-..\\x.caf"] {
      XCTAssertFalse(FiniteCuePolicy.validSoundName(value), value)
    }
  }
  func testThirtyMinuteSeriesKeepsTwentyFourIndependentFourSecondCues() {
    let session = IndirectAlarmSession(settings: .init(intervalMinutes: 30), signal: .init(), startedAt: now)
    let dates = session.dates(after: now)
    XCTAssertEqual(dates.count, 24)
    XCTAssertEqual(dates.first, now.addingTimeInterval(1800))
    XCTAssertEqual(dates.last, now.addingTimeInterval(43200))
    XCTAssertEqual(Set(dates.map(session.key(for:))).count, 24)
    XCTAssertEqual(SystemAlarmPolicy.soundSeconds, 4)
  }
  func testConsentForAlarmKitDoesNotAuthorizeTheDifferentNotificationContract() {
    XCTAssertNotEqual(FiniteCuePolicy.consentKey, "luma.alarmkit.short-stop-consent.v1")
    XCTAssertFalse(LumaFeatures.finiteNotificationDeviceVerified)
  }
}
