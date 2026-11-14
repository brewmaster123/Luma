import Foundation

/// Stop delay, independent of the unchanged four-second AlarmKit WAV asset.
public enum AlarmSignalDuration {
  public static let defaultSeconds = 4
  public static let range = 3...10
  public static let preferenceKey = "luma.alarmkit.signal-duration.v1"

  public static func validated(_ seconds: Int?) -> Int {
    guard let seconds, range.contains(seconds) else { return defaultSeconds }
    return seconds
  }
}

/// Bounded time to finish Stop and resume audio after an interruption.
/// The default retains the existing eight-second grace / ten-second lease.
public struct AlarmInterruptionWindow: Equatable, Sendable {
  public let recoveryDelay: TimeInterval
  public let leaseDelay: TimeInterval

  public init(now: Date, stopAt: Date?) {
    let delta = stopAt?.timeIntervalSince(now) ?? 0
    let remaining = delta.isFinite ? min(10, max(0, delta)) : 0
    recoveryDelay = max(8, remaining + 4)
    leaseDelay = recoveryDelay + 2
  }
}
