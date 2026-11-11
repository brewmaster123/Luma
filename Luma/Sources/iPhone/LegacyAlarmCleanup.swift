import Foundation
#if os(iOS) && canImport(AlarmKit)
import AlarmKit
#endif

/// This release never schedules AlarmKit. Cancel this app's daemon alarms,
/// including orphan IDs and ringing alarms, before admitting any finite cue.
@MainActor final class LegacyAlarmCleanup {
  private let keys = ["luma.system-alarm.configurations.v1", "luma.alarmkit.stop-windows.v1"]
  private let oldConsentKey = "luma.alarmkit.short-stop-consent.v1"
  private var completed = false
  func removeRemainingAlarms(requiresConfirmation: Bool = false) throws {
    guard !completed else { return }
    #if os(iOS)
    if #unavailable(iOS 26.0) {
      // This OS cannot own AlarmKit alarms. Notification migration is separate.
      finish(); return
    }
    #endif
    #if os(iOS) && canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let manager = AlarmManager.shared
      if manager.authorizationState == .authorized {
        let alarms = try manager.alarms
        for alarm in alarms {
          CueDiagnostics.event("legacy_alarmkit_cancel_attempt", identifier: alarm.id.uuidString)
          do {
            try manager.cancel(id: alarm.id)
            CueDiagnostics.event("legacy_alarmkit_cancel_returned", identifier: alarm.id.uuidString)
          } catch {
            CueDiagnostics.event("legacy_alarmkit_cancel_failed", identifier: alarm.id.uuidString,
              detail: error.localizedDescription)
            throw error
          }
        }
        let remaining = try manager.alarms
        guard remaining.isEmpty else {
          throw AppError.message("Не все старые будильники отменены. Новые сигналы не включены; откройте Luma ещё раз.")
        }
        CueDiagnostics.event("legacy_alarmkit_empty_verified")
        finish(); return
      }
    }
    #endif
    guard !requiresConfirmation && !hasLegacyRecords else {
      throw AppError.message("Нужно отменить старые будильники AlarmKit. Разрешите Luma доступ к будильникам в настройках iPhone и откройте приложение снова. Новая очередь пока не включена.")
    }
    finish()
  }
  private var hasLegacyRecords: Bool {
    if UserDefaults.standard.bool(forKey: oldConsentKey) { return true }
    return keys.contains { key in
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
    UserDefaults.standard.removeObject(forKey: oldConsentKey)
    completed = true
  }
}
