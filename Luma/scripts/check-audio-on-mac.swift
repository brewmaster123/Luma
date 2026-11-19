import Foundation
import AVFoundation
import CryptoKit
import Darwin

private struct AudioCheckFailure: Error, CustomStringConvertible {
  let description: String
}

@main
struct AudioImportCheck {
  static func main() {
    do { try run() }
    catch {
      let data = Data("FAIL: audio validation: \(error)\n".utf8)
      try? FileHandle.standardError.write(contentsOf: data)
      exit(EXIT_FAILURE)
    }
  }
  static func require(_ value: Bool, _ message: String) throws {
    if !value { throw AudioCheckFailure(description: message) }
  }
  static func run() throws {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent(".build/audio-validation/\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputs: [(name: String, rate: Double, channels: AVAudioChannelCount, bits: Int)] = [
      ("stereo-float48", 48000, 2, 32), ("mono-pcm22", 22050, 1, 16)
    ]
    var cases = 0
    for input in inputs {
      for seconds in [0.32, 2.0, 4.0, 40.0] {
        let label = "\(input.name)-\(seconds)s"
        print("RUN: \(label)")
        fflush(stdout)
        let source = directory.appendingPathComponent("\(label).wav")
        try writeTone(source, seconds: seconds, sampleRate: input.rate,
          channels: input.channels, bits: input.bits)
        let original = try Data(contentsOf: source)
        let clip = try CueAudioImporter.convert(source: source, directory: directory)
        let output = try AVAudioFile(forReading: directory.appendingPathComponent(clip.filename))
        let duration = Double(output.length) / output.fileFormat.sampleRate
        try require(output.fileFormat.sampleRate == 22050 && output.fileFormat.channelCount == 1, "\(label): output rate/channels")
        try require(output.fileFormat.streamDescription.pointee.mBitsPerChannel == 16, "\(label): disk must be PCM16")
        try require(abs(duration - min(28, seconds)) < 0.05, "\(label): incorrect import duration \(duration)")
        try require(clip.imported == true && abs((clip.sourceDuration ?? 0) - seconds) < 0.05, "\(label): source metadata")
        try require(output.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM, "\(label): disk codec")

        let short = try CueAudioImporter.convert(source: source, directory: directory,
          maximumDuration: 4, padToMaximum: true)
        let shortOutput = try AVAudioFile(forReading: directory.appendingPathComponent(short.filename))
        try require(shortOutput.length == 88200 && shortOutput.fileFormat.sampleRate == 22050,
          "\(label): padded/truncated copy must be exactly 4 seconds")

        let sounds = directory.appendingPathComponent("Sounds")
        let sound = try AlarmKitSoundBuilder.prepare(source: source, directory: sounds)
        let soundURL = sounds.appendingPathComponent(sound)
        try require(AlarmKitSoundBuilder.valid(soundURL), "\(label): invalid final PCM16 cue")
        let facts = try WaveCueInspector.inspect(Data(contentsOf: soundURL))
        try require(facts?.isFourSecondCue == true && facts?.hasLoopMetadata == false,
          "\(label): WAV length/loop metadata")
        try require(sound.hasPrefix("luma-ak4-") && sound.hasSuffix(".wav"),
          "\(label): must use new WAV cache")
        // Inspect the disk encoding separately from a standard Float32 reader.
        let inspection = try AVAudioFile(forReading: soundURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        print("INFO: \(label): file=\(inspection.fileFormat), processing=\(inspection.processingFormat), frames=\(inspection.length)")
        let pcm = try readMonoFloat(soundURL)
        try require(pcm.count == 88200, "\(label): expected 88200 decoded frames, got \(pcm.count)")
        try require(pcm.allSatisfy(\.isFinite), "\(label): nonfinite samples")
        try require(pcm[0] == 0 && pcm[88199] == 0, "\(label): fade endpoints must be zero")
        let contentEnd = min(88200, Int((seconds * 22050).rounded()))
        try require(pcm[max(0, contentEnd - 16)..<contentEnd].allSatisfy { abs($0) < 0.001 },
          "\(label): content must fade before truncation/padding")
        if seconds < 4 {
          let silentStart = min(88200, Int(ceil(seconds * 22050)) + 2048)
          try require(pcm[silentStart..<88200].allSatisfy { $0 == 0 }, "\(label): short content must have silent padding")
        }
        let cached = try AlarmKitSoundBuilder.prepare(source: source, directory: sounds)
        try require(cached == sound, "\(label): cache name changed")
        let after = try Data(contentsOf: source)
        try require(after == original, "\(label): original source changed")
        print("PASS: \(label): finite PCM16 4s; Float32 processing; fade, padding, cache and original verified")
        cases += 1
      }
    }
    try checkVolume(directory)
    let bad = directory.appendingPathComponent("invalid.mp3")
    try Data("invalid audio".utf8).write(to: bad)
    var rejected = false
    do { _ = try AlarmKitSoundBuilder.prepare(source: bad, directory: directory) }
    catch { rejected = true }
    try require(rejected, "Invalid input must be rejected without a default sound fallback")
    print("PASS: \(cases) audio matrix cases plus invalid-input rejection. No physical-device claim.")
  }
  /// 1.0: the signal volume. 100 % keeps the 0.9.9 file name and level; 50 % is its own copy,
  /// 10 dB quieter, with the same zero endpoints. The levels are passed explicitly, so the result
  /// does not depend on what the runner has stored.
  static func checkVolume(_ directory: URL) throws {
    let source = directory.appendingPathComponent("volume-source.wav")
    try writeTone(source, seconds: 4.0, sampleRate: 22050, channels: 1, bits: 16)
    let sounds = directory.appendingPathComponent("VolumeSounds")
    let full = try AlarmKitSoundBuilder.prepare(source: source, directory: sounds, volumePercent: 100)
    let half = try AlarmKitSoundBuilder.prepare(source: source, directory: sounds, volumePercent: 50)
    let sourceBytes = try Data(contentsOf: source)
    var hasher = SHA256()
    hasher.update(data: Data("luma-alarmkit-wave-4s-fade-v4".utf8))
    hasher.update(data: sourceBytes)
    let unity = "luma-ak4-" + hasher.finalize().map { String(format: "%02x", $0) }.joined() + ".wav"
    try require(full == unity, "Volume: 100 % must keep the 0.9.9 cache name")
    try require(half != full && half.hasPrefix("luma-ak4-") && half.hasSuffix(".wav"),
      "Volume: 50 % must be a separate WAV copy")
    try require(AlarmKitSoundBuilder.valid(sounds.appendingPathComponent(half)), "Volume: invalid 50 % copy")
    let loud = try readMonoFloat(sounds.appendingPathComponent(full))
    let quiet = try readMonoFloat(sounds.appendingPathComponent(half))
    try require(loud.count == 88200 && quiet.count == 88200, "Volume: both copies must be 4 seconds")
    try require(quiet[0] == 0 && quiet[88199] == 0, "Volume: fade endpoints must stay zero")
    let loudPeak = loud.map { abs($0) }.max() ?? 0
    let quietPeak = quiet.map { abs($0) }.max() ?? 0
    let ratio = Double(quietPeak / max(loudPeak, .leastNonzeroMagnitude))
    let expected = AlarmSignalVolume.gain(50)
    try require(loudPeak > 0.05 && abs(ratio - expected) < 0.01,
      "Volume: 50 % must scale the copy by \(expected), got \(ratio)")
    let again = try AlarmKitSoundBuilder.prepare(source: source, directory: sounds, volumePercent: 50)
    try require(again == half, "Volume: the 50 % cache name changed")
    print("PASS: volume 100 % keeps the 0.9.9 copy; 50 % is a separate copy at \(ratio) of its peak")
  }
  static func readMonoFloat(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    try require(file.processingFormat.commonFormat == .pcmFormatFloat32
      && !file.processingFormat.isInterleaved && file.processingFormat.channelCount == 1,
      "Unexpected inspection processing format \(file.processingFormat)")
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
      let samples = buffer.floatChannelData?[0] else {
      throw AudioCheckFailure(description: "Cannot allocate Float32 inspection buffer")
    }
    var result: [Float] = []
    while file.framePosition < file.length {
      let requested = AVAudioFrameCount(min(4096, file.length - file.framePosition))
      buffer.frameLength = 0
      try file.read(into: buffer, frameCount: requested)
      try require(buffer.frameLength > 0, "Early EOF in inspection: \(result.count)/\(file.length)")
      result.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }
    return result
  }
  static func writeTone(_ url: URL, seconds: Double, sampleRate: Double,
    channels: AVAudioChannelCount, bits: Int) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
      let data = buffer.floatChannelData else {
      throw AudioCheckFailure(description: "Cannot allocate source fixture")
    }
    // File data is interleaved. Work buffers are non-interleaved Float32.
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
      AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: bits == 32,
      AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    let file = try AVAudioFile(forWriting: url, settings: settings,
      commonFormat: .pcmFormatFloat32, interleaved: false)
    var position = 0
    let total = Int((seconds * sampleRate).rounded())
    while position < total {
      let count = min(4096, total - position)
      buffer.frameLength = AVAudioFrameCount(count)
      for channel in 0..<Int(channels) {
        for frame in 0..<count {
          data[channel][frame] = Float(sin(Double(position + frame) * 440 * 2 * .pi / sampleRate) * 0.1)
        }
      }
      try file.write(from: buffer)
      position += count
    }
  }
}
