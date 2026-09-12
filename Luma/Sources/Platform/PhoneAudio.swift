#if os(iOS)
  import Foundation
  import AVFoundation
  import Combine
  import UIKit
  import AudioToolbox
  @MainActor
  final class PhoneAudio: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate
  {
    @Published private(set) var monitoring = false
    @Published private(set) var recording = false
    @Published private(set) var playing = false
    @Published private(set) var recordSeconds = 0.0
    @Published private(set) var recordingJournal = false
    @Published private(set) var playbackID: UUID?
    @Published private(set) var playbackSeconds = 0.0
    private var preparingCapture = false
    private var journalCompletion: ((JournalVoice) -> Void)?
    private var hapticTask: Task<Void, Never>?
    private var playbackTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var onEpoch: ((AudioEpoch) -> Void)?
    var onClip: ((VoiceClip) -> Void)?
    var onError: ((String) -> Void)?
    var onInterruption: ((String) -> Void)?
    var isLumaSystemAlarm: (() -> Bool)?
    private let engine = AVAudioEngine()
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var recordingID: UUID?
    private var name = "Моя подсказка"
    private var tap = false
    private var excludedUntil = Date.distantPast
    override init() {
      super.init()
      observers.append(
        NotificationCenter.default.addObserver(
          forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] n in
          guard
            n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
              == AVAudioSession.InterruptionType.began.rawValue
          else { return }
          Task { @MainActor in self?.interrupt() }
        })
      observers.append(
        NotificationCenter.default.addObserver(
          forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
          Task { @MainActor in if self?.monitoring == true { self?.interrupt() } }
        })
    }
    func soundsDirectory() throws -> URL {
      var d = try FileManager.default.url(
        for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("Sounds")
      try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try d.setResourceValues(values)
      return d
    }
    func soundURL(_ s: SignalSettings, clips: [VoiceClip]) throws -> URL {
      if let id = s.voiceID {
        guard let clip = clips.first(where: { $0.id == id }), clip.duration > 0, clip.duration < 29,
          ["luma-voice-\(id.uuidString).caf", "luma-import-\(id.uuidString).caf"].contains(clip.filename)
        else { throw AppError.message("Выберите доступную голосовую дорожку.") }
        let url = try soundsDirectory().appendingPathComponent(clip.filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
          throw AppError.message("Файл дорожки не найден.")
        }
        return url
      }
      guard
        let url = Bundle.main.url(
          forResource: "luma-tone-\(s.validated().melodySeconds)", withExtension: "wav")
      else { throw AppError.message("Мелодия не найдена.") }
      return url
    }
    func alarmSound(_ signal: SignalSettings, clips: [VoiceClip]) throws -> PhoneAlarmService.Sound {
      let url = try soundURL(signal, clips: clips)
      let file = try AVAudioFile(forReading: url)
      let duration = Double(file.length) / file.processingFormat.sampleRate
      guard AlarmStopWindow(startsAt: Date(), duration: duration) != nil else {
        throw AppError.message("Выберите звук длительностью до 28 секунд.")
      }
      return PhoneAlarmService.Sound(name: url.lastPathComponent, duration: duration)
    }
    func permission() async throws {
      let allowed: Bool = await withCheckedContinuation { c in
        AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
      }
      guard allowed else { throw AppError.message("Разрешите микрофон: Настройки iPhone → Luma.") }
    }
    private func activate(record: Bool) throws {
      let s = AVAudioSession.sharedInstance()
      try s.setCategory(
        record ? .playAndRecord : .playback, mode: .default,
        options: record ? [.defaultToSpeaker] : [])
      try s.setActive(true)
      if record {
        try s.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try s.overrideOutputAudioPort(.speaker)
      }
    }
    func startMonitoring() async throws {
      guard !recording, !preparingCapture else { throw AppError.message("Сначала завершите запись.") }
      guard !monitoring else { return }
      try await permission()
      guard !recording, !preparingCapture else { throw AppError.message("Сначала завершите запись.") }
      try activate(record: true)
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        throw AppError.message("Микрофон недоступен.")
      }
      let accumulator = EnvelopeAccumulator(rate: format.sampleRate)
      input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] b, _ in
        guard let data = b.floatChannelData?[0] else { return }
        accumulator.append(data, count: Int(b.frameLength)) { values, start, end in
          guard let epoch = AcousticFeatures.extract(envelope: values, start: start, end: end)
          else { return }
          Task { @MainActor in
            guard let self, self.monitoring else { return }
            var e = epoch
            e.contaminated = e.start < self.excludedUntil
            self.onEpoch?(e)
          }
        }
      }
      tap = true
      do {
        try engine.start()
        monitoring = true
      } catch {
        stopMonitoring()
        throw error
      }
    }
    func stopMonitoring() {
      monitoring = false
      engine.stop()
      if tap {
        engine.inputNode.removeTap(onBus: 0)
        tap = false
      }
      deactivate()
    }
    func journalDirectory() throws -> URL {
      var directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true).appendingPathComponent("Luma/JournalAudio", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var values = URLResourceValues(); values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
      return directory
    }
    func journalURL(_ voice: JournalVoice) throws -> URL {
      guard voice.hasSafeFilename, voice.duration > 0, voice.duration < 1801 else {
        throw AppError.message("Файл голосовой заметки недоступен.")
      }
      let url = try journalDirectory().appendingPathComponent(voice.filename)
      guard FileManager.default.fileExists(atPath: url.path) else { throw AppError.message("Запись не найдена на iPhone.") }
      return url
    }
    func startRecording(name: String) async throws { try await startCapture(name: name, journal: nil) }
    func startJournalRecording(completion: @escaping (JournalVoice) -> Void) async throws {
      try await startCapture(name: "", journal: completion)
    }
    private func startCapture(name: String, journal: ((JournalVoice) -> Void)?) async throws {
      guard !monitoring, !recording, !preparingCapture else { throw AppError.message("Записывайте голос между сеансами.") }
      preparingCapture = true
      defer { preparingCapture = false }
      stopPlayback()
      try await permission()
      guard !monitoring, !recording else { throw AppError.message("Завершите ночной сеанс.") }
      try activate(record: true)
      let id = UUID(), isJournal = journal != nil
      let url = try (isJournal ? journalDirectory() : soundsDirectory())
        .appendingPathComponent(isJournal ? "luma-journal-\(id.uuidString).m4a" : "luma-voice-\(id.uuidString).caf")
      do {
        let settings: [String: Any] = isJournal
          ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
          : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 22050.0, AVNumberOfChannelsKey: 1,
             AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let capture = try AVAudioRecorder(url: url, settings: settings)
        capture.delegate = self; recorder = capture; recordingID = id
        self.name = String(name.prefix(60)); journalCompletion = journal; recordingJournal = isJournal
        guard capture.record(forDuration: isJournal ? 1800 : 28) else { throw AppError.message("Не удалось начать запись.") }
        recording = true; recordSeconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
          Task { @MainActor in self?.recordSeconds = self?.recorder?.currentTime ?? 0 }
        }
      } catch {
        recorder = nil; recordingID = nil; journalCompletion = nil; recordingJournal = false
        try? FileManager.default.removeItem(at: url); deactivate(); throw error
      }
    }
    func finishRecording() {
      guard let capture = recorder else { return }
      capture.stop()
      completeRecording(url: capture.url, success: true)
    }
    private func completeRecording(url: URL, success: Bool) {
      guard let id = recordingID, recorder?.url == url else { return }
      let isJournal = recordingJournal, completion = journalCompletion, clipName = name
      recordingID = nil; journalCompletion = nil; recorder = nil
      timer?.invalidate(); timer = nil; recording = false; recordingJournal = false
      defer { deactivate() }
      do {
        guard success else { throw AppError.message("Запись прервалась.") }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration > 0.3, duration < (isJournal ? 1801 : 29) else { throw AppError.message("Запись слишком короткая. Попробуйте ещё раз.") }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        if isJournal { completion?(JournalVoice(id: id, filename: url.lastPathComponent, duration: duration)) }
        else { onClip?(VoiceClip(id: id, name: clipName.isEmpty ? "Моя подсказка" : clipName, filename: url.lastPathComponent, duration: duration)) }
      } catch { try? FileManager.default.removeItem(at: url); onError?(error.localizedDescription) }
    }
    func importSound(from source: URL) async throws -> VoiceClip {
      guard !monitoring, !recording, !preparingCapture else { throw AppError.message("Добавляйте мелодии между сеансами.") }
      let access = source.startAccessingSecurityScopedResource()
      defer { if access { source.stopAccessingSecurityScopedResource() } }
      let directory = try soundsDirectory()
      return try await Task.detached(priority: .userInitiated) { try CueAudioImporter.convert(source: source, directory: directory) }.value
    }
    func play(_ signal: SignalSettings, clips: [VoiceClip], vibrate: Bool = false) throws {
      if recording { finishRecording() }
      try playFile(soundURL(signal, clips: clips), id: signal.voiceID, vibrate: vibrate)
    }
    func playJournal(_ voice: JournalVoice) throws {
      guard !recording, !monitoring else { throw AppError.message("Завершите запись или ночной сеанс перед прослушиванием.") }
      try playFile(journalURL(voice), id: voice.id, vibrate: false)
    }
    private func playFile(_ url: URL, id: UUID?, vibrate: Bool) throws {
      stopPlayback()
      // Bridges a sensor callback into genuine audio playback; does not create background wake-ups.
      backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Luma sound") { [weak self] in
        Task { @MainActor in self?.endBackgroundTask() }
      }
      do {
        if !monitoring { try activate(record: false) }
        let next = try AVAudioPlayer(contentsOf: url)
        next.numberOfLoops = 0; next.delegate = self; player = next
        excludedUntil = Date().addingTimeInterval(next.duration + 90)
        guard next.play() else { throw AppError.message("Не удалось воспроизвести звук.") }
        playbackID = id; playbackSeconds = 0; playing = true
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
          Task { @MainActor in self?.playbackSeconds = self?.player?.currentTime ?? 0 }
        }
        if vibrate {
          let duration = min(28, next.duration)
          hapticTask = Task { @MainActor [weak self] in
            let end = Date().addingTimeInterval(duration)
            while !Task.isCancelled, self?.playing == true, Date() < end {
              AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
              do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
          }
        }
      } catch { stopPlayback(); throw error }
    }
    func stopPlayback() {
      hapticTask?.cancel(); hapticTask = nil; player?.stop(); player = nil
      playbackTimer?.invalidate(); playbackTimer = nil
      playing = false; playbackID = nil; playbackSeconds = 0
      endBackgroundTask(); deactivate()
    }
    private func endBackgroundTask() {
      guard backgroundTask != .invalid else { return }
      let id = backgroundTask; backgroundTask = .invalid
      UIApplication.shared.endBackgroundTask(id)
    }
    private func deactivate() {
      if !monitoring && !recording && !playing {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      }
    }
    private func interrupt() {
      let active = monitoring
      let ownAlarm = isLumaSystemAlarm?() == true
      stopMonitoring()
      stopPlayback()
      finishRecording()
      if active && !ownAlarm {
        onInterruption?("Звук прерван системой. Возобновите сеанс, когда будете готовы.")
      }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
      Task { @MainActor [weak self] in
        guard self?.player === player else { return }; self?.stopPlayback()
      }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
      let url = recorder.url
      Task { @MainActor [weak self] in self?.completeRecording(url: url, success: flag) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
      Task { @MainActor [weak self] in
        guard self?.player === player else { return }; self?.stopPlayback()
        self?.onError?("Не удалось воспроизвести аудио. Выберите другую запись.")
      }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
      let url = recorder.url
      Task { @MainActor [weak self] in self?.completeRecording(url: url, success: false) }
    }
  }
  private final class EnvelopeAccumulator: @unchecked Sendable {
    let bucket: Int
    var count = 0
    var energy = 0.0
    var values: [Double] = []
    var start = Date()
    init(rate: Double) {
      bucket = max(1, Int(rate / 10))
      values.reserveCapacity(600)
    }
    func append(
      _ data: UnsafePointer<Float>, count length: Int, emit: ([Double], Date, Date) -> Void
    ) {
      for i in 0..<length {
        let x = Double(data[i])
        energy += x * x
        count += 1
        if count >= bucket {
          values.append(sqrt(energy / Double(count)))
          count = 0
          energy = 0
          if values.count == 600 {
            let end = Date()
            emit(values, start, end)
            values.removeAll(keepingCapacity: true)
            start = end
          }
        }
      }
    }
  }
#endif
