import Foundation
import HealthKit

/// Registers before the first UI appears, including system background launches.
@MainActor final class ResearchPhoneLink: NSObject, HKWorkoutSessionDelegate {
  var onPacket: ((WirePacket) -> Void)?
  var onStatus: ((String) -> Void)?
  private let store = HKHealthStore()
  private var session: HKWorkoutSession?
  var running: Bool { session?.state == .running }
  override init() {
    super.init()
    store.workoutSessionMirroringStartHandler = { [weak self] mirrored in
      Task { @MainActor in
        guard let self else { return }
        self.session = mirrored
        mirrored.delegate = self
        self.onStatus?("Соединение с ночной сессией часов установлено")
      }
    }
  }
  func authorize() async throws {
    try await store.requestAuthorization(toShare: [HKObjectType.workoutType()],
      read: [HKQuantityType(.heartRate)])
  }
  func send(_ p: WirePacket) {
    guard let session, let bytes = try? JSONEncoder().encode(p) else { return }
    session.sendToRemoteWorkoutSession(data: bytes) { _, _ in }
  }
  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
    didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
    Task { @MainActor [weak self] in
      guard let self, self.session === workoutSession else { return }
      if toState == .ended || toState == .stopped {
        self.session = nil
        self.onStatus?("Системная сессия часов завершена")
      }
    }
  }
  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
    Task { @MainActor [weak self] in
      guard let self, self.session === workoutSession else { return }
      self.session = nil
      self.onStatus?("Связь с сессией прервана: \(error.localizedDescription)")
    }
  }
  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
    didReceiveDataFromRemoteWorkoutSession data: [Data]) {
    for bytes in data where bytes.count < 256_000 {
      guard let p = try? JSONDecoder().decode(WirePacket.self, from: bytes), p.version == 2 else { continue }
      Task { @MainActor [weak self] in
        guard let self, self.session === workoutSession else { return }
        self.onPacket?(p)
      }
    }
  }
}
