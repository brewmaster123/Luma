import Foundation
#if canImport(AlarmKit)
import AlarmKit
#endif

/// Upgrade cleanup only. New alarms and REM cues never use AlarmKit.
/// Retain this for users installing over v0.3 or v0.4 with queued system alarms.
@MainActor final class LegacyAlarmCleanup {
  private let keys = ["luma.system-alarm.configurations.v1", "luma.alarmkit.stop-windows.v1"]
  private var completed = false

  func removeRemainingAlarms() throws {
    guard !completed else { return }
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let manager = AlarmManager.shared
      if manager.authorizationState == .authorized {
        // AlarmManager lists this app's alarms only, including an already ringing one.
        // Enumerate them even if a prior crash lost Luma's cached IDs.
        let alarms = try manager.alarms
        var failures = 0
        for alarm in alarms {
          do { try manager.cancel(id: alarm.id) } catch { failures += 1 }
        }
        guard failures == 0, try manager.alarms.isEmpty else {
          throw AppError.message("Не удалось отменить сигналы предыдущей версии. Откройте Luma ещё раз перед настройкой новых сигналов.")
        }
        finish()
        return
      }
    }
    #endif
    guard !hasLegacyRecords else {
      throw AppError.message("Сначала нужно отменить будильники предыдущей версии. В настройках iPhone разрешите Luma доступ к будильникам и снова откройте приложение. Данные и записи сохранятся.")
    }
    // Fresh installs and older iOS versions do not request AlarmKit permission.
    finish()
  }

  private var hasLegacyRecords: Bool {
    keys.contains { key in
      if let dictionary = UserDefaults.standard.dictionary(forKey: key) { return !dictionary.isEmpty }
      if let data = UserDefaults.standard.data(forKey: key) {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return true }
        if let array = value as? [Any] { return !array.isEmpty }
        if let dictionary = value as? [String: Any] { return !dictionary.isEmpty }
        return true
      }
      return false
    }
  }
  private func finish() {
    keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    completed = true
  }
}
