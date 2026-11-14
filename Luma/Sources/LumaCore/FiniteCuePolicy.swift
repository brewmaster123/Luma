import Foundation

/// Metadata copied from the system queue. It is evidence of admission/delivery,
/// never evidence that a speaker sounded or that an acoustic stop was measured.
public struct FiniteCueSnapshot: Equatable, Sendable {
  public var identifier: String
  public var key: String
  public var fireAt: Date
  public var title: String
  public var soundName: String
  public var repeats: Bool
  public var hasSound: Bool
  /// AlarmKit exposes IDs/state, not the full sound/presentation configuration.
  public var metadataVisible: Bool
  public var alerting: Bool
  public init(identifier: String, key: String = "", fireAt: Date = .distantPast,
    title: String = "", soundName: String = "", repeats: Bool = false, hasSound: Bool = false,
    metadataVisible: Bool = true, alerting: Bool = false) {
    self.identifier = identifier; self.key = key; self.fireAt = fireAt
    self.title = title; self.soundName = soundName; self.repeats = repeats; self.hasSound = hasSound
    self.metadataVisible = metadataVisible; self.alerting = alerting
  }
  public func matches(_ record: SystemAlarmRecord) -> Bool {
    // userInfo stores Unix seconds; Date internally uses another epoch. Their
    // floating-point round trip can differ by a fraction of a microsecond.
    identifier == record.notificationID && (!metadataVisible || (key == record.key
      && abs(fireAt.timeIntervalSince(record.fireAt)) < 0.001
      && title == record.title && soundName == record.soundName && hasSound && !repeats))
  }
}

public enum FiniteCuePolicy {
  public static let prefix = "luma.alarmkit."
  public static let consentKey = "luma.alarmkit.night-audio-stop.v3"
  public static func identifier(for id: UUID) -> String { prefix + id.uuidString }
  /// Historical notification-budget helper; AlarmKit uses queueLimit directly.
  public static func capacity(otherPending: Int) -> Int {
    min(SystemAlarmPolicy.queueLimit, max(0, 64 - max(0, otherPending)))
  }
  public static func validSoundName(_ name: String) -> Bool {
    name == "luma-alarm-4.wav" || (name.hasPrefix("luma-ak4-") && name.hasSuffix(".wav")
      && !name.contains("/") && !name.contains("\\") && !name.contains(".."))
  }
}
