import Foundation

/// Release gates, independent from future StoreKit entitlement checks.
public enum LumaFeatures {
  public static let remNightEnabled = false
  /// No documented system-managed short auto-dismiss is available in AlarmKit.
  /// App timers and alarmUpdates cannot guarantee execution on a locked phone.
  /// The test build explicitly discloses this limitation before arming AlarmKit.
  public static let alarmKitAutomaticStopVerified = false
}

public struct IndirectMethodSettings: Codable, Equatable, Sendable {
  public var intervalMinutes: Int
  public init(intervalMinutes: Int = 30) {
    self.intervalMinutes = min(60, max(10, intervalMinutes))
  }
  public var validated: Self { Self(intervalMinutes: intervalMinutes) }
  public var interval: TimeInterval { Double(validated.intervalMinutes) * 60 }
  /// A cadence counts from activation, not from the end of the preceding sound.
  /// Skip missed intervals rather than replaying a burst after a suspended app.
  public func nextSignal(startedAt: Date, after now: Date) -> Date {
    let elapsed = max(0, now.timeIntervalSince(startedAt))
    return startedAt.addingTimeInterval((floor(elapsed / interval) + 1) * interval)
  }
}
