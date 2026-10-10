import Foundation

/// On-device diagnostics only. No server, no cloud backup, no raw microphone audio.
@MainActor final class ResearchLog {
  private var url: URL?
  func start(_ id: UUID) {
    do {
      let base = try FileManager.default.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true)
      var directory = base.appendingPathComponent("REMLab", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var values = URLResourceValues(); values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
      url = directory.appendingPathComponent("\(id.uuidString).jsonl")
      if let url, !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil,
          attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
      }
    } catch { url = nil }
  }
  func append(_ packet: WirePacket) {
    guard let url, var data = try? JSONEncoder().encode(packet),
      let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    data.append(0x0a)
    do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { }
  }
  var fileURL: URL? { url }
}
