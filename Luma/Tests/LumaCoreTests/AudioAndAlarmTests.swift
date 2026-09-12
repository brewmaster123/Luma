import Foundation
import XCTest
@testable import LumaCore

final class AudioAndAlarmTests: XCTestCase {
  private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
  private func date(_ day: Int = 9, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
  }
  private func alarm(_ hour: Int, day: Int = 9) -> LumaAlarm {
    var a = LumaAlarm(); a.hour = hour; a.minute = 0; a.onceAt = date(day, hour); return a
  }
  func testInsertionOrderDoesNotDetermineAlarmOrder() {
    let nine = alarm(9), noon = alarm(12), seven = alarm(7)
    XCTAssertEqual(AlarmPlanner.sorted([nine, noon, seven], after: date(), calendar: calendar).map(\.id), [seven.id, nine.id, noon.id])
  }
  func testNextDateTakesPriorityOverClockAcrossMidnight() {
    let morning = alarm(7, day: 10), tonight = alarm(23)
    XCTAssertEqual(AlarmPlanner.sorted([morning, tonight], after: date(9, 22), calendar: calendar).map(\.id), [tonight.id, morning.id])
  }
  func testRepeatWeekdaySortsByActualNextOccurrence() {
    var monday = alarm(7); monday.weekdays = [2]
    var thursday = alarm(12); thursday.weekdays = [5]
    XCTAssertEqual(AlarmPlanner.sorted([monday, thursday], after: date(), calendar: calendar).map(\.id), [thursday.id, monday.id])
  }
  func testDisabledAndExpiredFollowUpcoming() {
    var disabled = alarm(6); disabled.enabled = false
    let expired = alarm(4), upcoming = alarm(9)
    XCTAssertEqual(AlarmPlanner.sorted([expired, disabled, upcoming], after: date(9, 8), calendar: calendar).map(\.id), [upcoming.id, expired.id, disabled.id])
  }
  func testTiesRemainDeterministic() {
    var a = alarm(7), b = alarm(7)
    a.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    b.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    XCTAssertEqual(AlarmPlanner.sorted([b,a], after: date(), calendar: calendar).map(\.id), [a.id,b.id])
  }
  func testLegacyArchiveMissingNewFieldsDecodes() throws {
    var archive = AppArchive(); archive.v2 = LumaState(); archive.v2?.alarms = [alarm(7)]
    var dream = DreamEntry(); dream.text = "Старый сон"; archive.diary = [dream]
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
    var state = try XCTUnwrap(json["v2"] as? [String: Any])
    state.removeValue(forKey: "phoneVibration"); state.removeValue(forKey: "defaultPhoneDelivery")
    var alarms = try XCTUnwrap(state["alarms"] as? [[String: Any]])
    alarms[0].removeValue(forKey: "phoneDelivery"); state["alarms"] = alarms; json["v2"] = state
    var diary = try XCTUnwrap(json["diary"] as? [[String: Any]])
    diary[0].removeValue(forKey: "voiceNotes"); json["diary"] = diary
    let decoded = try JSONDecoder().decode(AppArchive.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(decoded.diary.first?.text, "Старый сон"); XCTAssertNil(decoded.diary.first?.voiceNotes)
    XCTAssertEqual(decoded.v2?.alarms.first?.delivery, .shortCue); XCTAssertEqual(decoded.v2?.vibratesOnPhone, false)
  }
  func testVoiceOnlyDreamRoundTrips() throws {
    var dream = DreamEntry(); XCTAssertFalse(dream.hasContent)
    let id = UUID(); dream.voiceNotes = [JournalVoice(id: id, filename: "luma-journal-\(id.uuidString).m4a", duration: 63)]
    XCTAssertTrue(dream.hasContent)
    XCTAssertEqual(try JSONDecoder().decode(DreamEntry.self, from: JSONEncoder().encode(dream)), dream)
    dream.voiceNotes = []; dream.text = "   \n"; XCTAssertFalse(dream.hasContent)
  }
  func testFeedbackAndImportedMelodyRoundTrip() throws {
    let id = UUID(), voice = JournalVoice(id: UUID(), filename: "journal.m4a", duration: 41)
    var feedback = SessionFeedback(sessionID: id); feedback.voiceNotes = [voice]
    var clip = VoiceClip(id: UUID(), name: "Мелодия", filename: "import.caf", duration: 28); clip.imported = true; clip.sourceDuration = 183
    var state = LumaState(); state.feedback = [feedback]; state.voices = [clip]; state.phoneVibration = true; state.defaultPhoneDelivery = .systemAlarm
    let restored = try JSONDecoder().decode(LumaState.self, from: JSONEncoder().encode(state))
    XCTAssertEqual(restored.feedback, [feedback]); XCTAssertEqual(restored.voices, [clip]); XCTAssertTrue(restored.vibratesOnPhone)
    XCTAssertEqual(restored.defaultPhoneDelivery, .systemAlarm)
  }
  func testJournalFileCannotEscapeDirectory() {
    let id = UUID()
    XCTAssertFalse(JournalVoice(id: id, filename: "../state.json", duration: 10).hasSafeFilename)
    XCTAssertFalse(JournalVoice(id: id, filename: "luma-journal-\(UUID().uuidString).m4a", duration: 10).hasSafeFilename)
    XCTAssertTrue(JournalVoice(id: id, filename: "luma-journal-\(id.uuidString).m4a", duration: 10).hasSafeFilename)
  }
  func testThreeSecondGapSurvivesAndLegacyTwentyMigrates() throws {
    var signal = SignalSettings(); signal.gapSeconds = 3
    XCTAssertEqual(try JSONDecoder().decode(SignalSettings.self, from: JSONEncoder().encode(signal)).validated().gapSeconds, 3)
    signal.gapSeconds = 20; XCTAssertEqual(signal.validated().gapSeconds, 12)
    var legacy = NightSettings(); legacy.intervalSeconds = 3; XCTAssertEqual(legacy.validated().intervalSeconds, 3)
  }
}
