import Foundation
import Dispatch

/// Independent, monotonic deadline for a short cue. It does not depend on a
/// player's completion callback, UI timers, the current date, or a visible screen.
public final class CuePlaybackStopper: @unchecked Sendable {
  public enum Failure: Error { case invalidTiming }
  public static let maximumDuration: TimeInterval = 28
  public static let finishAllowance: TimeInterval = 0.25

  private let lock = NSLock()
  private var timer: DispatchSourceTimer?
  private var action: (@Sendable () -> Void)?

  public init(duration: TimeInterval, startDelay: TimeInterval = 0,
              onExpire: @escaping @Sendable () -> Void) throws {
    guard duration.isFinite, duration > 0, duration <= Self.maximumDuration,
      startDelay.isFinite, (0...10).contains(startDelay) else { throw Failure.invalidTiming }
    action = onExpire
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
    self.timer = timer
    timer.setEventHandler { [weak self] in self?.expire() }
    timer.schedule(deadline: .now() + startDelay + duration + Self.finishAllowance,
                   leeway: .milliseconds(20))
    timer.resume()
  }

  /// Normal finish, manual stop, interruption, and replacing a player all cancel
  /// the old deadline. A racing callback may only stop its captured old player.
  public func cancel() {
    lock.lock()
    let timer = self.timer
    self.timer = nil; action = nil
    lock.unlock()
    timer?.cancel()
  }

  private func expire() {
    lock.lock()
    let stop = action, timer = self.timer
    action = nil; self.timer = nil
    lock.unlock()
    timer?.cancel()
    stop?()
  }

  deinit { cancel() }
}
