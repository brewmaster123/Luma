import CoreMotion
import Foundation

@MainActor
final class MotionService {
  private let manager = CMMotionManager()
  private var start: Date?
  private var energy = 0.0
  private var count = 0
  private var lastSample: Date?
  private var generation = UUID()
  private(set) var epochs: [MotionEpoch] = []
  func reset() { stopUpdates(); epochs = [] }
  func startUpdates() {
    guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
    let token = UUID(); generation = token
    manager.deviceMotionUpdateInterval = 0.1
    manager.startDeviceMotionUpdates(to: .main) { [weak self] value, _ in
      guard let value else { return }
      let a = value.userAcceleration
      let squared = a.x * a.x + a.y * a.y + a.z * a.z
      let measuredAt = Date(timeIntervalSinceNow: value.timestamp - ProcessInfo.processInfo.systemUptime)
      Task { @MainActor in
        guard let self, self.generation == token,
          (-1...2).contains(Date().timeIntervalSince(measuredAt)) else { return }
        self.append(squared: squared, now: measuredAt)
      }
    }
  }
  func stopUpdates() {
    manager.stopDeviceMotionUpdates()
    generation = UUID(); lastSample = nil
    start = nil
    energy = 0
    count = 0
  }
  private func append(squared: Double, now: Date) {
    guard squared.isFinite else { return }
    if let lastSample {
      guard now > lastSample else { return }
      if now.timeIntervalSince(lastSample) > 2 { start = nil; energy = 0; count = 0 }
    }
    lastSample = now
    if start == nil { start = now }
    energy += squared
    count += 1
    guard let start, now.timeIntervalSince(start) >= 30 else { return }
    epochs.append(
      MotionEpoch(start: start, end: now, rmsG: sqrt(energy / Double(count)), sampleCount: count))
    epochs.removeAll { $0.end < now.addingTimeInterval(-240) }
    self.start = now
    energy = 0
    count = 0
  }
}
