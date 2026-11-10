import Foundation
import AVFoundation
import CryptoKit

enum AlarmKitSoundBuilder {
  /// Library/Sounds is a documented AlarmKit custom-sound location. Cache by
  /// actual source bytes; never substitute the unbounded default alarm sound.
  static func prepare(source: URL) throws -> String {
    let data = try Data(contentsOf: source)
    guard data.count <= 100 * 1024 * 1024 else { throw AppError.message("Аудиофайл слишком большой.") }
    var hasher = SHA256(); hasher.update(data: Data("luma-alarmkit-pcm-4s-v1".utf8)); hasher.update(data: data)
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let name = "luma-ak4-\(digest).caf"
    let folder = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).appendingPathComponent("Sounds")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    let target = folder.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: target.path), valid(target) { return name }
    let clip = try CueAudioImporter.convert(source: source, directory: folder,
      maximumDuration: SystemAlarmPolicy.soundSeconds, padToMaximum: true)
    let temporary = folder.appendingPathComponent(clip.filename)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard valid(temporary) else { throw AppError.message("Не удалось подготовить четырёхсекундный звук AlarmKit.") }
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    try FileManager.default.moveItem(at: temporary, to: target)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
    return name
  }
  private static func valid(_ url: URL) -> Bool {
    guard let f = try? AVAudioFile(forReading: url) else { return false }
    return f.processingFormat.channelCount == 1 && f.processingFormat.sampleRate == 22050
      && f.length == 88200
  }
}
