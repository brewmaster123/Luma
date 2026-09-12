import Foundation
import XCTest
@testable import LumaCore

final class NotificationMigrationTests: XCTestCase {
  func testUpdatingAlarmKitArchivePreservesUserDataAndSoundReferences() throws {
    let clipID = UUID()
    var state = LumaState()
    state.defaultPhoneDelivery = .systemAlarm
    state.voices = [VoiceClip(id: clipID, name: "Мой голос",
      filename: "luma-voice-\(clipID.uuidString).caf", duration: 12)]
    state.signal.voiceID = clipID
    state.phoneVibration = true
    for output in SignalOutput.allCases {
      var alarm = LumaAlarm()
      alarm.signal.output = output
      alarm.signal.voiceID = clipID
      alarm.phoneDelivery = .systemAlarm
      state.alarms.append(alarm)
    }
    var session = NightSession(source: .combined, signal: state.signal)
    session.status = .ended
    state.sessions = [session]
    var feedback = SessionFeedback(sessionID: session.id)
    feedback.note = "Помню свой сон"
    let journalID = UUID()
    feedback.voiceNotes = [JournalVoice(id: journalID,
      filename: "luma-journal-\(journalID.uuidString).m4a", duration: 68)]
    state.feedback = [feedback]
    var archive = AppArchive()
    archive.v2 = state
    var dream = DreamEntry(); dream.text = "Сон до обновления"
    dream.voiceNotes = feedback.voiceNotes; archive.diary = [dream]

    var restored = try JSONDecoder().decode(AppArchive.self, from: JSONEncoder().encode(archive))
    restored.v2?.useNotificationDelivery()
    let result = try XCTUnwrap(restored.v2)
    XCTAssertEqual(result.defaultPhoneDelivery, .shortCue)
    XCTAssertTrue(result.alarms.allSatisfy { $0.delivery == .shortCue })
    XCTAssertEqual(result.alarms.map(\.id), state.alarms.map(\.id))
    XCTAssertEqual(result.alarms.map(\.onceAt), state.alarms.map(\.onceAt))
    XCTAssertEqual(result.alarms.map(\.signal), state.alarms.map(\.signal))
    XCTAssertEqual(result.signal, state.signal)
    XCTAssertEqual(result.voices, state.voices)
    XCTAssertEqual(result.sessions, state.sessions)
    XCTAssertEqual(result.feedback, state.feedback)
    XCTAssertEqual(restored.diary, archive.diary)
    XCTAssertTrue(result.vibratesOnPhone)
  }

  func testRepeatedMigrationDoesNotDuplicateAlarmsOrChangeTheirNextDates() throws {
    var state = LumaState()
    var alarm = LumaAlarm(); alarm.weekdays = [2, 4, 6]; alarm.phoneDelivery = .systemAlarm
    state.alarms = [alarm]
    let now = Date(timeIntervalSince1970: 1_789_200_000)
    let before = AlarmPlanner.occurrences(state.alarms, after: now, limit: 48)
    state.useNotificationDelivery()
    let first = try JSONEncoder().encode(state)
    state = try JSONDecoder().decode(LumaState.self, from: first)
    state.useNotificationDelivery()
    XCTAssertEqual(state.alarms.count, 1)
    XCTAssertEqual(AlarmPlanner.occurrences(state.alarms, after: now, limit: 48), before)
    XCTAssertEqual(state.alarms[0].id, alarm.id)
    XCTAssertEqual(state.defaultPhoneDelivery, .shortCue)
  }
}
