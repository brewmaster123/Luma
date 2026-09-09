import Foundation
#if canImport(AlarmKit)
import AlarmKit
import SwiftUI
#endif

@MainActor
final class PhoneAlarmService {
  struct Result { var scheduled: Set<UUID> = []; var warning: String? }
  private let cacheKey = "luma.system-alarm.configurations.v1"
  var supported: Bool {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) { return true }
    #endif
    return false
  }
  var authorizationDescription: String {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      switch AlarmManager.shared.authorizationState {
      case .authorized: return "Системные будильники разрешены"
      case .denied: return "Разрешите будильники: Настройки iPhone → Luma"
      case .notDetermined: return "Нужно разрешение на системные будильники"
      @unknown default: return "Проверьте разрешение на будильники"
      }
    }
    #endif
    return "Системные будильники доступны с iOS 26"
  }
  func requestPermission() async throws {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let manager = AlarmManager.shared
      let state = manager.authorizationState == .notDetermined
        ? try await manager.requestAuthorization() : manager.authorizationState
      guard state == .authorized else { throw AppError.message("Разрешите системные будильники: Настройки iPhone → Luma.") }
      return
    }
    #endif
    throw AppError.message("Для системного будильника в беззвучном режиме нужна iOS 26 или новее.")
  }
  func rebuild(_ alarms: [LumaAlarm], soundName: (SignalSettings) throws -> String) async -> Result {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) { return await rebuildSystem(alarms, soundName: soundName) }
    #endif
    return Result(warning: alarms.contains { $0.enabled && $0.signal.output.phoneEnabled && $0.delivery == .systemAlarm }
      ? "Для системных будильников нужна iOS 26 или новее." : nil)
  }
  #if canImport(AlarmKit)
  @available(iOS 26.0, *)
  private func rebuildSystem(_ alarms: [LumaAlarm], soundName: (SignalSettings) throws -> String) async -> Result {
    let manager = AlarmManager.shared
    var result = Result()
    do {
      let existing = try manager.alarms
      let wanted = alarms.filter { $0.enabled && $0.signal.output.phoneEnabled && $0.delivery == .systemAlarm }
      let wantedIDs = Set(wanted.map(\.id)), existingIDs = Set(existing.map(\.id))
      var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
      for old in existing where !wantedIDs.contains(old.id) {
        try manager.cancel(id: old.id); cache.removeValue(forKey: old.id.uuidString)
      }
      for alarm in AlarmPlanner.sorted(wanted, after: Date()) {
        // A dismissed one-shot must not be recreated on the following launch.
        if alarm.weekdays.isEmpty && alarm.onceAt <= Date() {
          if existingIDs.contains(alarm.id) { result.scheduled.insert(alarm.id) }; continue
        }
        do {
          guard manager.authorizationState == .authorized else { throw AppError.message("Разрешите системные будильники в настройках iPhone.") }
          let sound = try soundName(alarm.signal)
          let fingerprint = [alarm.title, String(alarm.hour), String(alarm.minute),
            alarm.weekdays.sorted().map(String.init).joined(separator: ","),
            alarm.weekdays.isEmpty ? String(alarm.onceAt.timeIntervalSince1970) : "weekly", sound]
            .map { Data($0.utf8).base64EncodedString() }.joined(separator: ":")
          if existingIDs.contains(alarm.id), cache[alarm.id.uuidString] == fingerprint {
            result.scheduled.insert(alarm.id); continue
          }
          if existingIDs.contains(alarm.id) { try manager.cancel(id: alarm.id) }
          cache.removeValue(forKey: alarm.id.uuidString)
          let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: alarm.title),
            stopButton: AlarmButton(text: "Остановить", textColor: .white, systemImageName: "stop.fill"))
          let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert),
            metadata: LumaAlarmMetadata(), tintColor: Color(red: 0.8, green: 0.74, blue: 0.97))
          let schedule: Alarm.Schedule
          if alarm.weekdays.isEmpty { schedule = .fixed(alarm.onceAt) }
          else {
            let weekdays: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
            let selected = alarm.weekdays.sorted().filter { (1...7).contains($0) }.map { weekdays[$0 - 1] }
            guard !selected.isEmpty else { throw AppError.message("Выберите дни повтора будильника.") }
            schedule = .relative(.init(time: .init(hour: alarm.hour, minute: alarm.minute), repeats: .weekly(selected)))
          }
          let configuration = AlarmManager.AlarmConfiguration<LumaAlarmMetadata>.alarm(
            schedule: schedule, attributes: attributes, sound: .named(sound))
          _ = try await manager.schedule(id: alarm.id, configuration: configuration)
          cache[alarm.id.uuidString] = fingerprint; result.scheduled.insert(alarm.id)
        } catch { result.warning = "Не удалось установить «\(alarm.title)»: \(error.localizedDescription)" }
      }
      cache = cache.filter { entry in UUID(uuidString: entry.key).map { wantedIDs.contains($0) } ?? false }
      UserDefaults.standard.set(cache, forKey: cacheKey)
    } catch { result.warning = error.localizedDescription }
    return result
  }
  #endif
}
#if canImport(AlarmKit)
@available(iOS 26.0, *)
private struct LumaAlarmMetadata: AlarmMetadata {}
#endif
