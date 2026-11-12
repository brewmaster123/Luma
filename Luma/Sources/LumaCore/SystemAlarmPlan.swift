import Foundation

/// Schema 1: earlier AlarmKit; schema 2: notification trial; schema 3: AlarmKit
/// with a dedicated four-second WAV. Keep the storage location/record decoder.
public enum SystemAlarmKind: String, Codable, Hashable, Sendable { case smart, indirect, probe }
public struct SystemAlarmRequest: Equatable, Sendable {
  public var key: String
  public var ownerID: UUID
  public var kind: SystemAlarmKind
  public var fireAt: Date
  public var title: String
  public var source: URL
  public init(key: String, ownerID: UUID, kind: SystemAlarmKind, fireAt: Date,
    title: String, source: URL) {
    self.key = key; self.ownerID = ownerID; self.kind = kind
    self.fireAt = fireAt; self.title = title; self.source = source
  }
}
public struct SystemAlarmRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var key: String
  public var ownerID: UUID
  public var kind: SystemAlarmKind
  public var fireAt: Date
  public var title: String
  public var soundName: String
  /// Written before schedule() and cleared only after the system accepts it.
  public var pending: Bool
  public var stopAt: Date { fireAt.addingTimeInterval(SystemAlarmPolicy.soundSeconds) }
  public var notificationID: String { FiniteCuePolicy.identifier(for: id) }
  public init(id: UUID = UUID(), request: SystemAlarmRequest, soundName: String) {
    self.id = id; key = request.key; ownerID = request.ownerID; kind = request.kind
    fireAt = request.fireAt; title = request.title; self.soundName = soundName; pending = true
  }
}
public struct IndirectAlarmSession: Codable, Equatable, Sendable {
  public var id: UUID
  public var startedAt: Date
  public var settings: IndirectMethodSettings
  public var signal: SignalSettings
  public init(settings: IndirectMethodSettings, signal: SignalSettings, startedAt: Date = Date()) {
    id = UUID(); self.startedAt = startedAt; self.settings = settings.validated
    self.signal = signal.finiteCueSignal
  }
  public func dates(after now: Date, horizon: TimeInterval = SystemAlarmPolicy.queueHorizon) -> [Date] {
    guard now.timeIntervalSince1970.isFinite, startedAt.timeIntervalSince1970.isFinite,
      horizon.isFinite, horizon > 0 else { return [] }
    let step = settings.validated.interval
    let first = settings.nextSignal(startedAt: startedAt, after: now)
    let end = now.addingTimeInterval(min(horizon, SystemAlarmPolicy.queueHorizon))
    guard first <= end else { return [] }
    let count = min(SystemAlarmPolicy.queueLimit, Int(floor(end.timeIntervalSince(first) / step)) + 1)
    return (0..<count).map { first.addingTimeInterval(Double($0) * step) }
  }
  public func key(for date: Date) -> String {
    "luma.indirect.\(id.uuidString).\(Int(date.timeIntervalSince1970))"
  }
}
public struct SystemAlarmLedger: Codable, Equatable, Sendable {
  public var schema = 3
  public var records: [SystemAlarmRecord] = []
  public var handledKeys: [String] = []
  public var indirectSession: IndirectAlarmSession?
  /// Write cancellation intent before touching the daemon, so a crash cannot
  /// resurrect a stopped interval session or silently forget a failed cancel.
  public var cancelledOwners: [UUID]?
  public var cancelAllRequested: Bool?
  public init() {}
  /// Call after BOTH old notification requests and old AlarmKit alarms have
  /// been cancelled. Preserve the interval origin and future occurrence keys.
  @discardableResult public mutating func migrateToAlarmKitWave(now: Date) -> Bool {
    guard schema == 1 || schema == 2 else { return false }
    let sessionCancelled = indirectSession.map { (cancelledOwners ?? []).contains($0.id) } ?? false
    if cancelAllRequested == true || sessionCancelled { indirectSession = nil }
    for record in records where record.fireAt <= now { markHandled(record) }
    records.removeAll()
    cancelAllRequested = nil; cancelledOwners = nil
    schema = 3
    return true
  }
  /// Call only AFTER all legacy AlarmKit alarms have been cancelled and verified.
  /// Future occurrences must remain eligible; an elapsed cue is never replayed.
  @discardableResult public mutating func migrateToFiniteNotifications(now: Date) -> Bool {
    guard schema == 1 else { return false }
    let sessionCancelled = indirectSession.map { (cancelledOwners ?? []).contains($0.id) } ?? false
    if cancelAllRequested == true || sessionCancelled {
      indirectSession = nil
    }
    for record in records where record.fireAt <= now { markHandled(record) }
    records.removeAll()
    cancelledOwners = nil; cancelAllRequested = nil
    schema = 2
    return true
  }
  public mutating func markHandled(_ record: SystemAlarmRecord) {
    records.removeAll { $0.id == record.id }
    handledKeys.removeAll { $0 == record.key }
    handledKeys.append(record.key)
    handledKeys = Array(handledKeys.suffix(4096))
  }
}
public enum SystemAlarmPolicy {
  public static let soundSeconds: TimeInterval = 4
  /// A finite system queue, replenished while the app executes; not an infinite OS timer.
  public static let queueHorizon: TimeInterval = 12 * 60 * 60
  // Bounded app queue; the daemon can reject admission earlier. This is not an
  // assertion about a fixed OS AlarmKit limit.
  public static let queueLimit = 60
  public enum StopAction: Equatable, Sendable {
    case none
    case wait(until: Date)
    case stop(lateBy: TimeInterval)
  }
  public static func stopAction(record: SystemAlarmRecord, alerting: Bool, now: Date) -> StopAction {
    guard alerting else { return .none }
    // Never grant another four seconds after a delayed update or relaunch.
    if now >= record.stopAt { return .stop(lateBy: now.timeIntervalSince(record.stopAt)) }
    return .wait(until: record.stopAt)
  }
  public static func desired(_ requests: [SystemAlarmRequest], after now: Date,
    handled: Set<String>) -> [SystemAlarmRequest] {
    var keys = Set<String>()
    return requests.filter {
      $0.fireAt.timeIntervalSince1970.isFinite && $0.fireAt > now.addingTimeInterval(1)
        && !handled.contains($0.key) && keys.insert($0.key).inserted
    }.sorted { $0.fireAt == $1.fireAt ? $0.key < $1.key : $0.fireAt < $1.fireAt }
      .prefix(queueLimit).map { $0 }
  }
}
