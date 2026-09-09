import Foundation
import WatchConnectivity

@MainActor final class WatchBridge: NSObject, WCSessionDelegate {
  var onPacket: ((WirePacket) -> Void)?
  var onStatus: ((Bool, Bool) -> Void)?
  private let session: WCSession? = WCSession.isSupported() ? .default : nil
  private var configuration: WirePacket?
  override init() {
    super.init()
    session?.delegate = self
    session?.activate()
  }
  @discardableResult func send(_ p: WirePacket) -> Bool {
    guard let session, let data = try? JSONEncoder().encode(p), data.count < 256_000 else {
      return false
    }
    if p.kind == .configuration { configuration = p }
    guard session.activationState == .activated else { return false }
    if p.kind == .configuration {
      do { try session.updateApplicationContext(["lumaV2": data]) } catch { return false }
      if session.isReachable { session.sendMessageData(data, replyHandler: nil, errorHandler: nil) }
      return true
    }
    if p.kind == .acknowledgement { session.transferUserInfo(["lumaV2": data]) }
    // Never enqueue time-critical cues for delayed delivery.
    guard session.isReachable else { return p.kind == .acknowledgement }
    session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
    return true
  }
  private func decode(_ d: Data) {
    guard d.count < 256_000, let p = try? JSONDecoder().decode(WirePacket.self, from: d),
      p.version == 2, p.sentAt <= Date().addingTimeInterval(30)
    else { return }
    onPacket?(p)
  }
  private func status() {
    guard let session else {
      onStatus?(false, false)
      return
    }
    #if os(iOS)
      onStatus?(session.isPaired && session.isWatchAppInstalled, session.isReachable)
    #else
      onStatus?(session.isCompanionAppInstalled, session.isReachable)
    #endif
  }
  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.status()
      if let d = session.receivedApplicationContext["lumaV2"] as? Data { self.decode(d) }
      if let p = self.configuration { self.send(p) }
    }
  }
  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor [weak self] in self?.status() }
  }
  nonisolated func session(
    _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    guard let d = applicationContext["lumaV2"] as? Data else { return }
    Task { @MainActor [weak self] in self?.decode(d) }
  }
  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    guard let d = userInfo["lumaV2"] as? Data else { return }
    Task { @MainActor [weak self] in self?.decode(d) }
  }
  nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
    Task { @MainActor [weak self] in self?.decode(messageData) }
  }
  #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
      Task { @MainActor [weak self] in self?.status() }
    }
  #endif
}
