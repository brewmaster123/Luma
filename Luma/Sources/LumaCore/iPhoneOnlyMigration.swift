import Foundation

extension SignalSettings {
  /// .phone identifies the AlarmKit owner. It does not suppress Apple's own
  /// system forwarding to paired Apple Watch; legacy raw values remain decodable.
  public var finiteCueSignal: Self {
    var signal = validated()
    signal.output = .phone; signal.melodySeconds = 4
    return signal
  }
  /// Retained for source compatibility with older core tests/data helpers.
  public var systemAlarmSignal: Self { finiteCueSignal }
}
extension LumaState {
  /// Retain alarm IDs/dates/repeat days, audio references, journal and feedback.
  /// Keep legacy schedules and voice references while selecting AlarmKit.
  public mutating func migrateToiPhoneOnly(now: Date = Date()) {
    useAlarmKitDelivery()
    signal = signal.finiteCueSignal
    source = .phone
    for i in alarms.indices { alarms[i].signal = alarms[i].signal.finiteCueSignal }
    for i in sessions.indices where sessions[i].status != .ended {
      sessions[i].status = .ended
      sessions[i].endedAt = now
    }
  }
}
extension SystemAlarmLedger {
  /// Retain session identity/cadence. Queue migration is a separate transaction.
  @discardableResult public mutating func migrateToiPhoneOnly() -> Bool {
    guard var session = indirectSession else { return false }
    let normalized = session.signal.systemAlarmSignal
    guard session.signal != normalized else { return false }
    session.signal = normalized; indirectSession = session
    return true
  }
}
