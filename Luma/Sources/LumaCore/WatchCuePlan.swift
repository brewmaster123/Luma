import Foundation

public struct WatchCue: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var fireAt: Date
  public var title: String
  public init(id: UUID, fireAt: Date, title: String) {
    self.id = id; self.fireAt = fireAt; self.title = String(title.prefix(80))
  }
  public var notificationID: String { "luma.watch.cue." + id.uuidString }
}
public struct WatchCuePlan: Codable, Equatable, Sendable {
  public var schema = 1
  public var revision: UInt64
  public var createdAt: Date
  public var cues: [WatchCue]
  public init(revision: UInt64, createdAt: Date = Date(), cues: [WatchCue]) {
    self.revision = revision; self.createdAt = createdAt; self.cues = cues
  }
  public func validated(after now: Date) -> [WatchCue]? {
    guard schema == 1, revision > 0, createdAt.timeIntervalSince1970.isFinite,
      createdAt <= now.addingTimeInterval(120), cues.count <= 60,
      Set(cues.map(\.id)).count == cues.count,
      cues.allSatisfy({ $0.fireAt.timeIntervalSince1970.isFinite
        && $0.fireAt <= createdAt.addingTimeInterval(12 * 3600) }) else { return nil }
    return cues.filter { $0.fireAt > now.addingTimeInterval(1) }.sorted { $0.fireAt < $1.fireAt }
  }
  public static func shouldReplace(current: Self?, incoming: Self) -> Bool {
    guard let current else { return true }
    return incoming.revision > current.revision || incoming == current
  }
}
