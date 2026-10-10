import XCTest
import Dispatch
@testable import LumaCore

final class CuePlaybackStopperTests: XCTestCase {
  /// Simulates a player that keeps producing sound and never sends completion.
  private final class Player: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var sounding = true
    private var timestamp: UInt64?
    func stop() {
      lock.lock(); calls += 1; sounding = false
      timestamp = DispatchTime.now().uptimeNanoseconds
      lock.unlock()
    }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var playing: Bool { lock.lock(); defer { lock.unlock() }; return sounding }
    var stoppedAt: UInt64? { lock.lock(); defer { lock.unlock() }; return timestamp }
  }

  func testStopsCueWhenPlayerCompletionNeverArrives() throws {
    let player = Player(), stopped = expectation(description: "Forced stop without delegate callback")
    let deadline = try CuePlaybackStopper(duration: 0.03) { player.stop(); stopped.fulfill() }
    wait(for: [stopped], timeout: 2)
    XCTAssertFalse(player.playing)
    XCTAssertEqual(player.stops, 1)
    withExtendedLifetime(deadline) { }
  }

  func testCancelledOldDeadlineCannotStopReplacement() throws {
    let first = Player(), replacement = Player()
    let oldStopped = expectation(description: "Cancelled old cue must not expire")
    oldStopped.isInverted = true
    let old = try CuePlaybackStopper(duration: 0.03) { first.stop(); oldStopped.fulfill() }
    old.cancel()
    let newStopped = expectation(description: "Replacement stops at its own deadline")
    let next = try CuePlaybackStopper(duration: 0.15) { replacement.stop(); newStopped.fulfill() }
    wait(for: [oldStopped, newStopped], timeout: 0.8)
    XCTAssertEqual(first.stops, 0)
    XCTAssertEqual(replacement.stops, 1)
    withExtendedLifetime((old, next)) { }
  }

  func testScheduledStartDoesNotUsePreparationTimeAsPlaybackTime() throws {
    let player = Player()
    let stopped = expectation(description: "Delayed cue expires")
    let began = DispatchTime.now().uptimeNanoseconds
    let deadline = try CuePlaybackStopper(duration: 0.03, startDelay: 0.6) {
      player.stop(); stopped.fulfill()
    }
    XCTAssertTrue(player.playing)
    wait(for: [stopped], timeout: 2)
    XCTAssertEqual(player.stops, 1)
    let elapsed = Double(try XCTUnwrap(player.stoppedAt) - began) / 1_000_000_000
    XCTAssertGreaterThanOrEqual(elapsed, 0.6 + 0.03)
    withExtendedLifetime(deadline) { }
  }

  func testCancelAfterExpiryCannotInvokeStopAgain() throws {
    let player = Player(), stopped = expectation(description: "One stop")
    stopped.assertForOverFulfill = true
    let deadline = try CuePlaybackStopper(duration: 0.02) { player.stop(); stopped.fulfill() }
    wait(for: [stopped], timeout: 2)
    deadline.cancel(); deadline.cancel()
    XCTAssertEqual(player.stops, 1)
  }

  func testRejectsUnboundedOrInvalidCueTiming() {
    for duration in [0, -1, 28.01, Double.infinity, Double.nan] {
      XCTAssertThrowsError(try CuePlaybackStopper(duration: duration) { })
    }
    for delay in [-0.1, 10.01, Double.infinity, Double.nan] {
      XCTAssertThrowsError(try CuePlaybackStopper(duration: 1, startDelay: delay) { })
    }
  }

  func testDeadlineStillStopsAudioWhileCallingThreadIsBlocked() throws {
    let player = Player(), signal = DispatchSemaphore(value: 0)
    let deadline = try CuePlaybackStopper(duration: 0.02) { player.stop(); signal.signal() }
    XCTAssertEqual(signal.wait(timeout: .now() + 2), .success)
    XCTAssertFalse(player.playing)
    XCTAssertEqual(player.stops, 1)
    withExtendedLifetime(deadline) { }
  }

  func testRepeatedCuesStopWhenEveryFifthCompletionIsMissing() throws {
    let expired = expectation(description: "Only four missing completions need forced stops")
    expired.expectedFulfillmentCount = 4
    expired.assertForOverFulfill = true
    var players: [Player] = [], deadlines: [CuePlaybackStopper] = []
    for index in 1...20 {
      let player = Player()
      let deadline = try CuePlaybackStopper(duration: 0.03) { player.stop(); expired.fulfill() }
      players.append(player); deadlines.append(deadline)
      if index % 5 != 0 { player.stop(); deadline.cancel() }
    }
    wait(for: [expired], timeout: 2)
    XCTAssertTrue(players.allSatisfy { !$0.playing && $0.stops == 1 })
    withExtendedLifetime(deadlines) { }
  }
}
