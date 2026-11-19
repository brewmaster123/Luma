import Foundation

/// 1.0: how loud the AlarmKit signal is, as a share of the full level of 0.9.9.
///
/// AlarmKit has no volume setting of its own: an alarm plays at the iPhone's ringer volume.
/// Lumenoir already writes its own four-second copy of every signal sound, so the level is
/// baked into that copy. The scale follows loudness, not amplitude: every halving of the
/// percentage is 10 dB, which the ear hears as about half as loud. 100 % is exactly the sound
/// of 0.9.9 (same file name, same bytes); 50 %, the default, is −10 dB, "в 2 раза тише" as the
/// user asked on 19 Nov 2026. Older versions ignore the stored value, so rolling back is safe.
public enum AlarmSignalVolume {
  public static let range = 20...100
  public static let step = 10
  public static let defaultPercent = 50
  public static let unityPercent = 100
  public static let preferenceKey = "luma.alarmkit.signal-volume.v1"

  /// A stored or requested level, or the default if it is missing or not on the scale.
  public static func validated(_ percent: Int?) -> Int {
    guard let percent, range.contains(percent), percent % step == 0 else { return defaultPercent }
    return percent
  }

  /// 0 dB at 100 %, −10 dB at 50 %, about −23 dB at 20 %.
  public static func decibels(_ percent: Int) -> Double {
    10 * log2(Double(validated(percent)) / 100)
  }

  /// The factor the samples are multiplied by: exactly 1 at 100 %, never above 1.
  public static func gain(_ percent: Int) -> Double {
    let value = validated(percent)
    return value == unityPercent ? 1 : pow(10, decibels(value) / 20)
  }

  public static func current(_ defaults: UserDefaults = .standard) -> Int {
    validated(defaults.object(forKey: preferenceKey) as? Int)
  }
}
