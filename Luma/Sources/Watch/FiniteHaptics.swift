import Foundation
import WatchKit

@MainActor
final class FiniteHaptics {
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private(set) var isPlaying = false
  /// Foreground preview only. All nighttime cues use finite notification requests.
  func preview(count: Int) -> String? {
    guard CueCount(rawValue: count) != nil else { return "Неверное число сигналов." }
    guard WKExtension.shared().applicationState == .active else {
      return "Оставьте Luma открытой на часах для пробы."
    }
    guard !isPlaying else { return "Дождитесь окончания текущей пробы." }
    let token = UUID()
    generation = token
    isPlaying = true
    task = Task { @MainActor [weak self] in
      defer {
        if self?.generation == token {
          self?.isPlaying = false
          self?.task = nil
        }
      }
      for index in 0..<count {
        guard !Task.isCancelled, WKExtension.shared().applicationState == .active else { break }
        WKInterfaceDevice.current().play(.click)
        if index < count - 1 {
          do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { break }
        }
      }
    }
    return nil
  }
  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    isPlaying = false
  }
}
