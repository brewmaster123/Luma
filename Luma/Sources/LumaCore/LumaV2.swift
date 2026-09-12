import Foundation

public enum SignalOutput: String, Codable, CaseIterable, Identifiable, Sendable {
  case both, phone, watch
  public var id: String { rawValue }
  public var title: String {
    self == .both ? "iPhone + Watch" : self == .phone ? "Только iPhone" : "Только Watch"
  }
  public var phoneEnabled: Bool { self != .watch }
  public var watchEnabled: Bool { self != .phone }
}
public enum SensorSource: String, Codable, CaseIterable, Identifiable, Sendable {
  case combined, watch, phone
  public var id: String { rawValue }
  public var title: String {
    self == .combined ? "Часы + микрофон" : self == .watch ? "Apple Watch" : "Только iPhone"
  }
  public var usesMicrophone: Bool { self != .watch }
  public var usesWatch: Bool { self != .phone }
}
public struct SignalSettings: Codable, Equatable, Sendable {
  public var output: SignalOutput = .both
  public var count: CueCount = .two
  public var gapSeconds = 8
  public var melodySeconds = 8
  public var voiceID: UUID?
  public init() {}
  public func validated() -> Self {
    var s = self
    s.gapSeconds = gapSeconds == 20 ? 12 : ([3, 8, 12].contains(gapSeconds) ? gapSeconds : 8)
    s.melodySeconds = [4, 8, 15].contains(melodySeconds) ? melodySeconds : 8
    return s
  }
}
public struct VoiceClip: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var filename: String
  public var duration: Double
  public var imported: Bool?
  public var sourceDuration: Double?
  public init(id: UUID, name: String, filename: String, duration: Double) {
    self.id = id
    self.name = name
    self.filename = filename
    self.duration = duration
  }
}
public enum PhoneAlarmDelivery: String, Codable, CaseIterable, Identifiable, Sendable {
  case shortCue, systemAlarm
  public var id: String { rawValue }
  public var title: String { self == .systemAlarm ? "Системный будильник" : "Короткая подсказка" }
}
public struct JournalVoice: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var filename: String
  public var duration: Double
  public var createdAt: Date
  public init(id: UUID, filename: String, duration: Double, createdAt: Date = Date()) {
    self.id = id; self.filename = filename; self.duration = duration; self.createdAt = createdAt
  }
  public var hasSafeFilename: Bool { filename == "luma-journal-\(id.uuidString).m4a" }
}
public struct LumaAlarm: Codable, Identifiable, Equatable, Sendable {
  public var id = UUID()
  public var title = "Подсказка во сне"
  public var hour = 5
  public var minute = 30
  public var enabled = true
  /// Calendar weekday, Sunday = 1. Empty means a fixed one-shot, not a daily repeat.
  public var weekdays: Set<Int> = []
  public var onceAt = Date().addingTimeInterval(3600)
  public var signal = SignalSettings()
  public var phoneDelivery: PhoneAlarmDelivery?
  public var delivery: PhoneAlarmDelivery { phoneDelivery ?? .shortCue }
  public init() {}
  public func next(after date: Date, calendar: Calendar = .current) -> Date? {
    guard enabled else { return nil }
    if weekdays.isEmpty { return onceAt > date ? onceAt : nil }
    return weekdays.filter { (1...7).contains($0) }.compactMap {
      calendar.nextDate(
        after: date,
        matching: DateComponents(
          hour: min(23, max(0, hour)), minute: min(59, max(0, minute)), weekday: $0),
        matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }.min()
  }
}
public struct AlarmOccurrence: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var alarmID: UUID
  public var date: Date
  public var title: String
  public var signal: SignalSettings
}
public enum AlarmPlanner {
  public static func sorted(_ alarms: [LumaAlarm], after now: Date, calendar: Calendar = .current) -> [LumaAlarm] {
    alarms.map { ($0, $0.next(after: now, calendar: calendar)) }.sorted { lhs, rhs in
      switch (lhs.1, rhs.1) {
      case let (a?, b?) where a != b: return a < b
      case (_?, nil): return true
      case (nil, _?): return false
      default:
        if lhs.0.hour != rhs.0.hour { return lhs.0.hour < rhs.0.hour }
        if lhs.0.minute != rhs.0.minute { return lhs.0.minute < rhs.0.minute }
        return lhs.0.id.uuidString < rhs.0.id.uuidString
      }
    }.map { $0.0 }
  }

