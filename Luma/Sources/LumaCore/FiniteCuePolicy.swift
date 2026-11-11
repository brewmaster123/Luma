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
  public init(identifier: String, key: String = "", fireAt: Date = .distantPast,
    title: String = "", soundName: String = "", repeats: Bool = false, hasSound: Bool = false) {
    self.identifier = identifier; self.key = key; self.fireAt = fireAt
    self.title = title; self.soundName = soundName; self.repeats = repeats; self.hasSound = hasSound
  }
  public func matches(_ record: SystemAlarmRecord) -> Bool {
    // userInfo stores Unix seconds; Date internally uses another epoch. Their
    // floating-point round trip can differ by a fraction of a microsecond.
    identifier == record.notificationID && key == record.key
      && abs(fireAt.timeIntervalSince(record.fireAt)) < 0.001
      && title == record.title && soundName == record.soundName && hasSound && !repeats
  }
}

public enum FiniteCuePolicy {
  public static let prefix = "luma.cue."
  public static let consentKey = "luma.notifications.finite-cues-consent.v1"
  public static func identifier(for id: UUID) -> String { prefix + id.uuidString }
  public static func capacity(otherPending: Int) -> Int {
    min(SystemAlarmPolicy.queueLimit, max(0, 64 - max(0, otherPending)))
  }
  public static func validSoundName(_ name: String) -> Bool {
    name == "luma-tone-4.wav" || (name.hasPrefix("luma-cue4-") && name.hasSuffix(".caf")
      && !name.contains("/") && !name.contains("\\") && !name.contains(".."))
  }
}
