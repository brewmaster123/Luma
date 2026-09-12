import Foundation
import UserNotifications

@MainActor final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  struct Sound { let name: String; let duration: TimeInterval }
  var onForeground: ((String) -> Void)?
  override init() {
    super.init()
    center.delegate = self
  }
  func requestPermission() async throws {
    guard try await center.requestAuthorization(options: [.alert, .sound]) else {
      throw AppError.message("Разрешите уведомления Luma в настройках устройства.")
    }
  }
  struct Access {
    let needsRequest: Bool
    let canSignal: Bool
    let summary: String
  }
  func access() async -> Access {
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined:
      return Access(needsRequest: true, canSignal: false, summary: "Ещё не запрашивались")
    case .denied:
      return Access(needsRequest: false, canSignal: false, summary: "Выключены в настройках")
    case .authorized:
      return Access(needsRequest: false, canSignal: settings.soundSetting == .enabled,
        summary: settings.soundSetting == .enabled ? "Уведомления разрешены" : "Разрешены, звук выключен")
    case .provisional, .ephemeral:
      return Access(needsRequest: false, canSignal: false, summary: "Нужен полный доступ к уведомлениям")
    @unknown default:
      return Access(needsRequest: false, canSignal: false, summary: "Проверьте настройки уведомлений")
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
    #if os(watchOS)
      let items = all.filter { $0.signal.output.watchEnabled }
    #else
      let items = all.filter { $0.signal.output.phoneEnabled }
    #endif
    let previous = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("luma.alarm.") }
    let previousIDs = Set(previous.map(\.identifier))
    guard !items.isEmpty else { remove(ids: Array(previousIDs)); return [] }
    var budget = 48
    var ids = Set<UUID>()
    var keep = Set<String>()
    do {
      try await checkPermission()
      for a in items {
        #if os(watchOS)
          let count = a.signal.count.rawValue
          let name = ""
        #else
          let count = 1
          let name = try soundName(a.signal)
        #endif
        // Keep an imminent pending request when returning from Settings; do not
        // cancel and recreate the whole queue in the second before it fires.
        let remaining = (0..<count).map { index in
          (id: a.id + ".\(index)", date: a.date.addingTimeInterval(Double(index * a.signal.gapSeconds)))
        }.filter { $0.date > Date() || previousIDs.contains($0.id) }
        guard !remaining.isEmpty else { continue }
        guard budget >= remaining.count else { break }
        for item in remaining {
          if item.date.timeIntervalSinceNow >= 1 {
            try await add(id: item.id, title: a.title, at: item.date, sound: name)
            keep.insert(item.id)
          } else if previousIDs.contains(item.id) { keep.insert(item.id) }
        }
        if remaining.contains(where: { keep.contains($0.id) }) { ids.insert(a.alarmID) }
        budget -= remaining.count
      }
    } catch {
      await cancelPrefix("luma.alarm.")
      throw error
    }
    remove(ids: Array(previousIDs.subtracting(keep)))
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
  func phoneCue(id: String, title: String = "Подсказка Luma", sound: String) async throws {
    try await checkPermission()
    let pending = await center.pendingNotificationRequests()
    guard pending.count < 60 else { throw AppError.message("Очередь сигналов iPhone заполнена.") }
    try await add(id: id, title: title, at: Date().addingTimeInterval(2), sound: sound)
  }
  private func add(id: String, title: String, at: Date, sound: String) async throws {
    let delay = at.timeIntervalSinceNow
    guard delay >= 1 else { throw AppError.message("Время сигнала прошло. Выберите новое время.") }
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = "Можно продолжать спать. Подсказка затихнет сама."
    #if os(watchOS)
      // watchOS does not support named notification sounds. The system default
      // notification sound/haptic keeps Watch alerts finite and buildable.
      c.sound = .default
    #else
      c.sound =
        sound.isEmpty
        ? .default : UNNotificationSound(named: UNNotificationSoundName(rawValue: sound))
    #endif
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
      self?.onForeground?(id)
      completion([.banner, .sound])
    }
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completion: @escaping () -> Void
  ) { completion() }
}
