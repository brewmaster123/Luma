import Foundation
import AVFoundation

enum CueAudioImporter {
  static func convert(source: URL, directory: URL) throws -> VoiceClip {
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
      var remainingInput = min(input.length, AVAudioFramePosition(input.processingFormat.sampleRate * 28))
      var written: AVAudioFramePosition = 0
      var readError: Error?
      while written < 22050 * 28 {
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
        let accepted = min(outputBuffer.frameLength, AVAudioFrameCount(22050 * 28 - written))
        outputBuffer.frameLength = accepted
        if accepted > 0 { try output.write(from: outputBuffer); written += AVAudioFramePosition(accepted) }
        if status == .endOfStream { break }
        if status == .error || accepted == 0 { throw AppError.message("Формат аудиофайла не поддерживается.") }
      }
      guard written > 6615 else { throw AppError.message("Аудиофайл слишком короткий.") }
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
