#if os(iOS)
  import Foundation
  import AVFoundation
  import Combine
  @MainActor
  final class PhoneAudio: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate
  {
    @Published private(set) var monitoring = false
    @Published private(set) var recording = false
    @Published private(set) var playing = false
    @Published private(set) var recordSeconds = 0.0
    var onEpoch: ((AudioEpoch) -> Void)?
    var onClip: ((VoiceClip) -> Void)?
    var onError: ((String) -> Void)?
    var onInterruption: ((String) -> Void)?
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
          clip.filename == "luma-voice-\(id.uuidString).caf"
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
      if record { try s.overrideOutputAudioPort(.speaker) }
    }
    func startMonitoring() async throws {
      guard !recording else { throw AppError.message("Сначала завершите запись подсказки.") }
      guard !monitoring else { return }
      try await permission()
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
    func startRecording(name: String) async throws {
      guard !monitoring, !recording else {
        throw AppError.message("Записывайте подсказки между сеансами.")
      }
      stopPlayback()
      try await permission()
      try activate(record: true)
      let id = UUID()
      let url = try soundsDirectory().appendingPathComponent("luma-voice-\(id.uuidString).caf")
      let r = try AVAudioRecorder(
        url: url,
        settings: [
          AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 22050.0, AVNumberOfChannelsKey: 1,
          AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
        ])
      r.delegate = self
      recorder = r
      recordingID = id
      self.name = String(name.prefix(60))
      guard r.record(forDuration: 28) else {
        recorder = nil
        throw AppError.message("Не удалось начать запись.")
      }
      recording = true
      recordSeconds = 0
      startRecordingTimer()
    }
    private func startRecordingTimer() {
      timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.recordSeconds = self?.recorder?.currentTime ?? 0 }
      }
    }
    func finishRecording() { recorder?.stop() }
    func play(_ s: SignalSettings, clips: [VoiceClip]) throws {
      guard !recording else { throw AppError.message("Сначала завершите запись.") }
      stopPlayback()
      if !monitoring { try activate(record: false) }
      let p = try AVAudioPlayer(contentsOf: soundURL(s, clips: clips))
      p.numberOfLoops = 0
      p.delegate = self
      player = p
      excludedUntil = Date().addingTimeInterval(p.duration + 90)
      guard p.play() else {
        player = nil
        throw AppError.message("Воспроизведение недоступно.")
      }
      playing = true
    }
    func stopPlayback() {
      player?.stop()
      player = nil
      playing = false
      deactivate()
    }
    private func deactivate() {
      if !monitoring && !recording && !playing {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      }
    }
    private func interrupt() {
      let active = monitoring
      stopMonitoring()
      stopPlayback()
      finishRecording()
      if active {
        onInterruption?("Звук прерван системой. Возобновите сеанс, когда будете готовы.")
      }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
      Task { @MainActor [weak self] in
        self?.playing = false
        self?.player = nil
        self?.deactivate()
      }
    }
    nonisolated func audioRecorderDidFinishRecording(
      _ recorder: AVAudioRecorder, successfully flag: Bool
    ) {
      let url = recorder.url
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.recording = false
        self.timer?.invalidate()
        self.timer = nil
        self.recorder = nil
        defer { self.deactivate() }
        do {
          guard flag, let id = self.recordingID else {
            throw AppError.message("Запись прервалась.")
          }
          let f = try AVAudioFile(forReading: url)
          let duration = Double(f.length) / f.processingFormat.sampleRate
          guard duration > 0.3, duration < 29 else {
            throw AppError.message("Запишите подсказку от 1 до 28 секунд.")
          }
          try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
          self.onClip?(
            VoiceClip(
              id: id, name: self.name.isEmpty ? "Моя подсказка" : self.name,
              filename: url.lastPathComponent, duration: duration))
        } catch {
          try? FileManager.default.removeItem(at: url)
          self.onError?(error.localizedDescription)
        }
      }
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
