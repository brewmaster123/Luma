import XCTest
@testable import LumaCore

final class CoreSafetyTests: XCTestCase {
    let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private func plan(mode: NightMode = .experimentalREM, count: CueCount = .two) -> NightPlan {
        var settings = NightSettings(); settings.mode = mode; settings.cueCount = count
        return NightPlan(createdAt: origin.addingTimeInterval(-3600), windowStart: origin,
                         windowEnd: origin.addingTimeInterval(1800), settings: settings)
    }
    private func candidate(at date: Date) -> REMEvidence {
        REMEvidence(kind: .candidate, heuristicScore: 0.9, latestSampleAt: date, explanation: "Synthetic test")
    }
    func testEveryAllowedCountProducesExactlyThatManyFiniteUniqueRequests() throws {
        for count in CueCount.allCases {
            let p = plan(mode: .scheduled, count: count)
            let requests = try CueEngine().scheduledRequests(plan: p, now: origin.addingTimeInterval(-60))
            XCTAssertEqual(requests.count, count.rawValue)
            XCTAssertEqual(Set(requests.map(\.id)).count, count.rawValue)
            XCTAssertTrue(requests.allSatisfy { p.contains($0.fireAt) })
            XCTAssertEqual(requests, try CueEngine().scheduledRequests(plan: p, now: origin.addingTimeInterval(-30)))
        }
    }
    func testLateScheduledCommandNeverReschedulesOrFiresImmediately() {
        XCTAssertThrowsError(try CueEngine().scheduledRequests(plan: plan(mode: .scheduled), now: origin.addingTimeInterval(10)))
    }
    func testReevaluatingOneMeasurementDoesNotCreateAStreak() {
        var memory = DecisionMemory(); let engine = CueEngine(); let p = plan()
        for second in stride(from: 0, through: 240, by: 30) {
            XCTAssertTrue(engine.decide(plan: p, evidence: candidate(at: origin),
                                        now: origin.addingTimeInterval(Double(second)), memory: &memory).isEmpty)
        }
        XCTAssertFalse(memory.reservedBurst)
    }
    func testStaleUnknownAndFutureEvidenceNeverTriggers() {
        let engine = CueEngine(); let p = plan()
        for evidence in [candidate(at: origin.addingTimeInterval(-300)),
                         candidate(at: origin.addingTimeInterval(999)), .unavailable("missing")] {
            var memory = DecisionMemory()
            for second in [0.0, 60, 120, 180] {
                XCTAssertTrue(engine.decide(plan: p, evidence: evidence, now: origin.addingTimeInterval(second), memory: &memory).isEmpty)
            }
        }
    }
    func testOnlyOneBurstSurvivesSerializationAndRepeatedUpdates() throws {
        var memory = DecisionMemory(); let engine = CueEngine(); let p = plan(count: .five)
        var outputs: [CueRequest] = []
        for second in [0.0, 60, 120] {
            let date = origin.addingTimeInterval(second)
            outputs += engine.decide(plan: p, evidence: candidate(at: date), now: date, memory: &memory)
        }
        XCTAssertEqual(outputs.count, 5)
        memory = try JSONDecoder().decode(DecisionMemory.self, from: JSONEncoder().encode(memory))
        for second in stride(from: 180.0, through: 1500, by: 60) {
            let date = origin.addingTimeInterval(second)
            XCTAssertTrue(engine.decide(plan: p, evidence: candidate(at: date), now: date, memory: &memory).isEmpty)
        }
    }
    func testSuspensionGapRequiresNewSustainedEvidence() {
        var memory = DecisionMemory(); let engine = CueEngine(); let p = plan()
        for second in [0.0, 60, 500, 560] {
            let date = origin.addingTimeInterval(second)
            XCTAssertTrue(engine.decide(plan: p, evidence: candidate(at: date), now: date, memory: &memory).isEmpty)
        }
    }
    func testNeverSchedulesOutsideWindowOrAClippedSeries() {
        var memory = DecisionMemory(); let engine = CueEngine(); let p = plan(count: .five)
        for second in [-180.0, -120, -60, 1650, 1710, 1770, 1830] {
            let date = origin.addingTimeInterval(second)
            XCTAssertTrue(engine.decide(plan: p, evidence: candidate(at: date), now: date, memory: &memory).isEmpty)
        }
    }
    func testEstimatorAbstainsWithMissingMotionDespiteLotsOfHeartData() {
        let samples = stride(from: -2700.0, through: 0, by: 60).map { HeartSample(date: origin.addingTimeInterval($0), bpm: 65) }
        XCTAssertEqual(REMEstimator().evaluate(heart: samples, motion: [], now: origin).kind, .insufficient)
    }
    func testDuplicatesAndNonfiniteValuesCannotManufactureEnoughMeasurements() {
        let samples = Array(repeating: HeartSample(date: origin, bpm: 65), count: 200) +
            [HeartSample(date: origin.addingTimeInterval(-120), bpm: .nan)]
        XCTAssertEqual(REMEstimator().evaluate(heart: samples, motion: [], now: origin).kind, .insufficient)
    }
    func testMixingSensorsCannotManufactureOneDenseStream() {
        let samples = (0..<10).map { HeartSample(date: origin.addingTimeInterval(Double(-$0 * 60)), bpm: 65, source: "sensor-\($0)") }
        XCTAssertEqual(REMEstimator().evaluate(heart: samples, motion: [], now: origin).kind, .insufficient)
    }
    func testScheduledTimeIsNotProofOfDeliveryOrREM() throws {
        let request = try XCTUnwrap(CueEngine().scheduledRequests(plan: plan(mode: .scheduled), now: origin.addingTimeInterval(-60)).first)
        let record = CueRecord(request: request, status: .scheduled)
        let rem = SleepSegment(start: origin.addingTimeInterval(-10), end: origin.addingTimeInterval(600), stage: .rem, source: "Apple")
        XCTAssertEqual(SleepComparison().compare(record: record, segments: [rem]), .unknown)
    }
    func testConflictingHistoricalStagesAreUnknown() throws {
        let request = try XCTUnwrap(CueEngine().scheduledRequests(plan: plan(mode: .scheduled), now: origin.addingTimeInterval(-60)).first)
        var record = CueRecord(request: request, status: .deliveryObserved); record.deliveredAt = origin
        let rem = SleepSegment(start: origin, end: origin.addingTimeInterval(600), stage: .rem, source: "A")
        let core = SleepSegment(start: origin, end: origin.addingTimeInterval(600), stage: .core, source: "B")
        XCTAssertEqual(SleepComparison().compare(record: record, segments: [rem, core]), .unknown)
        XCTAssertEqual(SleepComparison().compare(record: record, segments: [rem]), .matchesREM)
    }
    func testNextPlanHandlesMidnightAndDSTWithoutFixed86400Assumption() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0)))
        var settings = NightSettings(); settings.startHour = 2; settings.startMinute = 30
        let p = try XCTUnwrap(settings.nextPlan(now: now, calendar: calendar))
        XCTAssertGreaterThan(p.windowStart, now)
        XCTAssertLessThan(p.windowStart.timeIntervalSince(now), 24 * 3600)
        XCTAssertTrue(p.isValid)
    }
}
