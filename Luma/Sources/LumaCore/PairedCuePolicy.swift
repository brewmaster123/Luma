import Foundation

/// Separate phone playback and Watch notifications; the delayed phone notification
/// is a fallback, never a second live sound.
public enum PairedCuePolicy {
  public static let fallbackDelay: TimeInterval = 5
  public static let maximumAlarmLateness: TimeInterval = 2
  public static let cueLeadTime: TimeInterval = 4
  /// A paired alarm needs an already-running phone audio session before iOS suspends
  /// the app. Sleep alarms are expected to be armed shortly before bed, so keep the
  /// runtime only for the upcoming night instead of holding the microphone for days.
  public static let phoneRuntimeHorizon: TimeInterval = 16 * 60 * 60
  public static func phoneNotificationDate(_ occurrence: AlarmOccurrence) -> Date {
    occurrence.date.addingTimeInterval(occurrence.signal.output == .both ? fallbackDelay : 0)
  }

  public static func needsPhoneRuntime(
    _ occurrences: [AlarmOccurrence], now: Date, completedIDs: Set<String>
  ) -> Bool {
    occurrences.contains { occurrence in
      occurrence.signal.output == .both
        && !completedIDs.contains(occurrence.id)
        && occurrence.date >= now.addingTimeInterval(-maximumAlarmLateness)
        && occurrence.date <= now.addingTimeInterval(phoneRuntimeHorizon)
    }
  }
  public static func canPlayAlarm(_ occurrence: AlarmOccurrence, now: Date,
    runtimeAvailable: Bool, completedIDs: Set<String>) -> Bool {
    let age = now.timeIntervalSince(occurrence.date)
    return runtimeAvailable && occurrence.signal.output == .both
      && age >= 0 && age <= maximumAlarmLateness && !completedIDs.contains(occurrence.id)
  }
  public static func watchStart(requested: Date?, now: Date) -> Date? {
    guard let requested else { return now.addingTimeInterval(2) }
    let lead = requested.timeIntervalSince(now)
    guard lead >= -maximumAlarmLateness, lead <= 10 else { return nil }
    return max(requested, now.addingTimeInterval(1.1))
  }
  public static func microphoneIsFresh(lastInput: Date?, now: Date) -> Bool {
    guard let lastInput else { return false }
    return (0...3).contains(now.timeIntervalSince(lastInput))
  }
}
