import Foundation

public enum CueCount: Int, Codable, CaseIterable, Identifiable, Sendable {
  case one = 1
  case two = 2
  case three = 3
  case five = 5
  public var id: Int { rawValue }
}

public enum NightMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case scheduled, experimentalREM
  public var id: String { rawValue }
  public var title: String { self == .scheduled ? "По времени" : "По признакам REM" }
}

public struct NightSettings: Codable, Equatable, Sendable {
  public var mode: NightMode = .scheduled
  public var cueCount: CueCount = .two
  public var intervalSeconds: Int = 12
  public var startHour: Int = 5
  public var startMinute: Int = 30
  public var windowMinutes: Int = 30
  public init() {}

  public func validated() -> NightSettings {
    var value = self
    value.intervalSeconds = [8, 12, 20].contains(intervalSeconds) ? intervalSeconds : 12
    value.startHour = min(23, max(0, startHour))
    value.startMinute = min(59, max(0, startMinute))
    value.windowMinutes = [20, 30].contains(windowMinutes) ? windowMinutes : 30
    return value
  }

  public func nextPlan(now: Date, calendar: Calendar = .current) -> NightPlan? {
    let s = validated()
    guard
      let start = calendar.nextDate(
        after: now.addingTimeInterval(60),
        matching: DateComponents(hour: s.startHour, minute: s.startMinute),
        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward
      )
    else { return nil }
    return NightPlan(
      createdAt: now, windowStart: start,
      windowEnd: start.addingTimeInterval(Double(s.windowMinutes * 60)), settings: s)
  }
}

public struct NightPlan: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var createdAt: Date
  public var windowStart: Date
  public var windowEnd: Date
  public var settings: NightSettings
  public init(
    id: UUID = UUID(), createdAt: Date, windowStart: Date, windowEnd: Date, settings: NightSettings
  ) {
    self.id = id
    self.createdAt = createdAt
    self.windowStart = windowStart
    self.windowEnd = windowEnd
    self.settings = settings.validated()
  }
  public var isValid: Bool {
    let span = windowEnd.timeIntervalSince(windowStart)
    return span >= 60 && span <= 1800 && windowStart >= createdAt
  }
  public func contains(_ date: Date) -> Bool { isValid && date >= windowStart && date < windowEnd }
}

public struct HeartSample: Codable, Equatable, Sendable {
  public var date: Date
  public var bpm: Double
  public var source: String
  public init(date: Date, bpm: Double, source: String = "watch") {
    self.date = date
    self.bpm = bpm
    self.source = source
  }
}

public struct MotionEpoch: Codable, Equatable, Sendable {
  public var start: Date
  public var end: Date
  public var rmsG: Double
  public var sampleCount: Int
  public init(start: Date, end: Date, rmsG: Double, sampleCount: Int) {
    self.start = start
    self.end = end
    self.rmsG = rmsG
    self.sampleCount = sampleCount
  }
}

public enum EvidenceKind: String, Codable, Sendable {
  case insufficient, unlikely, candidate
}

public struct REMEvidence: Codable, Equatable, Sendable {
  public var kind: EvidenceKind
  /// An uncalibrated engineering score. NEVER display it as probability or accuracy.
  public var heuristicScore: Double?
  public var latestSampleAt: Date?
  public var explanation: String
  public init(
    kind: EvidenceKind, heuristicScore: Double? = nil, latestSampleAt: Date? = nil,
    explanation: String
  ) {
    self.kind = kind
    self.heuristicScore = heuristicScore
    self.latestSampleAt = latestSampleAt
    self.explanation = explanation
  }
  public static func unavailable(_ message: String) -> REMEvidence {
    REMEvidence(kind: .insufficient, explanation: message)
  }
  public var title: String {
    switch kind {
    case .insufficient: return "Недостаточно данных"
    case .unlikely: return "Устойчивых признаков нет"
    case .candidate: return "REM-подобные признаки"
    }
  }
}

public struct CueRequest: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var planID: UUID
  public var index: Int
  public var fireAt: Date
}

public enum CueStatus: String, Codable, Sendable {
  case reserved, scheduled, deliveryObserved, failed, cancelled
}

public struct CueRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var planID: UUID
  public var scheduledAt: Date
  public var deliveredAt: Date?
  public var status: CueStatus
  public var note: String
  public init(request: CueRequest, status: CueStatus = .reserved, note: String = "") {
    id = request.id
    planID = request.planID
    scheduledAt = request.fireAt
    self.status = status
    self.note = note
  }
}

public enum SleepStage: String, Codable, Hashable, Sendable {
  case awake, core, deep, rem, unspecified
  public var title: String {
    switch self {
    case .awake: return "Бодрствование"
    case .core: return "Основной"
    case .deep: return "Глубокий"
    case .rem: return "REM"
    case .unspecified: return "Сон без стадии"
    }
  }
}

public struct SleepSegment: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var start: Date
  public var end: Date
  public var stage: SleepStage
  public var source: String
  public init(
    id: String = UUID().uuidString, start: Date, end: Date, stage: SleepStage, source: String
  ) {
    self.id = id
    self.start = start
    self.end = end
    self.stage = stage
    self.source = source
  }
}

public struct DreamEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID = UUID()
  public var date: Date = Date()
  public var text: String = ""
  public var noticedCue: Bool = false
  public var reportedLucidity: Bool = false
  public init() {}
}

public enum PlanState: String, Codable, Sendable {
  case none, awaitingWatch, armed, finished, cancelled, failed
}

public enum PacketKind: String, Codable, Sendable { case arm, cancel, receipt, snapshot }

public struct SyncPacket: Codable, Identifiable, Sendable {
  public let protocolVersion: Int
  public var id: UUID
  public var sentAt: Date
  public var kind: PacketKind
  public var plan: NightPlan?
  public var replyTo: UUID?
  public var planState: PlanState?
  public var message: String?
  public var records: [CueRecord]?
  public init(
    kind: PacketKind, plan: NightPlan? = nil, replyTo: UUID? = nil,
    planState: PlanState? = nil, message: String? = nil, records: [CueRecord]? = nil
  ) {
    protocolVersion = 1
    id = UUID()
    sentAt = Date()
    self.kind = kind
    self.plan = plan
    self.replyTo = replyTo
    self.planState = planState
    self.message = message
    self.records = records
  }
}

public struct AppArchive: Codable, Sendable {
  public var v2: LumaState?
  public var schemaVersion = 1
  public var settings = NightSettings()
  public var plan: NightPlan?
  public var planState: PlanState = .none
  public var pendingCommand: SyncPacket?
  public var lastCommandAt: Date = .distantPast
  public var processedCommands: [UUID] = []
  public var commandReceipts: [SyncPacket] = []
  public var records: [CueRecord] = []
  public var diary: [DreamEntry] = []
  public var decision = DecisionMemory()
  public var onboardingComplete = false
  public init() {}
}
