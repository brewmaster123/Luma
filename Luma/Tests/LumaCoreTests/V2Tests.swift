import XCTest

@testable import LumaCore

final class V2Tests: XCTestCase {
  let origin = Date(timeIntervalSince1970: 1_800_000_000)
  func evidence(_ seconds: Double, _ kind: EvidenceKind = .candidate) -> REMEvidence {
    REMEvidence(
      kind: kind, heuristicScore: 0.9, latestSampleAt: origin.addingTimeInterval(seconds),
      explanation: "Synthetic fixture")
  }
  @discardableResult func consume(
    _ seconds: Double, _ memory: inout EpisodeMemory, _ kind: EvidenceKind = .candidate
  ) -> Bool { memory.consume(evidence(seconds, kind), now: origin.addingTimeInterval(seconds)) }
  func testContinuousEpisodeOnlySignalsOnceForTwelveHours() {
    var m = EpisodeMemory()
    var n = 0
    for t in stride(from: 0.0, through: 43200, by: 60) { if consume(t, &m) { n += 1 } }
    XCTAssertEqual(n, 1)
  }
  func testTwentySeparateEpisodesHaveNoSessionCapAndSurviveRestore() throws {
    var m = EpisodeMemory()
    var n = 0
    for hour in 0..<20 {
      for t in stride(from: 0.0, through: 3540, by: 60) {
        if consume(Double(hour * 3600) + t, &m, t < 600 ? .candidate : .unlikely) { n += 1 }
      }
      m = try JSONDecoder().decode(EpisodeMemory.self, from: JSONEncoder().encode(m))
    }
    XCTAssertEqual(n, 20)
  }
  func testMissingDataDoesNotMeanExit() {
    var m = EpisodeMemory()
    for t in [0.0, 60, 120] { consume(t, &m) }
    _ = m.consume(.unavailable("missing"), now: origin.addingTimeInterval(2000))
    for t in [2060.0, 2120, 2180] { XCTAssertFalse(consume(t, &m)) }
    XCTAssertTrue(m.insideEpisode)
  }
  func testShortExitAndDuplicateSamplesCannotRetrigger() {
    var m = EpisodeMemory()
    for t in [0.0, 60, 120] { consume(t, &m) }
    for t in [180.0, 240, 300] { consume(t, &m, .unlikely) }
    for t in stride(from: 360.0, through: 1500, by: 60) { XCTAssertFalse(consume(t, &m)) }
    var other = EpisodeMemory()
    for t in stride(from: 0.0, through: 240, by: 30) {
      XCTAssertFalse(other.consume(evidence(0), now: origin.addingTimeInterval(t)))
    }
  }
  func testCooldownAfterRealExit() {
    var m = EpisodeMemory()
    for t in [0.0, 60, 120] { consume(t, &m) }
    for t in stride(from: 180.0, through: 480, by: 60) { consume(t, &m, .unlikely) }
    for t in stride(from: 540.0, through: 1260, by: 60) { XCTAssertFalse(consume(t, &m)) }
    XCTAssertTrue(consume(1320, &m))
  }
  func testThousandSavedAlarmsUseBoundedOrderedQueue() throws {
    let alarms = (0..<1000).map { i -> LumaAlarm in
      var a = LumaAlarm()
      a.onceAt = origin.addingTimeInterval(Double(1000 - i) * 60)
      return a
    }
    var state = LumaState()
    state.alarms = alarms
    let restored = try JSONDecoder().decode(LumaState.self, from: JSONEncoder().encode(state))
    XCTAssertEqual(restored.alarms.count, 1000)
    let q = AlarmPlanner.occurrences(restored.alarms, after: origin, limit: 48)
    XCTAssertEqual(q.count, 48)
    XCTAssertEqual(q.first?.date, origin.addingTimeInterval(60))
    XCTAssertEqual(Set(q.map(\.id)).count, 48)
  }
  func testExpiredOneShotNeverReappearsTomorrow() {
    var a = LumaAlarm()
    a.onceAt = origin.addingTimeInterval(-1)
    XCTAssertTrue(AlarmPlanner.occurrences([a], after: origin).isEmpty)
  }
  func testDisabledAlarmsAndInvalidWeekdaysAreNotScheduled() {
    var a = LumaAlarm()
    a.enabled = false
    a.onceAt = origin.addingTimeInterval(60)
    var b = LumaAlarm()
    b.weekdays = [0, 8]
    XCTAssertTrue(AlarmPlanner.occurrences([a, b], after: origin).isEmpty)
  }
  func testWeekdayAlarmCrossesSpringDSTUsingCalendar() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0)))
    var a = LumaAlarm()
    a.hour = 2
    a.minute = 30
    a.weekdays = [1]
    let q = AlarmPlanner.occurrences([a], after: now, limit: 2, calendar: cal)
    XCTAssertEqual(q.count, 2)
    XCTAssertEqual(cal.component(.weekday, from: q[0].date), 1)
    XCTAssertGreaterThan(q[1].date, q[0].date)
    XCTAssertLessThan(q[0].date.timeIntervalSince(now), 86400)
  }
  func testThreeOutputRoutesAreIndependentOfSensors() {
    XCTAssertEqual(SignalOutput.allCases.count, 3)
    XCTAssertTrue(SignalOutput.both.phoneEnabled && SignalOutput.both.watchEnabled)
    XCTAssertTrue(SignalOutput.phone.phoneEnabled && !SignalOutput.phone.watchEnabled)
    XCTAssertTrue(SignalOutput.watch.watchEnabled && !SignalOutput.watch.phoneEnabled)
    var s = SignalSettings()
    s.gapSeconds = -10
    s.melodySeconds = 999
    XCTAssertEqual(s.validated().gapSeconds, 8)
    XCTAssertEqual(s.validated().melodySeconds, 8)
  }
  func testOldArchiveKeepsDreamEntriesWithoutV2Key() throws {
    var old = AppArchive()
    var d = DreamEntry()
    d.text = "Сон у моря"
    old.diary = [d]
    let bytes = try JSONEncoder().encode(old)
    let decoded = try JSONDecoder().decode(AppArchive.self, from: bytes)
    XCTAssertNil(decoded.v2)
    XCTAssertEqual(decoded.diary.first?.text, "Сон у моря")
  }
  func testSilenceCannotManufactureBreathing() throws {
    let a = try XCTUnwrap(
      AcousticFeatures.extract(
        envelope: Array(repeating: 0, count: 600), start: origin, end: origin.addingTimeInterval(60)
      ))
    XCTAssertNil(a.breathingProxy)
    XCTAssertEqual(a.periodicity, 0)
  }
  func testPeriodicAcousticFixtureYieldsFiniteFeatures() throws {
    let x = (0..<600).map { 0.02 + 0.01 * sin(Double($0) * 2 * Double.pi / 40) }
    let a = try XCTUnwrap(
      AcousticFeatures.extract(envelope: x, start: origin, end: origin.addingTimeInterval(60)))
    XCTAssertTrue(a.levelDB.isFinite)
    XCTAssertGreaterThan(a.periodicity, 0.95)
    XCTAssertNotNil(a.breathingProxy)
  }
  func testCorruptAudioWindowsAreRejected() {
    XCTAssertNil(
      AcousticFeatures.extract(
        envelope: Array(repeating: .nan, count: 600), start: origin,
        end: origin.addingTimeInterval(60)))
    XCTAssertNil(
      AcousticFeatures.extract(
        envelope: Array(repeating: 0.1, count: 600), start: origin,
        end: origin.addingTimeInterval(1)))
  }
  func audio(_ contaminated: Bool = false) -> [AudioEpoch] {
    (0..<8).map { i in
      AudioEpoch(
        start: origin.addingTimeInterval(Double(i - 8) * 60),
        end: origin.addingTimeInterval(Double(i - 7) * 60), levelDB: -35, transientFraction: 0.01,
        breathingProxy: i % 2 == 0 ? 10 : 18, periodicity: 0.9, contaminated: contaminated)
    }
  }
  func testOwnCueAndNoiseDoNotProducePhoneCandidate() {
    let estimator = MultimodalEstimator()
    let s = LumaState()
    XCTAssertEqual(
      estimator.evaluate(
        source: .phone, heart: [], motion: [], breath: [], audio: audio(true), now: origin, state: s
      ).evidence.kind, .insufficient)
    let noisy = audio().map { v -> AudioEpoch in
      var e = v
      e.transientFraction = 0.8
      return e
    }
    XCTAssertEqual(
      estimator.evaluate(
        source: .phone, heart: [], motion: [], breath: [], audio: noisy, now: origin, state: s
      ).evidence.kind, .insufficient)
  }
  func testCombinedDoesNotSilentlyBecomePhoneOnly() {
    let e = MultimodalEstimator()
    XCTAssertEqual(
      e.evaluate(
        source: .combined, heart: [], motion: [], breath: [], audio: audio(), now: origin,
        state: LumaState()
      ).evidence.kind, .insufficient)
    XCTAssertEqual(
      e.evaluate(
        source: .phone, heart: [], motion: [], breath: [], audio: audio(), now: origin,
        state: LumaState()
      ).evidence.kind, .candidate)
  }
  func personalized(_ count: Int) -> LumaState {
    var state = LumaState()
    state.personalizationEnabled = true
    for i in 0..<count {
      var s = NightSession(source: .watch, signal: SignalSettings())
      s.startedAt = origin.addingTimeInterval(Double(-i) * 86400)
      s.status = .ended
      let f = FeatureSnapshot(
        date: s.startedAt, source: .watch, heartRate: i % 2 == 0 ? 65 : 85, heartSpread: 4)
      s.episodes = [REMEpisode(date: s.startedAt, features: f)]
      state.sessions.append(s)
      var feedback = SessionFeedback(sessionID: s.id)
      feedback.noticed = .yes
      feedback.lucid = i % 2 == 0 ? .yes : .no
      state.feedback.append(feedback)
    }
    return state
  }
  func testPersonalizationRequiresManyNightsAndExplicitOptIn() {
    let f = FeatureSnapshot(date: origin, source: .watch, heartRate: 65, heartSpread: 4)
    XCTAssertEqual(Personalization.adjustment(for: f, state: personalized(11)), 0)
    var state = personalized(12)
    XCTAssertEqual(Personalization.examples(state: state).count, 12)
    let delta = Personalization.adjustment(for: f, state: state)
    XCTAssertGreaterThan(delta, 0)
    XCTAssertLessThanOrEqual(abs(delta), 0.025)
    state.personalizationEnabled = false
    XCTAssertEqual(Personalization.adjustment(for: f, state: state), 0)
  }
  func testAmbiguousMultiCueAndSameNightFeedbackCannotOverweightLearning() {
    var state = personalized(12)
    let extra = state.sessions[0].episodes[0]
    state.sessions[0].episodes.append(REMEpisode(date: extra.date, features: extra.features))
    XCTAssertEqual(Personalization.examples(state: state).count, 11)
    state.feedback[0].episodeID = extra.id
    XCTAssertEqual(Personalization.examples(state: state).count, 12)
    for i in state.sessions.indices { state.sessions[i].startedAt = origin }
    XCTAssertEqual(Personalization.examples(state: state).count, 1)
  }
}
