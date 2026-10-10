import XCTest
@testable import LumaCore

final class RealtimeREMTests: XCTestCase {
  let zero = Date(timeIntervalSince1970: 1_800_000_000)
  func fixtures(_ now: Date, candidate: Bool = true) -> ([HeartSample], [MotionEpoch]) {
    let heart = stride(from: -1800, through: 0, by: 5).map { offset in
      let recent = offset >= -180 && candidate
      let bpm = recent ? 70.0 + (offset % 10 == 0 ? 8 : -8) : 55.0 + (offset % 10 == 0 ? 1 : -1)
      return HeartSample(date: now.addingTimeInterval(Double(offset)), bpm: bpm, source: "watch")
    }
    let motion = stride(from: -120, through: -30, by: 30).map { offset in
      MotionEpoch(start: now.addingTimeInterval(Double(offset)),
        end: now.addingTimeInterval(Double(offset + 30)), rmsG: 0.001, sampleCount: 300)
    }
    return (heart, motion)
  }
  func consume(_ engine: inout RealtimeREMEngine, at seconds: Double,
               candidate: Bool = true) -> RealtimeREMEngine.Decision {
    let now = zero.addingTimeInterval(seconds)
    let (h, m) = fixtures(now, candidate: candidate)
    return engine.consume(heart: h, motion: m, now: now)
  }
  func testFreshDataNeedsSustainedEvidenceAndCuesOnce() {
    var engine = RealtimeREMEngine(startedAt: zero)
    var episodes = 0
    for seconds in stride(from: 1800.0, through: 2700, by: 15) {
      let d = consume(&engine, at: seconds)
      XCTAssertEqual(d.evaluation.evidence.kind, .candidate)
      if d.episode != nil { episodes += 1; XCTAssertEqual(seconds, 1890) }
    }
    XCTAssertEqual(episodes, 1)
  }
  func testInsufficientDataNeverBecomesREM() {
    var engine = RealtimeREMEngine(startedAt: zero)
    for seconds in stride(from: 1800.0, through: 7200, by: 15) {
      let d = engine.consume(heart: [], motion: [], now: zero.addingTimeInterval(seconds))
      XCTAssertEqual(d.evaluation.evidence.kind, .insufficient)
      XCTAssertNil(d.episode)
    }
  }
  func testWarmupAndMotionAreRequired() {
    var engine = RealtimeREMEngine(startedAt: zero)
    XCTAssertEqual(consume(&engine, at: 1199).evaluation.evidence.kind, .insufficient)
    let now = zero.addingTimeInterval(1800), (h, _) = fixtures(zero.addingTimeInterval(1800))
    XCTAssertEqual(RealtimeREMEngine.evaluate(heart: h, motion: [], startedAt: zero, now: now).evidence.kind, .insufficient)
  }
  func testStaleHeartAndOverlappingMotionAreRejected() {
    let now = zero.addingTimeInterval(1800), (h, m) = fixtures(zero.addingTimeInterval(1800))
    let stale = h.filter { now.timeIntervalSince($0.date) > 45 }
    XCTAssertEqual(RealtimeREMEngine.evaluate(heart: stale, motion: m, startedAt: zero, now: now).evidence.kind, .insufficient)
    XCTAssertEqual(RealtimeREMEngine.evaluate(heart: h, motion: m + [m[0]], startedAt: zero, now: now).evidence.kind, .insufficient)
  }
  func testRepeatedSameSampleDoesNotConfirmOnset() {
    var engine = RealtimeREMEngine(startedAt: zero)
    let now = zero.addingTimeInterval(1800), (h, m) = fixtures(zero.addingTimeInterval(1800))
    for seconds in 0...120 {
      XCTAssertNil(engine.consume(heart: h, motion: m, now: now.addingTimeInterval(Double(seconds))).episode)
    }
  }
  func testExecutionGapResetsConfirmation() {
    var engine = RealtimeREMEngine(startedAt: zero)
    for s in stride(from: 1800.0, through: 1845, by: 15) { XCTAssertNil(consume(&engine, at: s).episode) }
    XCTAssertNil(consume(&engine, at: 2000).episode)
    for s in stride(from: 2015.0, through: 2075, by: 15) { XCTAssertNil(consume(&engine, at: s).episode) }
    XCTAssertNotNil(consume(&engine, at: 2090).episode)
  }
  func testExitAndCooldownAllowAnotherEpisode() {
    var engine = RealtimeREMEngine(startedAt: zero)
    for s in stride(from: 1800.0, through: 1890, by: 15) { _ = consume(&engine, at: s) }
    for s in stride(from: 1905.0, through: 2205, by: 15) { XCTAssertNil(consume(&engine, at: s, candidate: false).episode) }
    var episodes = 0
    for s in stride(from: 2220.0, through: 3000, by: 15) {
      if consume(&engine, at: s).episode != nil { episodes += 1; XCTAssertGreaterThanOrEqual(s, 2880) }
    }
    XCTAssertEqual(episodes, 1)
  }
  func testCueExclusionCannotCreateAnExit() {
    var engine = RealtimeREMEngine(startedAt: zero)
    for s in stride(from: 1800.0, through: 1890, by: 15) { _ = consume(&engine, at: s) }
    engine.excludeCue(until: zero.addingTimeInterval(2200))
    for s in stride(from: 1905.0, through: 2190, by: 15) { _ = consume(&engine, at: s, candidate: false) }
    for s in stride(from: 2205.0, through: 3300, by: 15) { XCTAssertNil(consume(&engine, at: s).episode) }
  }
  func testCueTransportRejectsDuplicatesExpiredAndWrongSession() {
    let now = zero.addingTimeInterval(1800), session = UUID()
    var p = WirePacket(kind: .researchCue)
    p.sentAt = now; p.sessionID = session; p.cueDate = now.addingTimeInterval(2)
    p.researchEpisode = REMEpisode(date: now, features: FeatureSnapshot(date: now, source: .watch))
    p.episodeID = p.researchEpisode?.id
    XCTAssertTrue(ResearchCuePolicy.accepts(p, sessionID: session, now: now, processed: []))
    XCTAssertFalse(ResearchCuePolicy.accepts(p, sessionID: session, now: now, processed: [p.id]))
    XCTAssertFalse(ResearchCuePolicy.accepts(p, sessionID: UUID(), now: now, processed: []))
    XCTAssertFalse(ResearchCuePolicy.accepts(p, sessionID: session, now: now.addingTimeInterval(30), processed: []))
    p.cueDate = now.addingTimeInterval(60)
    XCTAssertFalse(ResearchCuePolicy.accepts(p, sessionID: session, now: now, processed: []))
    p.cueDate = now.addingTimeInterval(2); p.episodeID = UUID()
    XCTAssertFalse(ResearchCuePolicy.accepts(p, sessionID: session, now: now, processed: []))
  }
  func testOldSessionAndWireFormatStillDecode() throws {
    let session = NightSession(source: .watch, signal: SignalSettings())
    let decoded = try JSONDecoder().decode(NightSession.self, from: JSONEncoder().encode(session))
    XCTAssertNil(decoded.watchResearch)
    let packet = WirePacket(kind: .configuration)
    let old = try JSONDecoder().decode(WirePacket.self, from: JSONEncoder().encode(packet))
    XCTAssertNil(old.researchEpisode)
  }
}
