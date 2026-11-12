import Foundation
import AVFoundation
import CryptoKit

enum AlarmKitSoundBuilder {
  static let sampleRate: Double = 22050
  static let frameCount: AVAudioFramePosition = 88200
  /// Cache a separate, faded PCM copy. Never modify a voice or diary original,
  /// and never substitute the default system sound on a conversion error.
  static func prepare(source: URL, directory override: URL? = nil) throws -> String {
    if override == nil, let bundled = Bundle.main.url(forResource: "luma-tone-4", withExtension: "wav"),
      source.standardizedFileURL == bundled.standardizedFileURL {
      guard let alarm = Bundle.main.url(forResource: "luma-alarm-4", withExtension: "wav"),
        valid(alarm) else { throw AppError.message("Р’ СЃР±РѕСЂРєРµ РЅРµ РЅР°Р№РґРµРЅ С‡РµС‚С‹СЂС‘С…СЃРµРєСѓРЅРґРЅС‹Р№ WAV РґР»СЏ AlarmKit.") }
      return alarm.lastPathComponent
    }
    let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard source.isFileURL, size <= 100 * 1024 * 1024 else {
      throw AppError.message("Р’С‹Р±РµСЂРёС‚Рµ Р°СѓРґРёРѕС„Р°Р№Р» СЂР°Р·РјРµСЂРѕРј РґРѕ 100 РњР‘.")
    }
    let data = try Data(contentsOf: source)
    var hasher = SHA256()
    hasher.update(data: Data("luma-alarmkit-wave-4s-fade-v4".utf8)); hasher.update(data: data)
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let name = "luma-ak4-\(digest).wav"
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
    let faded = folder.appendingPathComponent("luma-render-\(UUID()).wav")
    defer {
      try? FileManager.default.removeItem(at: temporary)
      try? FileManager.default.removeItem(at: faded)
    }
    try renderFade(from: temporary, to: faded)
    guard valid(faded) else { throw AppError.message("РќРµ СѓРґР°Р»РѕСЃСЊ РїРѕРґРіРѕС‚РѕРІРёС‚СЊ С‡РµС‚С‹СЂС‘С…СЃРµРєСѓРЅРґРЅС‹Р№ Р·РІСѓРє.") }
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    try FileManager.default.moveItem(at: faded, to: target)
    #if os(iOS)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
    #endif
    return name
  }
  static func valid(_ url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "wav",
      let data = try? Data(contentsOf: url),
      let facts = WaveCueInspector.inspect(data), facts.isFourSecondCue else { return false }
    guard let f = try? AVAudioFile(forReading: url) else { return false }
    let format = f.fileFormat.streamDescription.pointee
    return f.fileFormat.channelCount == 1 && f.fileFormat.sampleRate == sampleRate
      && f.length == frameCount && format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 16
  }
  static func soundURL(for name: String) throws -> URL {
    guard FiniteCuePolicy.validSoundName(name) else {
      throw AppError.message("РќРµРґРѕРїСѓСЃС‚РёРјРѕРµ РёРјСЏ РєРѕСЂРѕС‚РєРѕРіРѕ Р·РІСѓРєР° AlarmKit.")
    }
    if name == "luma-alarm-4.wav" {
      guard let url = Bundle.main.url(forResource: "luma-alarm-4", withExtension: "wav") else {
        throw AppError.message("Р‘Р°Р·РѕРІС‹Р№ WAV РґР»СЏ AlarmKit РЅРµ РїРѕРїР°Р» РІ СЃР±РѕСЂРєСѓ.")
      }
      return url
    }
    return try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false).appendingPathComponent("Sounds").appendingPathComponent(name)
  }
  private static func renderFade(from source: URL, to target: URL) throws {
    let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard input.length == frameCount, input.processingFormat.sampleRate == sampleRate,
      input.processingFormat.channelCount == 1, !input.processingFormat.isInterleaved,
      input.processingFormat.commonFormat == .pcmFormatFloat32 else {
      NSLog("Luma finite cue input: %@", "frames=\(input.length), file=\(input.fileFormat), processing=\(input.processingFormat)")
      throw AppError.message("РќРµ СѓРґР°Р»РѕСЃСЊ РїСЂРѕС‡РёС‚Р°С‚СЊ С‡РµС‚С‹СЂС‘С…СЃРµРєСѓРЅРґРЅС‹Р№ Р·РІСѓРє. РџРѕРїСЂРѕР±СѓР№С‚Рµ РґСЂСѓРіРѕР№ С„Р°Р№Р».")
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)),
      let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096),
      let samples = buffer.floatChannelData?[0], let chunkSamples = chunk.floatChannelData?[0] else {
      NSLog("Luma finite cue buffer allocation failed: %@", String(describing: input.processingFormat))
      throw AppError.message("РќРµ СѓРґР°Р»РѕСЃСЊ РѕР±СЂР°Р±РѕС‚Р°С‚СЊ РєРѕСЂРѕС‚РєРёР№ Р·РІСѓРє. РџРѕРІС‚РѕСЂРёС‚Рµ РїРѕРїС‹С‚РєСѓ.")
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
        throw AppError.message("Р¤Р°Р№Р» РєРѕСЂРѕС‚РєРѕРіРѕ Р·РІСѓРєР° РїСЂРѕС‡РёС‚Р°РЅ РЅРµ РїРѕР»РЅРѕСЃС‚СЊСЋ. РџРѕРїСЂРѕР±СѓР№С‚Рµ РґСЂСѓРіРѕР№ С„Р°Р№Р».")
      }
      samples.advanced(by: position).update(from: chunkSamples, count: count)
      position += count
    }
    buffer.frameLength = AVAudioFrameCount(position)
    guard (0..<position).allSatisfy({ samples[$0].isFinite }) else {
      throw AppError.message("Р’ РєРѕСЂРѕС‚РєРѕРј Р·РІСѓРєРµ РѕР±РЅР°СЂСѓР¶РµРЅС‹ РЅРµРґРѕРїСѓСЃС‚РёРјС‹Рµ РѕС‚СЃС‡С‘С‚С‹.")
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
