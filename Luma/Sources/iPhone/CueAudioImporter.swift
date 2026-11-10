import Foundation
import AVFoundation

enum CueAudioImporter {
  static func convert(source: URL, directory: URL, maximumDuration: TimeInterval = 28,
    padToMaximum: Bool = false) throws -> VoiceClip {
    guard maximumDuration.isFinite, (0.31...28).contains(maximumDuration) else {
      throw AppError.message("Недопустимая длительность аудио.")
    }
    guard source.isFileURL else { throw AppError.message("Выберите аудиофайл в приложении «Файлы».") }
    let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 100 * 1024 * 1024 else { throw AppError.message("Выберите аудиофайл размером до 100 МБ.") }
    let input = try AVAudioFile(forReading: source)
    let sourceDuration = Double(input.length) / input.processingFormat.sampleRate
    guard sourceDuration.isFinite, sourceDuration > 0.3,
      let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22050, channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: input.processingFormat, to: format),
      let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
    else { throw AppError.message("Не удалось прочитать аудио. Попробуйте MP3, M4A, WAV или CAF без защиты.") }
    let id = UUID()
    let target = directory.appendingPathComponent("luma-import-\(id.uuidString).caf")
    do {
      let output = try AVAudioFile(forWriting: target, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
      let maximumFrames = AVAudioFramePosition(22050 * maximumDuration)
      var remainingInput = min(input.length, AVAudioFramePosition(input.processingFormat.sampleRate * maximumDuration))
      var written: AVAudioFramePosition = 0
      var readError: Error?
      while written < maximumFrames {
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { requested, state in
          guard remainingInput > 0 else { state.pointee = .endOfStream; return nil }
          let frames = AVAudioFrameCount(min(remainingInput, AVAudioFramePosition(requested)))
          guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frames) else {
            state.pointee = .endOfStream; return nil
          }
          do {
            try input.read(into: buffer, frameCount: frames)
            remainingInput -= AVAudioFramePosition(buffer.frameLength)
            if buffer.frameLength == 0 { remainingInput = 0; state.pointee = .endOfStream; return nil }
            state.pointee = .haveData; return buffer
          } catch { readError = error; state.pointee = .endOfStream; return nil }
        }
        if let error { throw error }; if let readError { throw readError }
        let accepted = min(outputBuffer.frameLength, AVAudioFrameCount(maximumFrames - written))
        outputBuffer.frameLength = accepted
        if accepted > 0 { try output.write(from: outputBuffer); written += AVAudioFramePosition(accepted) }
        if status == .endOfStream { break }
        if status == .error || accepted == 0 { throw AppError.message("Формат аудиофайла не поддерживается.") }
      }
      guard written > 6615 else { throw AppError.message("Аудиофайл слишком короткий.") }
      // A short voice remains intact; a silent tail fills the rest of its four
      // second AlarmKit copy. The original diary/voice file is never truncated.
      if padToMaximum, let samples = outputBuffer.int16ChannelData?[0] {
        samples.initialize(repeating: 0, count: Int(outputBuffer.frameCapacity))
        while written < maximumFrames {
          outputBuffer.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(outputBuffer.frameCapacity), maximumFrames - written))
          try output.write(from: outputBuffer); written += AVAudioFramePosition(outputBuffer.frameLength)
        }
      }
      #if os(iOS)
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
      #endif
      var clip = VoiceClip(id: id, name: String(source.deletingPathExtension().lastPathComponent.prefix(60)),
        filename: target.lastPathComponent, duration: Double(written) / 22050)
      clip.imported = true; clip.sourceDuration = sourceDuration
      return clip
    } catch { try? FileManager.default.removeItem(at: target); throw error }
  }
}
