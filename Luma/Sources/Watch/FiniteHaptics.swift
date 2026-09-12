import Foundation
import WatchKit

@MainActor
final class FiniteHaptics {
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private(set) var isPlaying = false
  var onProgress: ((Int, Int) -> Void)?
  var onFinished: ((Bool) -> Void)?
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
    onProgress?(0, count)
    task = Task { @MainActor [weak self] in
      var finished = false
      defer {
        if self?.generation == token {
          self?.isPlaying = false
          self?.task = nil
          self?.onFinished?(!finished)
        }
      }
      for index in 0..<count {
        guard !Task.isCancelled, WKExtension.shared().applicationState == .active else { break }
        self?.onProgress?(index + 1, count)
        WKInterfaceDevice.current().play(.notification)
        do { try await Task.sleep(nanoseconds: index < count - 1 ? 1_500_000_000 : 1_000_000_000) }
        catch { break }
      }
      finished = !Task.isCancelled && WKExtension.shared().applicationState == .active
    }
    return nil
  }
  func cancel() {
    let wasPlaying = isPlaying
    generation = UUID()
    task?.cancel()
    task = nil
    isPlaying = false
    if wasPlaying { onFinished?(true) }
  }
}
