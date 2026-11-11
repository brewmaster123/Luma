import Foundation
import AVFoundation
import CryptoKit

enum FiniteCueSoundBuilder {
  static let sampleRate: Double = 22050
  static let frameCount: AVAudioFramePosition = 88200
  /// Cache a separate, faded PCM copy. Never modify a voice or diary original,
  /// and never substitute the default notification sound on a conversion error.
  static func prepare(source: URL, directory override: URL? = nil) throws -> String {
    if override == nil, let bundled = Bundle.main.url(forResource: "luma-tone-4", withExtension: "wav"),
      source.standardizedFileURL == bundled.standardizedFileURL {
      guard valid(bundled) else { throw AppError.message("Повреждён базовый звук Luma.") }
      return bundled.lastPathComponent
    }
    let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard source.isFileURL, size <= 100 * 1024 * 1024 else {
      throw AppError.message("Выберите аудиофайл размером до 100 МБ.")
    }
    let data = try Data(contentsOf: source)
    var hasher = SHA256()
    hasher.update(data: Data("luma-finite-pcm-4s-fade-v2".utf8)); hasher.update(data: data)
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let name = "luma-cue4-\(digest).caf"
    let folder: URL
    if let override { folder = override }
    else {
      folder = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true).appendingPathComponent("Sounds")
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #if os(iOS)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
    #endif
    let target = folder.appendingPathComponent(name)
    if valid(target) { return name }
    let clip = try CueAudioImporter.convert(source: source, directory: folder,
      maximumDuration: SystemAlarmPolicy.soundSeconds, padToMaximum: true)
    let temporary = folder.appendingPathComponent(clip.filename)
    let faded = folder.appendingPathComponent("luma-render-\(UUID()).caf")
    defer {
      try? FileManager.default.removeItem(at: temporary)
      try? FileManager.default.removeItem(at: faded)
    }
    try renderFade(from: temporary, to: faded)
    guard valid(faded) else { throw AppError.message("Не удалось подготовить четырёхсекундный звук.") }
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    try FileManager.default.moveItem(at: faded, to: target)
    #if os(iOS)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
    #endif
    return name
  }
  static func valid(_ url: URL) -> Bool {
    guard let f = try? AVAudioFile(forReading: url) else { return false }
    let format = f.fileFormat.streamDescription.pointee
    return f.fileFormat.channelCount == 1 && f.fileFormat.sampleRate == sampleRate
      && f.length == frameCount && format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 16
  }
  private static func renderFade(from source: URL, to target: URL) throws {
    let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: true)
    guard input.length == frameCount,
      let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(frameCount))
    else { throw AppError.message("Неверная длительность короткого звука.") }
    try input.read(into: buffer)
    guard buffer.frameLength == AVAudioFrameCount(frameCount), let samples = buffer.int16ChannelData?[0] else {
      throw AppError.message("Не удалось обработать короткий звук.")
    }
    // Fade the end of the actual content, before any padding on a short voice.
    var end = Int(buffer.frameLength)
    while end > 0 && samples[end - 1] == 0 { end -= 1 }
    let fade = min(Int(sampleRate * 0.12), end)
    let attack = min(Int(sampleRate * 0.01), end)
    if fade > 1 {
      for i in 0..<fade {
        let gain = 0.5 * (1 + cos(.pi * Double(i) / Double(fade - 1)))
        let index = end - fade + i
        samples[index] = Int16((Double(samples[index]) * gain).rounded())
      }
    }
    if attack > 1 {
      for i in 0..<attack {
        let gain = 0.5 * (1 - cos(.pi * Double(i) / Double(attack - 1)))
        samples[i] = Int16((Double(samples[i]) * gain).rounded())
      }
    }
    let output = try AVAudioFile(forWriting: target, settings: input.processingFormat.settings,
      commonFormat: .pcmFormatInt16, interleaved: true)
    try output.write(from: buffer)
  }
}
