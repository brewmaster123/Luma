import Foundation

public struct DecisionMemory: Codable, Equatable, Sendable {
    public var planID: UUID?
    public var candidateSince: Date?
    public var lastEvaluationAt: Date?
    public var latestEvidenceAt: Date?
    /// Reserve before scheduling. A crash must not produce a second burst.
    public var reservedBurst: Bool = false
    public init() {}
}

public enum CuePlanError: LocalizedError, Equatable {
    case invalidPlan, outsideWindow, burstAlreadyReserved, notEnoughTime
    public var errorDescription: String? {
        switch self {
        case .invalidPlan: return "Некорректный план сессии. Выберите время заново."
        case .outsideWindow: return "Время сигнала уже прошло. Выберите новое время."
        case .burstAlreadyReserved: return "Серия для этой сессии уже подготовлена."
        case .notEnoughTime: return "В оставшееся окно не помещается вся серия сигналов."
        }
    }
}

public struct CueEngine: Sendable {
    public init() {}

    public func scheduledRequests(plan: NightPlan, now: Date) throws -> [CueRequest] {
        guard plan.isValid else { throw CuePlanError.invalidPlan }
        // A command that arrives after its intended cue time is rejected, never moved to tomorrow.
        guard plan.windowStart > now.addingTimeInterval(1) else { throw CuePlanError.outsideWindow }
        return try makeRequests(plan: plan, firstAt: plan.windowStart)
    }

    public func decide(plan: NightPlan, evidence: REMEvidence, now: Date,
                       memory: inout DecisionMemory) -> [CueRequest] {
        guard plan.settings.mode == .experimentalREM, plan.contains(now) else {
            memory.candidateSince = nil; return []
        }
        if memory.planID != plan.id { memory = DecisionMemory(); memory.planID = plan.id }
        guard !memory.reservedBurst else { return [] }
        guard evidence.kind == .candidate, let sampleAt = evidence.latestSampleAt,
              sampleAt <= now, now.timeIntervalSince(sampleAt) <= 90 else {
            memory.candidateSince = nil; memory.lastEvaluationAt = now; return []
        }
        if let previous = memory.lastEvaluationAt,
           now < previous || now.timeIntervalSince(previous) > 90 { memory.candidateSince = nil }
        memory.lastEvaluationAt = now
        // Re-evaluating the same HealthKit measurement cannot establish a sustained state.
        if let last = memory.latestEvidenceAt, sampleAt <= last { return [] }
        memory.latestEvidenceAt = sampleAt
        if memory.candidateSince == nil { memory.candidateSince = now; return [] }
        guard let since = memory.candidateSince, now.timeIntervalSince(since) >= 120,
              let requests = try? makeRequests(plan: plan, firstAt: now.addingTimeInterval(3)) else { return [] }
        memory.reservedBurst = true
        return requests
    }

    private func makeRequests(plan: NightPlan, firstAt: Date) throws -> [CueRequest] {
        let count = plan.settings.cueCount.rawValue
        let gap = Double(plan.settings.validated().intervalSeconds)
        guard firstAt >= plan.windowStart, firstAt.addingTimeInterval(Double(count - 1) * gap) < plan.windowEnd else {
            throw CuePlanError.notEnoughTime
        }
        return (0..<count).map { index in
            CueRequest(id: "luma.\(plan.id.uuidString).\(index)", planID: plan.id,
                       index: index, fireAt: firstAt.addingTimeInterval(Double(index) * gap))
        }
    }
}

public enum ComparisonResult: String, Sendable {
    case matchesREM, anotherStage, unknown
}

public struct SleepComparison: Sendable {
    public init() {}
    /// Delivery must be observed. Scheduled time is not proof of a delivered vibration.
    /// Agreement with Apple is not accuracy against polysomnography.
    public func compare(record: CueRecord, segments: [SleepSegment]) -> ComparisonResult {
        guard record.status == .deliveryObserved, let date = record.deliveredAt else { return .unknown }
        let matches = segments.filter { $0.start <= date && date < $0.end }
        let stages = Set(matches.map(\.stage))
        guard stages.count == 1, let stage = stages.first, stage != .unspecified else { return .unknown }
        return stage == .rem ? .matchesREM : .anotherStage
    }
}
