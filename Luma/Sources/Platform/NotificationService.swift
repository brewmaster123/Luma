import Foundation
import UserNotifications

struct CueNotificationAccess {
  var authorized: Bool
  var sound: Bool
  var alerts: Bool
  var lockScreen: Bool
  var scheduledSummary: Bool
  var ready: Bool { authorized && sound && alerts && lockScreen }
}

@MainActor protocol FiniteNotificationScheduling {
  func requestAuthorization() async throws
  func access() async -> CueNotificationAccess
  func pending() async -> [FiniteCueSnapshot]
  func delivered() async -> [FiniteCueSnapshot]
  func add(_ record: SystemAlarmRecord) async throws
  func cancel(_ identifiers: [String], includingDelivered: Bool) async throws
}

/// iOS plays an ordinary custom notification sound once. It is not a ringtone,
/// a critical alert, an AlarmKit alarm, or a timer that needs Luma to stop it.
@MainActor final class NotificationService: FiniteNotificationScheduling {
  struct Sound { let name: String; let duration: TimeInterval }
  private let center: UNUserNotificationCenter
  init(center: UNUserNotificationCenter = .current()) { self.center = center }
  func requestAuthorization() async throws {
    _ = try await center.requestAuthorization(options: [.alert, .sound])
  }
  func access() async -> CueNotificationAccess {
    let s = await center.notificationSettings()
    return .init(authorized: s.authorizationStatus == .authorized,
      sound: s.soundSetting == .enabled, alerts: s.alertSetting == .enabled,
      lockScreen: s.lockScreenSetting == .enabled,
      scheduledSummary: s.scheduledDeliverySetting == .enabled)
  }
  func pending() async -> [FiniteCueSnapshot] {
    await center.pendingNotificationRequests().map(Self.snapshot)
  }
  func delivered() async -> [FiniteCueSnapshot] {
    await center.deliveredNotifications().map { Self.snapshot($0.request) }
  }
  func add(_ record: SystemAlarmRecord) async throws {
    guard FiniteCuePolicy.validSoundName(record.soundName), record.fireAt.timeIntervalSinceNow > 1 else {
      throw AppError.message("Не удалось подготовить короткий сигнал. Выберите время в будущем.")
    }
    let content = UNMutableNotificationContent()
    content.title = record.title
    content.body = "Короткий сигнал Luma · 4 секунды"
    content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: record.soundName))
    content.interruptionLevel = .active
    content.threadIdentifier = "luma.short-cues"
    content.userInfo = ["luma_key": record.key, "luma_fire_at": record.fireAt.timeIntervalSince1970,
      "luma_sound": record.soundName, "luma_kind": record.kind.rawValue]
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: record.fireAt.timeIntervalSinceNow, repeats: false)
    try await center.add(UNNotificationRequest(identifier: record.notificationID, content: content, trigger: trigger))
  }
  func cancel(_ identifiers: [String], includingDelivered: Bool) async throws {
    guard !identifiers.isEmpty else { return }
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
    if includingDelivered { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    let remaining = Set(await center.pendingNotificationRequests().map(\.identifier))
    guard remaining.isDisjoint(with: identifiers) else {
      throw AppError.message("Система ещё не подтвердила отмену старых сигналов. Откройте Luma ещё раз.")
    }
  }
  private static func snapshot(_ request: UNNotificationRequest) -> FiniteCueSnapshot {
    let info = request.content.userInfo
    return .init(identifier: request.identifier, key: info["luma_key"] as? String ?? "",
      fireAt: Date(timeIntervalSince1970: (info["luma_fire_at"] as? Double) ?? 0),
      title: request.content.title, soundName: info["luma_sound"] as? String ?? "",
      repeats: request.trigger?.repeats ?? false, hasSound: request.content.sound != nil)
  }
}
