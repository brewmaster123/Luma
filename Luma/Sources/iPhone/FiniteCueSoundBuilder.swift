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
    hasher.update(data: Data("luma-finite-pcm-4s-fade-v3-float-processing".utf8)); hasher.update(data: data)
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
    let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard input.length == frameCount, input.processingFormat.sampleRate == sampleRate,
      input.processingFormat.channelCount == 1, !input.processingFormat.isInterleaved,
      input.processingFormat.commonFormat == .pcmFormatFloat32 else {
      NSLog("Luma finite cue input: %@", "frames=\(input.length), file=\(input.fileFormat), processing=\(input.processingFormat)")
      throw AppError.message("Не удалось прочитать четырёхсекундный звук. Попробуйте другой файл.")
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)),
      let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096),
      let samples = buffer.floatChannelData?[0], let chunkSamples = chunk.floatChannelData?[0] else {
      NSLog("Luma finite cue buffer allocation failed: %@", String(describing: input.processingFormat))
      throw AppError.message("Не удалось обработать короткий звук. Повторите попытку.")
    }
    // A successful read can return fewer frames than requested. Gather all of
    // them before fading, and report an early EOF separately from a format error.
    var position = 0
    while position < Int(frameCount) {
      chunk.frameLength = 0
      let requested = AVAudioFrameCount(min(Int(chunk.frameCapacity), Int(frameCount) - position))
      try input.read(into: chunk, frameCount: requested)
      let count = Int(chunk.frameLength)
      guard count > 0 else {
        NSLog("Luma finite cue early EOF: %@", "read=\(position)/\(frameCount), processing=\(input.processingFormat)")
        throw AppError.message("Файл короткого звука прочитан не полностью. Попробуйте другой файл.")
      }
      samples.advanced(by: position).update(from: chunkSamples, count: count)
      position += count
    }
    buffer.frameLength = AVAudioFrameCount(position)
    guard (0..<position).allSatisfy({ samples[$0].isFinite }) else {
      throw AppError.message("В коротком звуке обнаружены недопустимые отсчёты.")
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
        samples[index] = Float(Double(samples[index]) * gain)
      }
    }
    if attack > 1 {
      for i in 0..<attack {
        let gain = 0.5 * (1 - cos(.pi * Double(i) / Double(attack - 1)))
        samples[i] = Float(Double(samples[i]) * gain)
      }
    }
    let output = try AVAudioFile(forWriting: target, settings: CueAudioImporter.pcm16FileSettings,
      commonFormat: .pcmFormatFloat32, interleaved: false)
    try output.write(from: buffer)
  }
}
