import CoreMotion
import Foundation

@MainActor
final class MotionService {
  private let manager = CMMotionManager()
  private var start: Date?
  private var energy = 0.0
  private var count = 0
  private(set) var epochs: [MotionEpoch] = []
  func startUpdates() {
    guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
    manager.deviceMotionUpdateInterval = 0.1
    manager.startDeviceMotionUpdates(to: .main) { [weak self] value, _ in
      guard let value else { return }
      let a = value.userAcceleration
      let squared = a.x * a.x + a.y * a.y + a.z * a.z
      Task { @MainActor in self?.append(squared: squared, now: Date()) }
    }
  }
  func stopUpdates() {
    manager.stopDeviceMotionUpdates()
    start = nil
    energy = 0
    count = 0
  }
  private func append(squared: Double, now: Date) {
    guard squared.isFinite else { return }
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
