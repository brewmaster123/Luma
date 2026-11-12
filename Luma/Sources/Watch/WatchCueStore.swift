import Foundation
import Combine
import WatchConnectivity
import UserNotifications
import WatchKit

@MainActor final class WatchCueStore: NSObject, ObservableObject, WCSessionDelegate {
  static let shared = WatchCueStore()
  @Published private(set) var summary = "Откройте Luma на iPhone"
  @Published private(set) var next: Date?
  private let savedKey = "luma.watch.received-plan.v1"
  private var plan: WatchCuePlan?
  private var applying = false
  private var launchPending = false
  private var contentObserver: NSKeyValueObservation?
  private var backgroundDeadline: Task<Void, Never>?
  private var backgroundTasks: [WKRefreshBackgroundTask] = []
  private var queued: (WatchCuePlan, (([String: Any]) -> Void)?)?
  override init() {
    super.init()
    if let data = UserDefaults.standard.data(forKey: savedKey) {
      plan = try? JSONDecoder().decode(WatchCuePlan.self, from: data)
    }
    WCSession.default.delegate = self; WCSession.default.activate()
    contentObserver = WCSession.default.observe(\.hasContentPending, options: [.new]) { [weak self] _, _ in
      Task { @MainActor in self?.finishBackgroundTasks() }
    }
  }
  func authorizeAndRefresh() async {
    do {
      guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
        summary = "Разрешите уведомления и звуки Luma на часах"; return
      }
      if let plan { await apply(plan, reply: nil) }
      await refreshFromPhone()
    } catch { summary = error.localizedDescription }
  }
  func refreshFromPhone() async {
    if let data = WCSession.default.receivedApplicationContext["lumaCuePlan"] as? Data {
      receive(data, reply: nil)
    }
    if WCSession.default.activationState == .activated, WCSession.default.isReachable {
      WCSession.default.sendMessage(["requestPlan": true], replyHandler: { _ in }, errorHandler: { _ in })
    }
  }
  private func receive(_ data: Data, reply: (([String: Any]) -> Void)?) {
    guard data.count < 100_000, let incoming = try? JSONDecoder().decode(WatchCuePlan.self, from: data),
      WatchCuePlan.shouldReplace(current: plan, incoming: incoming),
      incoming.validated(after: Date()) != nil else {
      reply?(["error": "Некорректное или устаревшее расписание"]); return
    }
    // Keep just the newest full snapshot while an async notification operation runs.
    if applying || launchPending {
      if queued == nil || incoming.revision >= queued!.0.revision {
        queued?.1?(["error": "Заменено новым расписанием"])
        queued = (incoming, reply)
      } else { reply?(["error": "Есть более новое расписание"]) }
      return
    }
    launchPending = true
    Task { launchPending = false; await apply(incoming, reply: reply) }
  }
  private func apply(_ incoming: WatchCuePlan, reply: (([String: Any]) -> Void)?) async {
    if applying {
      if queued == nil || incoming.revision >= queued!.0.revision {
        queued?.1?(["error": "Заменено новым расписанием"]); queued = (incoming, reply)
      } else { reply?(["error": "Есть более новое расписание"]) }
      return
    }
    applying = true
    defer {
      applying = false
      if let queued { self.queued = nil; receivePlan(queued.0, reply: queued.1) }
      else { finishBackgroundTasks() }
    }
    let center = UNUserNotificationCenter.current()
    var ack: [String: Any] = ["revision": String(incoming.revision)]
    do {
      guard WatchCuePlan.shouldReplace(current: plan, incoming: incoming),
        let desired = incoming.validated(after: Date()) else { throw WatchPlanError.invalid }
      // Persist the newer full plan before awaits, preventing an older in-flight plan from winning.
      plan = incoming
      UserDefaults.standard.set(try JSONEncoder().encode(incoming), forKey: savedKey)
      let pending = await center.pendingNotificationRequests()
      let wanted = Set(desired.map(\.notificationID))
      let obsolete = pending.map(\.identifier).filter { $0.hasPrefix("luma.watch.cue.") && !wanted.contains($0) }
      center.removePendingNotificationRequests(withIdentifiers: obsolete)
      center.removeDeliveredNotifications(withIdentifiers: obsolete)
      let settings = await center.notificationSettings()
      guard (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional),
        settings.soundSetting == .enabled else { throw WatchPlanError.permission }
      let existing = Set(pending.map(\.identifier))
      for cue in desired where !existing.contains(cue.notificationID) {
        // A newer full snapshot already waiting must not admit stale additions.
        if let queued, queued.0.revision > incoming.revision { throw WatchPlanError.superseded }
        let delay = cue.fireAt.timeIntervalSinceNow
        guard delay > 1 else { continue }
        let content = UNMutableNotificationContent()
        content.title = cue.title; content.body = "Короткий сигнал Luma"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("luma-alarm-4.wav"))
        content.threadIdentifier = "luma.watch.cues"
        content.userInfo = ["cueID": cue.id.uuidString]
        let request = UNNotificationRequest(identifier: cue.notificationID, content: content,
          trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
        try await center.add(request)
      }
      let admitted = Set(await center.pendingNotificationRequests().map(\.identifier))
      let future = desired.filter { $0.fireAt.timeIntervalSinceNow > 2 }
      guard Set(future.map(\.notificationID)).isSubset(of: admitted) else { throw WatchPlanError.unconfirmed }
      next = desired.first?.fireAt
      summary = "В очереди на часах: \(future.count)"
      ack["count"] = future.count
    } catch {
      summary = error.localizedDescription; ack["error"] = summary
    }
    reply?(ack)
    if WCSession.default.activationState == .activated, WCSession.default.isReachable {
      WCSession.default.sendMessage(ack, replyHandler: { _ in }, errorHandler: { _ in })
    }
  }
  private func receivePlan(_ incoming: WatchCuePlan, reply: (([String: Any]) -> Void)?) {
    guard let data = try? JSONEncoder().encode(incoming) else { return }
    receive(data, reply: reply)
  }
  func retainBackgroundTasks(_ tasks: Set<WKRefreshBackgroundTask>) {
    for task in tasks {
      if task is WKWatchConnectivityRefreshBackgroundTask { backgroundTasks.append(task) }
      else { task.setTaskCompletedWithSnapshot(false) }
    }
    Task { await refreshFromPhone(); finishBackgroundTasks() }
    backgroundDeadline?.cancel()
    backgroundDeadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
      guard let self else { return }
      if !self.backgroundTasks.isEmpty {
        self.summary = "Передача не завершена; откройте Luma на часах"
        self.finishBackgroundTasks(force: true)
      }
    }
  }
  private func finishBackgroundTasks(force: Bool = false) {
    guard force || (!applying && !launchPending && queued == nil && WCSession.default.activationState == .activated
      && !WCSession.default.hasContentPending) else { return }
    backgroundTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }; backgroundTasks.removeAll()
    backgroundDeadline?.cancel(); backgroundDeadline = nil
  }
  nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    Task { @MainActor [weak self] in await self?.refreshFromPhone() }
  }
  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    guard let data = applicationContext["lumaCuePlan"] as? Data else { return }
    Task { @MainActor [weak self] in self?.receive(data, reply: nil) }
  }
  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
    guard let data = message["lumaCuePlan"] as? Data else { replyHandler(["error": "Нет расписания"]); return }
    Task { @MainActor [weak self] in self?.receive(data, reply: replyHandler) }
  }
}
private enum WatchPlanError: LocalizedError {
  case invalid, permission, superseded, unconfirmed
  var errorDescription: String? {
    switch self {
    case .invalid: return "Некорректное расписание"
    case .permission: return "Разрешите уведомления и звуки Luma на часах"
    case .superseded: return "Получено более новое расписание"
    case .unconfirmed: return "watchOS не подтвердила очередь"
    }
  }
}
