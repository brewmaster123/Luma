import Foundation
import OSLog

enum CueDiagnostics {
  private static let lock = NSLock()
  private static let logger = Logger(subsystem: "com.sevchlenko.luma", category: "alarmkit-short-sound")
  static var logURL: URL? { try? directory().appendingPathComponent("alarmkit-wave-events.jsonl") }
  static func directory() throws -> URL {
    // Keep the legacy ledger location so upgrades can actually find schema 1.
    let folder = try FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LumaAlarmKit")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #if os(iOS)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
    #endif
    return folder
  }
  static func event(_ name: String, record: SystemAlarmRecord? = nil,
    identifier: String? = nil, detail: String? = nil) {
    logger.info("\(name, privacy: .public)")
    lock.lock(); defer { lock.unlock() }
    guard let file = logURL else { return }
    var item: [String: Any] = ["event": name, "at": Date().timeIntervalSince1970,
      "delivery": "alarmkit-four-second-wav", "acoustic_measurement": false]
    if let record {
      item["id"] = record.id.uuidString; item["kind"] = record.kind.rawValue
      item["scheduled_at"] = record.fireAt.timeIntervalSince1970
      item["sound_seconds"] = SystemAlarmPolicy.soundSeconds
    }
    if let identifier { item["system_identifier"] = identifier }
    if let detail { item["detail"] = String(detail.prefix(300)) }
    guard var data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else { return }
    data.append(10)
    do {
      if let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber,
        size.intValue > 2 * 1024 * 1024 {
        let previous = file.deletingLastPathComponent().appendingPathComponent("alarmkit-wave-events.previous.jsonl")
        if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
        try FileManager.default.moveItem(at: file, to: previous)
      }
      if FileManager.default.fileExists(atPath: file.path) {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
      } else { try data.write(to: file, options: .atomic) }
      #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
      #endif
    } catch { /* A diagnostic failure must never block scheduling or cancellation. */ }
  }
}
