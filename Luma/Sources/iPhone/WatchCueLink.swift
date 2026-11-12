import Foundation
import Combine
import WatchConnectivity

@MainActor final class WatchCueLink: NSObject, ObservableObject, WCSessionDelegate {
  @Published private(set) var summary = "Часы: подключение…"
  private var latest: WatchCuePlan?
  private var confirmedRevision: UInt64?
  private let defaults = UserDefaults.standard
  private let revisionKey = "luma.watch.plan-revision.v1"
  private let savedKey = "luma.watch.outgoing-plan.v1"
  override init() {
    super.init()
    if let data = defaults.data(forKey: savedKey) {
      latest = try? JSONDecoder().decode(WatchCuePlan.self, from: data)
    }
    guard WCSession.isSupported() else { summary = "Apple Watch недоступны"; return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }
  func publish(_ records: [SystemAlarmRecord]) {
    let cues = records.filter { !$0.pending && $0.fireAt > Date().addingTimeInterval(1) }
      .sorted { $0.fireAt < $1.fireAt }
      .map { WatchCue(id: $0.id, fireAt: $0.fireAt, title: $0.title) }
    // Reconnection resends the latest full plan without inventing another revision.
    if let latest, latest.cues == cues { send(); return }
    let stored = UInt64(defaults.string(forKey: revisionKey) ?? "") ?? 0
    guard max(stored, latest?.revision ?? 0) < UInt64.max else {
      summary = "Часы: счётчик расписания повреждён"; return
    }
    let revision = max(stored, latest?.revision ?? 0) + 1
    let plan = WatchCuePlan(revision: revision, cues: cues)
    guard let data = try? JSONEncoder().encode(plan) else { return }
    defaults.set(String(revision), forKey: revisionKey)
    defaults.set(data, forKey: savedKey)
    latest = plan; confirmedRevision = nil
    send()
  }
  func send() {
    guard let plan = latest, WCSession.default.activationState == .activated else { return }
    let session = WCSession.default
    guard session.isPaired, session.isWatchAppInstalled else {
      summary = "Установите и откройте Luma на Apple Watch"; return
    }
    guard let data = try? JSONEncoder().encode(plan) else { return }
    do {
      try session.updateApplicationContext(["lumaCuePlan": data])
      if confirmedRevision != plan.revision {
        summary = "Часы: ожидаем подтверждение \(plan.cues.count) сигналов"
      }
      if session.isReachable {
        session.sendMessage(["lumaCuePlan": data], replyHandler: { [weak self] reply in
          let revision = reply["revision"] as? String
          let count = reply["count"] as? Int
          let error = reply["error"] as? String
          Task { @MainActor in self?.acceptAck(revision, count: count, error: error) }
        }, errorHandler: { _ in /* The full context remains queued for delivery. */ })
      }
    } catch { summary = "Часы: \(error.localizedDescription)" }
  }
  private func acceptAck(_ revision: String?, count: Int?, error: String?) {
    guard let revision, let value = UInt64(revision), value == latest?.revision else { return }
    if let error { summary = "Часы: \(error)"; return }
    confirmedRevision = value
    summary = "На часах подтверждено: \(count ?? 0) сигналов"
  }
  nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    Task { @MainActor [weak self] in self?.send() }
  }
  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
  nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor [weak self] in self?.send() }
  }
  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
    let revision = message["revision"] as? String, count = message["count"] as? Int
    let error = message["error"] as? String
    Task { @MainActor [weak self] in
      if message["requestPlan"] as? Bool == true { self?.send() }
      else { self?.acceptAck(revision, count: count, error: error) }
      replyHandler(["received": true])
    }
  }
}
