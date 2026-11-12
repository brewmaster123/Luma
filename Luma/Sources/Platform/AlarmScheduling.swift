import Foundation

struct AlarmAccess {
  var supported: Bool
  var authorized: Bool
  var ready: Bool { supported && authorized }
}

@MainActor protocol ShortAlarmScheduling {
  var supported: Bool { get }
  func requestAuthorization() async throws
  func access() async -> AlarmAccess
  func pending() async throws -> [FiniteCueSnapshot]
  func delivered() async -> [FiniteCueSnapshot]
  func add(_ record: SystemAlarmRecord) async throws
  func cancel(_ identifiers: [String], includingDelivered: Bool) async throws
  func stop(_ identifier: String) async throws
  func setUpdateHandler(_ handler: (@MainActor () -> Void)?)
}

extension ShortAlarmScheduling {
  var supported: Bool { true }
  func delivered() async -> [FiniteCueSnapshot] { [] }
  func stop(_ identifier: String) async throws {
    try await cancel([identifier], includingDelivered: true)
  }
  func setUpdateHandler(_ handler: (@MainActor () -> Void)?) {}
}
