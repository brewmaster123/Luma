import Foundation
import UserNotifications

@MainActor final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  var onForeground: ((String) -> Bool)?
  override init() {
    super.init()
    center.delegate = self
  }
  func requestPermission() async throws {
    guard try await center.requestAuthorization(options: [.alert, .sound]) else {
      throw AppError.message("Разрешите уведомления Luma в настройках устройства.")
    }
  }
  func checkPermission() async throws {
    let s = await center.notificationSettings()
    guard s.authorizationStatus == .authorized, s.soundSetting == .enabled else {
      throw AppError.message("Разрешите уведомления и звуки Luma. Проверьте фокусирование «Сон».")
    }
  }
  func rebuildAlarms(_ all: [AlarmOccurrence], soundName: (SignalSettings) throws -> String)
    async throws -> Set<UUID>
  {
    await cancelPrefix("luma.alarm.")
    #if os(watchOS)
      let items = all.filter { $0.signal.output.watchEnabled }
    #else
      let items = all.filter { $0.signal.output.phoneEnabled }
    #endif
    guard !items.isEmpty else { return [] }
    try await checkPermission()
    var budget = 48
    var ids = Set<UUID>()
    do {
      for a in items {
        #if os(watchOS)
          let count = a.signal.count.rawValue
          let name = ""
        #else
          let count = 1
          let name = try soundName(a.signal)
        #endif
        guard budget >= count else { break }
        for i in 0..<count {
          try await add(
            id: a.id + ".\(i)", title: a.title,
            at: a.date.addingTimeInterval(Double(i * a.signal.gapSeconds)), sound: name)
        }
        ids.insert(a.alarmID)
        budget -= count
      }
    } catch {
      await cancelPrefix("luma.alarm.")
      throw error
    }
    return ids
  }
  func watchBurst(id: String, signal: SignalSettings) async throws {
    try await checkPermission()
    let pending = await center.pendingNotificationRequests()
    guard pending.count + signal.count.rawValue <= 60 else {
      throw AppError.message("Очередь сигналов часов заполнена.")
    }
    do {
      for i in 0..<signal.count.rawValue {
        try await add(
          id: id + ".\(i)", title: "Подсказка Luma",
          at: Date().addingTimeInterval(2 + Double(i * signal.validated().gapSeconds)), sound: "")
      }
    } catch {
      await cancelPrefix(id)
      throw error
    }
  }
  func phoneCue(id: String, sound: String) async throws {
    try await checkPermission()
    try await add(id: id, title: "Подсказка Luma", at: Date().addingTimeInterval(2), sound: sound)
  }
  private func add(id: String, title: String, at: Date, sound: String) async throws {
    let delay = at.timeIntervalSinceNow
    guard delay >= 1 else { throw AppError.message("Время сигнала прошло. Выберите новое время.") }
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = "Можно продолжать спать. Подсказка затихнет сама."
    c.sound =
      sound.isEmpty
      ? .default : UNNotificationSound(named: UNNotificationSoundName(rawValue: sound))
    c.interruptionLevel = .active
    try await center.add(
      UNNotificationRequest(
        identifier: id, content: c,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
  }
  func remove(ids: [String]) {
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }
  func cancelPrefix(_ prefix: String) async {
    let p = await center.pendingNotificationRequests()
    let d = await center.deliveredNotifications()
    remove(
      ids: p.map(\.identifier).filter { $0.hasPrefix(prefix) }
        + d.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) })
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let id = notification.request.identifier
    Task { @MainActor [weak self] in
      completion(self?.onForeground?(id) == true ? [.banner] : [.banner, .sound])
    }
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completion: @escaping () -> Void
  ) { completion() }
}
