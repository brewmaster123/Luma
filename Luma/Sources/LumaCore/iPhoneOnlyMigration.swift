import Foundation

extension SignalSettings {
  /// .phone identifies the AlarmKit owner. It does not suppress Apple's own
  /// system forwarding to paired Apple Watch; legacy raw values remain decodable.
  public var systemAlarmSignal: Self {
    var signal = validated()
    signal.output = .phone; signal.melodySeconds = 4
    return signal
  }
}
extension LumaState {
  /// Retain alarm IDs/dates/repeat days, audio references, journal and feedback.
  /// A legacy Watch-only alarm must become an iPhone AlarmKit alarm, not vanish.
  public mutating func migrateToiPhoneOnly(now: Date = Date()) {
    useAlarmKitDelivery()
    signal = signal.systemAlarmSignal
    source = .phone
    for i in alarms.indices { alarms[i].signal = alarms[i].signal.systemAlarmSignal }
    for i in sessions.indices where sessions[i].status != .ended {
      sessions[i].status = .ended
      sessions[i].endedAt = now
    }
  }
}
extension SystemAlarmLedger {
  /// Existing accepted system alarms and stop deadlines are untouched.
  @discardableResult public mutating func migrateToiPhoneOnly() -> Bool {
    guard var session = indirectSession else { return false }
    let normalized = session.signal.systemAlarmSignal
    guard session.signal != normalized else { return false }
    session.signal = normalized; indirectSession = session
    return true
  }
}
