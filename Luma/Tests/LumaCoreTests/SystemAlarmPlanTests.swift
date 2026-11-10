import XCTest
@testable import LumaCore

final class SystemAlarmPlanTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 2_000_000_000)
  private func request(_ offset: Double, key: String = "a") -> SystemAlarmRequest {
    .init(key: key, ownerID: UUID(), kind: .smart, fireAt: start.addingTimeInterval(offset),
      title: "Test", source: URL(fileURLWithPath: "/test.caf"))
  }
  func testStopIsSeparateFromFileEndAndUsesOriginalDeadline() {
    let record = SystemAlarmRecord(request: request(0), soundName: "short.caf")
    XCTAssertEqual(SystemAlarmPolicy.stopAction(record: record, alerting: false,
      now: start.addingTimeInterval(100)), .none)
    XCTAssertEqual(SystemAlarmPolicy.stopAction(record: record, alerting: true,
      now: start.addingTimeInterval(2)), .wait(until: start.addingTimeInterval(4)))
    XCTAssertEqual(SystemAlarmPolicy.stopAction(record: record, alerting: true,
      now: start.addingTimeInterval(4)), .stop(lateBy: 0))
    XCTAssertEqual(SystemAlarmPolicy.stopAction(record: record, alerting: true,
      now: start.addingTimeInterval(104)), .stop(lateBy: 100))
  }
  func testEveryIntervalKeepsCadenceAfterLateResume() {
    for minutes in 10...60 {
      let s = IndirectAlarmSession(settings: .init(intervalMinutes: minutes),
        signal: SignalSettings(), startedAt: start)
      let now = start.addingTimeInterval(Double(minutes) * 60 * 3 + 17)
      let dates = s.dates(after: now)
      XCTAssertFalse(dates.isEmpty)
      XCTAssertEqual(dates.first, start.addingTimeInterval(Double(minutes) * 60 * 4))
      XCTAssertTrue(dates.allSatisfy { $0 > now && $0 <= now.addingTimeInterval(43200) })
      for pair in zip(dates, dates.dropFirst()) {
        XCTAssertEqual(pair.1.timeIntervalSince(pair.0), Double(minutes) * 60)
      }
    }
  }
  func testQueueSkipsPastHandledDuplicatesAndSortsGlobally() {
    let input = [request(90, key: "late"), request(30, key: "early"), request(90, key: "late"),
      request(-10, key: "past"), request(40, key: "handled")]
    XCTAssertEqual(SystemAlarmPolicy.desired(input, after: start, handled: ["handled"])
      .map(\.key), ["early", "late"])
  }
  func testQueueIsFiniteAndDoesNotCatchUpMissedSignals() {
    let s = IndirectAlarmSession(settings: .init(intervalMinutes: 10),
      signal: SignalSettings(), startedAt: start)
    XCTAssertEqual(s.dates(after: start).count, 72)
    XCTAssertEqual(s.dates(after: start.addingTimeInterval(600)).first,
      start.addingTimeInterval(1200))
    let many = (1...150).map { request(Double($0) * 10, key: String($0)) }
    XCTAssertEqual(SystemAlarmPolicy.desired(many, after: start, handled: []).count, 96)
  }
  func testLedgerReservationAndHandledKeysSurviveRelaunch() throws {
    var ledger = SystemAlarmLedger()
    let record = SystemAlarmRecord(request: request(30), soundName: "luma-ak4.caf")
    ledger.records = [record]
    var restored = try JSONDecoder().decode(SystemAlarmLedger.self, from: JSONEncoder().encode(ledger))
    XCTAssertEqual(restored.records.first?.pending, true)
    restored.markHandled(record)
    XCTAssertTrue(restored.records.isEmpty)
    XCTAssertEqual(restored.handledKeys, [record.key])
  }
  func testIndirectAlwaysHasPhoneSoundAndPreservesVoiceReference() {
    var signal = SignalSettings(); signal.output = .watch; signal.melodySeconds = 15
    signal.voiceID = UUID()
    let s = IndirectAlarmSession(settings: .init(intervalMinutes: 30), signal: signal, startedAt: start)
    XCTAssertEqual(s.signal.output, .phone)
    XCTAssertEqual(s.signal.melodySeconds, 4)
    XCTAssertEqual(s.signal.voiceID, signal.voiceID)
  }
  func testCancellationIntentSurvivesBeforeDaemonCancellation() throws {
    var ledger = SystemAlarmLedger()
    let s = IndirectAlarmSession(settings: .init(), signal: .init(), startedAt: start)
    ledger.indirectSession = s
    ledger.records = [SystemAlarmRecord(request: request(30), soundName: "luma-ak4-test.caf")]
    ledger.indirectSession = nil
    ledger.cancelledOwners = [s.id]; ledger.cancelAllRequested = true
    let recovered = try JSONDecoder().decode(SystemAlarmLedger.self, from: JSONEncoder().encode(ledger))
    XCTAssertNil(recovered.indirectSession)
    XCTAssertEqual(recovered.cancelledOwners, [s.id])
    XCTAssertEqual(recovered.cancelAllRequested, true)
    XCTAssertEqual(recovered.records.count, 1)
  }
  func testLedgerWithoutNewCancellationFieldsRemainsReadable() throws {
    let old = Data(#"{"schema":1,"records":[],"handledKeys":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(SystemAlarmLedger.self, from: old)
    XCTAssertNil(decoded.cancelAllRequested)
    XCTAssertNil(decoded.cancelledOwners)
    XCTAssertTrue(decoded.records.isEmpty)
  }
}
