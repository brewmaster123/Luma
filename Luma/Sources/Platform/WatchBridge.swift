import Foundation
import WatchConnectivity

@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    var onPacket: ((SyncPacket) -> Void)?
    var onStatus: ((Bool, Bool) -> Void)?
    var onPreview: ((Int) -> String?)?
    private var queued: [SyncPacket] = []
    private let session: WCSession?

    override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func send(_ packet: SyncPacket) {
        guard let session else { onStatus?(false, false); return }
        guard session.activationState == .activated else { queued.append(packet); return }
        guard let data = try? JSONEncoder().encode(packet) else { return }
        // Latest state recovers on reconnect; durable transfer recovers command acknowledgements.
        try? session.updateApplicationContext(["lumaPacket": data])
        session.transferUserInfo(["lumaPacket": data])
        if session.isReachable { session.sendMessageData(data, replyHandler: nil, errorHandler: nil) }
    }

    func preview(count: Int) async throws {
        guard let session, session.activationState == .activated, session.isReachable else {
            throw AppError.message("Откройте Luma на Apple Watch и оставьте экран включённым для пробы.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.sendMessage(["lumaPreview": count], replyHandler: { reply in
                if let error = reply["error"] as? String { continuation.resume(throwing: AppError.message(error)) }
                else { continuation.resume() }
            }, errorHandler: { continuation.resume(throwing: $0) })
        }
    }

    private func decode(_ data: Data) {
        guard data.count < 256_000, let packet = try? JSONDecoder().decode(SyncPacket.self, from: data),
              packet.protocolVersion == 1, packet.sentAt <= Date().addingTimeInterval(300) else { return }
        onPacket?(packet)
    }
    private func publishStatus() {
        guard let session else { onStatus?(false, false); return }
        #if os(iOS)
        onStatus?(session.isPaired && session.isWatchAppInstalled, session.isReachable)
        #else
        onStatus?(session.isCompanionAppInstalled, session.isReachable)
        #endif
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.publishStatus()
            if activationState == .activated {
                let pending = self.queued; self.queued.removeAll()
                pending.forEach(self.send)
                if let data = session.receivedApplicationContext["lumaPacket"] as? Data { self.decode(data) }
            }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.publishStatus() }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["lumaPacket"] as? Data else { return }
        Task { @MainActor [weak self] in self?.decode(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["lumaPacket"] as? Data else { return }
        Task { @MainActor [weak self] in self?.decode(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor [weak self] in self?.decode(messageData) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let count = message["lumaPreview"] as? Int, CueCount(rawValue: count) != nil else {
            replyHandler(["error": "Неизвестная команда."]); return
        }
        Task { @MainActor [weak self] in
            guard let preview = self?.onPreview else { replyHandler(["error": "Проба доступна только на часах."]); return }
            if let error = preview(count) { replyHandler(["error": error]) }
            else { replyHandler(["ok": true]) }
        }
    }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.publishStatus() }
    }
    #endif
}
