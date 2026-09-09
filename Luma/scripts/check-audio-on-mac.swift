import Foundation
import AVFoundation

@main
struct AudioImportCheck {
  static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Luma-audio-check-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for seconds in [2.0, 40.0] {
      let source = directory.appendingPathComponent("test-\(Int(seconds)).wav")
      try writeTone(source, seconds: seconds)
      let clip = try CueAudioImporter.convert(source: source, directory: directory)
      let output = try AVAudioFile(forReading: directory.appendingPathComponent(clip.filename))
      let duration = Double(output.length) / output.fileFormat.sampleRate
      precondition(output.fileFormat.sampleRate == 22050 && output.fileFormat.channelCount == 1)
      precondition(abs(duration - min(28, seconds)) < 0.05, "Incorrect trimming")
      precondition(clip.imported == true && abs((clip.sourceDuration ?? 0) - seconds) < 0.05)
      precondition(output.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM)
      print("PASS: stereo 48 kHz \(seconds)s converted to mono PCM 22.05 kHz \(duration)s")
    }
    let bad = directory.appendingPathComponent("invalid.mp3")
    try Data("invalid audio".utf8).write(to: bad)
    do { _ = try CueAudioImporter.convert(source: bad, directory: directory); fatalError("Invalid input accepted") }
    catch { print("PASS: invalid audio rejected") }
  }
  static func writeTone(_ url: URL, seconds: Double) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    var position = 0
    while position < Int(seconds * 48000) {
      let count = min(4096, Int(seconds * 48000) - position); buffer.frameLength = AVAudioFrameCount(count)
      for channel in 0..<2 { for frame in 0..<count {
        buffer.floatChannelData![channel][frame] = Float(sin(Double(position + frame) * 440 * 2 * .pi / 48000) * 0.1)
      } }
      try file.write(from: buffer); position += count
    }
  }
}
