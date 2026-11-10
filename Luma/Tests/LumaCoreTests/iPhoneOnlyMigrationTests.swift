import Foundation
import XCTest
@testable import LumaCore

final class iPhoneOnlyMigrationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)
  func testEveryLegacyOutputBecomesAnAlarmKitAlarmWithoutChangingSchedule() {
    var state = LumaState()
    let voice = UUID()
    for output in SignalOutput.allCases {
      var alarm = LumaAlarm()
      alarm.signal.output = output; alarm.signal.voiceID = voice
      alarm.signal.count = .five; alarm.signal.gapSeconds = 12
      alarm.weekdays = [2, 4, 7]; alarm.onceAt = now.addingTimeInterval(3600)
      state.alarms.append(alarm)
    }
    let previous = state.alarms
    state.migrateToiPhoneOnly(now: now)
    XCTAssertEqual(state.alarms.map(\.id), previous.map(\.id))
    XCTAssertEqual(state.alarms.map(\.onceAt), previous.map(\.onceAt))
    XCTAssertEqual(state.alarms.map(\.weekdays), previous.map(\.weekdays))
    for alarm in state.alarms {
      XCTAssertEqual(alarm.signal.output, .phone)
      XCTAssertEqual(alarm.signal.melodySeconds, 4)
      XCTAssertEqual(alarm.signal.voiceID, voice)
      XCTAssertEqual(alarm.delivery, .systemAlarm)
    }
  }
  func testArchiveKeepsDiaryVoiceNotesFeedbackAndCompletedSessions() throws {
    var archive = AppArchive(), state = LumaState()
    let voice = VoiceClip(id: UUID(), name: "Голос", filename: "original.caf", duration: 20)
    state.voices = [voice]; state.signal.voiceID = voice.id
    var session = NightSession(source: .watch, signal: state.signal)
    session.status = .ended; session.endedAt = now
    state.sessions = [session]
    var feedback = SessionFeedback(sessionID: session.id); feedback.note = "Помню сон"
    let note = JournalVoice(id: UUID(), filename: "dream.m4a", duration: 100)
    feedback.voiceNotes = [note]; state.feedback = [feedback]
    archive.v2 = state
    var dream = DreamEntry(); dream.text = "Мои сновидения"; dream.voiceNotes = [note]
    archive.diary = [dream]
    var decoded = try JSONDecoder().decode(AppArchive.self, from: JSONEncoder().encode(archive))
    decoded.v2?.migrateToiPhoneOnly(now: now)
    XCTAssertEqual(decoded.diary, archive.diary)
    XCTAssertEqual(decoded.v2?.voices, state.voices)
    XCTAssertEqual(decoded.v2?.feedback, state.feedback)
    XCTAssertEqual(decoded.v2?.sessions, state.sessions)
    XCTAssertEqual(decoded.v2?.signal.voiceID, voice.id)
  }
  func testDisabledAndExpiredWatchAlarmsAreNotResurrected() {
    var state = LumaState()
    var disabled = LumaAlarm(); disabled.signal.output = .watch
    disabled.onceAt = now.addingTimeInterval(600); disabled.enabled = false
    var expired = LumaAlarm(); expired.signal.output = .watch; expired.onceAt = now.addingTimeInterval(-600)
    var future = LumaAlarm(); future.signal.output = .watch; future.onceAt = now.addingTimeInterval(900)
    state.alarms = [disabled, expired, future]
    state.migrateToiPhoneOnly(now: now)
    XCTAssertFalse(state.alarms[0].enabled)
    XCTAssertEqual(state.alarms[1].onceAt, expired.onceAt)
    XCTAssertEqual(AlarmPlanner.occurrences(state.alarms, after: now).map(\.alarmID), [future.id])
  }
  func testLegacyLiveSessionsEndOnceAndMigrationIsIdempotent() throws {
    var state = LumaState()
    var session = NightSession(source: .combined, signal: .init())
    session.watchResearch = true; session.watchResearchRunID = UUID()
    state.sessions = [session]
    state.migrateToiPhoneOnly(now: now)
    XCTAssertEqual(state.sessions[0].status, .ended)
    XCTAssertEqual(state.sessions[0].endedAt, now)
    XCTAssertEqual(state.sessions[0].watchResearchRunID, session.watchResearchRunID)
    // Compare the complete persisted state. LumaState deliberately does not
    // require Equatable just for this migration regression check.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let first = try encoder.encode(state)
    state.migrateToiPhoneOnly(now: now.addingTimeInterval(86400))
    XCTAssertEqual(try encoder.encode(state), first)
  }
  func testActiveSystemQueueAndStopDeadlinesArePreserved() {
    var session = IndirectAlarmSession(settings: .init(intervalMinutes: 17), signal: .init(), startedAt: now)
    session.signal.output = .both; session.signal.voiceID = UUID() // A decoded pre-0.9 session.
    let request = SystemAlarmRequest(key: session.key(for: now.addingTimeInterval(1020)),
      ownerID: session.id, kind: .indirect, fireAt: now.addingTimeInterval(1020),
      title: "Непрямой метод", source: URL(fileURLWithPath: "/original.caf"))
    let record = SystemAlarmRecord(request: request, soundName: "luma-ak4-test.caf")
    var ledger = SystemAlarmLedger(); ledger.records = [record]; ledger.indirectSession = session
    ledger.handledKeys = ["old"]; ledger.cancelledOwners = [UUID()]
    let previous = ledger
    XCTAssertTrue(ledger.migrateToiPhoneOnly())
    XCTAssertEqual(ledger.records, previous.records)
    XCTAssertEqual(ledger.records[0].stopAt, record.stopAt)
    XCTAssertEqual(ledger.handledKeys, previous.handledKeys)
    XCTAssertEqual(ledger.cancelledOwners, previous.cancelledOwners)
    XCTAssertEqual(ledger.indirectSession?.id, session.id)
    XCTAssertEqual(ledger.indirectSession?.startedAt, session.startedAt)
    XCTAssertEqual(ledger.indirectSession?.signal.voiceID, session.signal.voiceID)
    XCTAssertEqual(ledger.indirectSession?.signal.output, .phone)
    XCTAssertFalse(ledger.migrateToiPhoneOnly())
  }
  func testAllNewIndirectSessionsUseTheSingleSystemRoute() {
    for oldOutput in SignalOutput.allCases {
      var signal = SignalSettings(); signal.output = oldOutput
      let session = IndirectAlarmSession(settings: .init(intervalMinutes: 10), signal: signal, startedAt: now)
      XCTAssertEqual(session.signal.output, .phone)
      XCTAssertEqual(session.signal.melodySeconds, 4)
      XCTAssertEqual(session.dates(after: now).first, now.addingTimeInterval(600))
    }
  }
}
