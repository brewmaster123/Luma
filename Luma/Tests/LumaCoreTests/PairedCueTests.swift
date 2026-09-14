import XCTest
@testable import LumaCore

final class PairedCueTests: XCTestCase {
  let date = Date(timeIntervalSince1970: 1_800_000_000)
  private func occurrence(_ output: SignalOutput = .both) -> AlarmOccurrence {
    var alarm = LumaAlarm(); alarm.onceAt = date; alarm.signal.output = output
    return AlarmPlanner.occurrences([alarm], after: date.addingTimeInterval(-1), limit: 1)[0]
  }
  func testFallbackLeavesRoomForLivePlaybackAndPreservesOtherRoutes() {
    let paired = occurrence()
    XCTAssertEqual(PairedCuePolicy.phoneNotificationDate(paired), date.addingTimeInterval(5))
    XCTAssertEqual(PairedCuePolicy.phoneNotificationDate(occurrence(.phone)), date)
    XCTAssertGreaterThan(PairedCuePolicy.fallbackDelay, PairedCuePolicy.maximumAlarmLateness + 1)
    XCTAssertEqual(paired.date, date)
  }
  func testCannotPlayFromSuspensionOrBeforeDueTime() {
    let a = occurrence()
    XCTAssertFalse(PairedCuePolicy.canPlayAlarm(a, now: date, runtimeAvailable: false, completedIDs: []))
    XCTAssertFalse(PairedCuePolicy.canPlayAlarm(a, now: date.addingTimeInterval(-0.1), runtimeAvailable: true, completedIDs: []))
    XCTAssertTrue(PairedCuePolicy.canPlayAlarm(a, now: date, runtimeAvailable: true, completedIDs: []))
  }
  func testLateReturnCannotRaceTheFallbackOrReplayOldAlarm() {
    let a = occurrence()
    XCTAssertTrue(PairedCuePolicy.canPlayAlarm(a, now: date.addingTimeInterval(2), runtimeAvailable: true, completedIDs: []))
    for delay in [2.01, 5, 60, 3600] {
      XCTAssertFalse(PairedCuePolicy.canPlayAlarm(a, now: date.addingTimeInterval(delay), runtimeAvailable: true, completedIDs: []))
    }
  }
  func testCompletedOccurrenceSurvivesReloadWithoutRepeatingPlayback() throws {
    let a = occurrence(); var state = LumaState(); state.completedAlarmIDs = [a.id]
    let restored = try JSONDecoder().decode(LumaState.self, from: JSONEncoder().encode(state))
    XCTAssertFalse(PairedCuePolicy.canPlayAlarm(a, now: date, runtimeAvailable: true, completedIDs: Set(restored.completedAlarmIDs)))
    var next = a; next.date = date.addingTimeInterval(86400); next.id += ".next"
    XCTAssertTrue(PairedCuePolicy.canPlayAlarm(next, now: next.date, runtimeAvailable: true, completedIDs: Set(restored.completedAlarmIDs)))
  }
  func testPhoneOnlyAndWatchOnlyNeverStartSecondPlayer() {
    for output in [SignalOutput.phone, .watch] {
      XCTAssertFalse(PairedCuePolicy.canPlayAlarm(occurrence(output), now: date, runtimeAvailable: true, completedIDs: []))
    }
  }
  func testDelayedWatchMessageIsRejectedAndFutureTargetIsPreserved() {
    XCTAssertEqual(PairedCuePolicy.watchStart(requested: date.addingTimeInterval(2.5), now: date), date.addingTimeInterval(2.5))
    XCTAssertNil(PairedCuePolicy.watchStart(requested: date.addingTimeInterval(-2.01), now: date))
    XCTAssertNil(PairedCuePolicy.watchStart(requested: date.addingTimeInterval(10.1), now: date))
    XCTAssertEqual(PairedCuePolicy.watchStart(requested: date, now: date), date.addingTimeInterval(1.1))
    XCTAssertEqual(PairedCuePolicy.watchStart(requested: nil, now: date), date.addingTimeInterval(2))
  }
  func testMicrophoneFlagAloneDoesNotProveLiveBackgroundInput() {
    XCTAssertFalse(PairedCuePolicy.microphoneIsFresh(lastInput: nil, now: date))
    XCTAssertFalse(PairedCuePolicy.microphoneIsFresh(lastInput: date.addingTimeInterval(-3.01), now: date))
    XCTAssertFalse(PairedCuePolicy.microphoneIsFresh(lastInput: date.addingTimeInterval(1), now: date))
    XCTAssertTrue(PairedCuePolicy.microphoneIsFresh(lastInput: date.addingTimeInterval(-1), now: date))
  }
  func testCueTargetIsOptionalInOldVersionTwoPackets() throws {
    var packet = WirePacket(kind: .cue); packet.cueDate = date
    let restored = try JSONDecoder().decode(WirePacket.self, from: JSONEncoder().encode(packet))
    XCTAssertEqual(restored.cueDate, date)
    var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(packet)) as? [String: Any])
    old.removeValue(forKey: "cueDate")
    let legacy = try JSONDecoder().decode(WirePacket.self, from: JSONSerialization.data(withJSONObject: old))
    XCTAssertNil(legacy.cueDate); XCTAssertEqual(legacy.version, 2)
  }
}