  public static func occurrences(
    _ alarms: [LumaAlarm], after: Date, limit: Int = 64, calendar: Calendar = .current
  ) -> [AlarmOccurrence] {
    guard limit > 0 else { return [] }
    var next = alarms.compactMap { a in a.next(after: after, calendar: calendar).map { (a, $0) } }
    var result: [AlarmOccurrence] = []
    while !next.isEmpty && result.count < limit {
      next.sort { $0.1 == $1.1 ? $0.0.id.uuidString < $1.0.id.uuidString : $0.1 < $1.1 }
      let (a, d) = next.removeFirst()
      result.append(
        AlarmOccurrence(
          id: "luma.alarm.\(a.id.uuidString).\(Int(d.timeIntervalSince1970))", alarmID: a.id,
          date: d, title: a.title, signal: a.signal.validated()))
      if !a.weekdays.isEmpty, let n = a.next(after: d, calendar: calendar) { next.append((a, n)) }
    }
    return result
  }
}
public struct BreathSample: Codable, Equatable, Sendable {
  public var date: Date
  public var perMinute: Double
  public init(date: Date, perMinute: Double) {
    self.date = date
    self.perMinute = perMinute
  }
}
public struct AudioEpoch: Codable, Equatable, Sendable {
  public var start: Date
  public var end: Date
  public var levelDB: Double
  public var transientFraction: Double
  /// Acoustic periodicity only, NOT a clinical respiratory measurement.
  public var breathingProxy: Double?
  public var periodicity: Double
  public var contaminated = false
  public init(
    start: Date, end: Date, levelDB: Double, transientFraction: Double, breathingProxy: Double?,
    periodicity: Double, contaminated: Bool = false
  ) {
    self.start = start
    self.end = end
    self.levelDB = levelDB
    self.transientFraction = transientFraction
    self.breathingProxy = breathingProxy
    self.periodicity = periodicity
    self.contaminated = contaminated
  }
}
public struct FeatureSnapshot: Codable, Equatable, Sendable {
  public var date: Date
  public var source: SensorSource
  public var heartRate: Double?
  public var heartSpread: Double?
  public var respiration: Double?
  public var acousticBreathing: Double?
  public var movement: Double?
  public var soundDB: Double?
  public var score: Double?
  public init(
    date: Date, source: SensorSource, heartRate: Double? = nil, heartSpread: Double? = nil
  ) {
    self.date = date
    self.source = source
    self.heartRate = heartRate
    self.heartSpread = heartSpread
  }
}
public enum SessionStatus: String, Codable, Sendable { case running, paused, ended }
public struct REMEpisode: Codable, Identifiable, Equatable, Sendable {
  public var id = UUID()
  public var date: Date
  public var features: FeatureSnapshot
  public var phoneResult: String?
  public var watchResult: String?
  public init(date: Date, features: FeatureSnapshot) {
    self.date = date
    self.features = features
  }
}
public struct NightSession: Codable, Identifiable, Equatable, Sendable {
  public var id = UUID()
  public var startedAt = Date()
  public var endedAt: Date?
  public var source: SensorSource
  public var signal: SignalSettings
  public var status: SessionStatus = .running
  public var episodes: [REMEpisode] = []
  public var samples: [FeatureSnapshot] = []
  public init(source: SensorSource, signal: SignalSettings) {
    self.source = source
    self.signal = signal.validated()
  }
}
public enum FeedbackAnswer: String, Codable, CaseIterable, Identifiable, Sendable {
  case yes, no, unsure
  public var id: String { rawValue }
  public var title: String { self == .yes ? "Да" : self == .no ? "Нет" : "Не помню" }
}
public struct SessionFeedback: Codable, Identifiable, Equatable, Sendable {
  public var sessionID: UUID
  public var id: UUID { sessionID }
  public var updatedAt = Date()
  public var noticed: FeedbackAnswer = .unsure
  public var lucid: FeedbackAnswer = .unsure
  public var awakened: FeedbackAnswer = .unsure
  public var note = ""
  public var episodeID: UUID?
  public var voiceNotes: [JournalVoice]?
  public init(sessionID: UUID) { self.sessionID = sessionID }
}
public struct LumaState: Codable, Sendable {
  public var version = 2
  public var signal = SignalSettings()
  public var source: SensorSource = .combined
  public var alarms: [LumaAlarm] = []
  public var voices: [VoiceClip] = []
  public var sessions: [NightSession] = []
  public var feedback: [SessionFeedback] = []
  public var phoneVibration: Bool?
  public var defaultPhoneDelivery: PhoneAlarmDelivery?
  public var vibratesOnPhone: Bool { phoneVibration ?? false }
  public var personalizationEnabled = false
  public var episodeMemory = EpisodeMemory()
  public var configurationRevision: Date = .distantPast
  public var processedEvents: [UUID] = []
  public var completedAlarmIDs: [String] = []
  public var mutedWatchSessions: [UUID] = []
  public init() {}
}
/// Persistent hysteresis. Missing data cannot establish exit; a crash cannot replay a reserved episode.
public struct EpisodeMemory: Codable, Equatable, Sendable {
  public var candidateSince: Date?
  public var exitSince: Date?
  public var lastSample: Date?
  public var lastEvaluation: Date?
  public var lastCue: Date?
  public var insideEpisode = false
  public init() {}
  public mutating func consume(_ evidence: REMEvidence, now: Date) -> Bool {
    guard let date = evidence.latestSampleAt, date <= now, now.timeIntervalSince(date) <= 90,
      evidence.kind != .insufficient
    else {
      candidateSince = nil
      exitSince = nil
      lastEvaluation = now
      return false
    }
    if let previous = lastEvaluation, now <= previous || now.timeIntervalSince(previous) > 90 {
      candidateSince = nil
      exitSince = nil
    }
    lastEvaluation = now
    guard lastSample == nil || date > lastSample! else { return false }
    lastSample = date
    if evidence.kind == .unlikely {
      candidateSince = nil
      if exitSince == nil { exitSince = now }
      if let exitSince, now.timeIntervalSince(exitSince) >= 300 { insideEpisode = false }
      return false
    }
    exitSince = nil
    guard !insideEpisode else { return false }
    if candidateSince == nil { candidateSince = now }
    guard let since = candidateSince, now.timeIntervalSince(since) >= 120,
      lastCue == nil || now.timeIntervalSince(lastCue!) >= 1200
    else { return false }
    insideEpisode = true
    lastCue = now
    candidateSince = nil
    return true
  }
}
public enum WireKind: String, Codable, Sendable {
  case configuration, acknowledgement, sensors, cue
}
public struct WirePacket: Codable, Sendable {
  public var version = 2
  public var id = UUID()
  public var sentAt = Date()
  public var kind: WireKind
  public var revision: Date?
  public var alarms: [LumaAlarm]?
  public var sessionID: UUID?
  public var source: SensorSource?
  public var signal: SignalSettings?
  public var heart: [HeartSample]?
  public var breath: [BreathSample]?
  public var motion: [MotionEpoch]?
  public var episodeID: UUID?
  public var replyTo: UUID?
  public var message: String?
  public init(kind: WireKind) { self.kind = kind }
}
