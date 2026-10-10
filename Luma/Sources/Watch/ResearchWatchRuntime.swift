import Foundation
import HealthKit
import WatchKit

/// Explicit, user-started sensor experiment. Not an App Store sleep-runtime solution.
@MainActor final class ResearchWatchRuntime: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
  var onPacket: ((WirePacket) -> Void)?
  var onStatus: ((String, Bool) -> Void)?
  private let store = HKHealthStore()
  private let motion = MotionService()
  private let log = ResearchLog()
  private var session: HKWorkoutSession?
  private var builder: HKLiveWorkoutBuilder?
  private var detector: RealtimeREMEngine?
  private var heart: [HeartSample] = []
  private var timer: Timer?
  private var haptics: Task<Void, Never>?
  private var testTask: Task<Void, Never>?
  private var cueToken = UUID()
  private var runID = UUID()
  private var signal = SignalSettings()
  private(set) var sessionID: UUID?
  private(set) var isRunning = false
  private(set) var isStarting = false
  var logURL: URL? { log.fileURL }

  func start(id: UUID, signal: SignalSettings) async throws {
    guard session == nil, !isStarting else { return }
    guard WKApplication.shared().applicationState == .active else {
      throw AppError.message("Начните тест при открытой Luma на часах.")
    }
    isStarting = true; sessionID = id; runID = UUID()
    defer { isStarting = false }
    self.signal = signal.validated()
    let hr = HKQuantityType(.heartRate)
    do {
      try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hr])
      guard sessionID == id else { return }
      guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
        throw AppError.message("Для теста разрешите Luma доступ к тренировкам в настройках «Здоровья».")
      }
      let configuration = HKWorkoutConfiguration()
      configuration.activityType = .other
      configuration.locationType = .unknown
      let next = try HKWorkoutSession(healthStore: store, configuration: configuration)
      let nextBuilder = next.associatedWorkoutBuilder()
      let source = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
      // Suppress energy statistics; this does NOT guarantee that Health/Activity is unaffected.
      source.disableCollection(for: HKQuantityType(.activeEnergyBurned))
      source.disableCollection(for: HKQuantityType(.basalEnergyBurned))
      nextBuilder.dataSource = source
      next.delegate = self; nextBuilder.delegate = self
      session = next; builder = nextBuilder
      let start = Date()
      detector = RealtimeREMEngine(startedAt: start)
      heart = []; log.start(id)
      next.startActivity(with: start)
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        nextBuilder.beginCollection(withStart: start) { success, error in
          if let error { c.resume(throwing: error) }
          else if success { c.resume() }
          else { c.resume(throwing: AppError.message("Не удалось начать сбор пульса.")) }
        }
      }
      guard sessionID == id, session === next else { next.end(); return }
      isRunning = true
      motion.reset(); motion.startUpdates()
      timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.evaluate() }
      }
      next.startMirroringToCompanionDevice { [weak self] success, error in
        Task { @MainActor in
          guard let self, self.session === next else { return }
          self.status(success ? "Связь с iPhone установлена · собираем пульс"
            : "Основной канал iPhone недоступен · пробуем WatchConnectivity: \(error?.localizedDescription ?? "нет связи")")
        }
      }
      status("Тест датчиков запущен · собираем пульс")
    } catch {
      stop(reason: "Сбор данных остановлен: \(error.localizedDescription)")
      throw error
    }
  }

  func stop(reason: String = "Ночной тест завершён") {
    let id = sessionID
    timer?.invalidate(); timer = nil
    haptics?.cancel(); haptics = nil; cueToken = UUID()
    testTask?.cancel(); testTask = nil
    motion.stopUpdates()
    isRunning = false
    if let id {
      var p = WirePacket(kind: .researchStopped); p.sessionID = id
      p.message = reason; p.researchRunning = false
      transmit(p)
    }
    let old = session
    session = nil; sessionID = nil; detector = nil
    old?.end(); builder?.discardWorkout(); builder = nil
    onStatus?(reason, false)
  }

  func receive(_ p: WirePacket) {
    guard p.sessionID == sessionID else { return }
    guard p.researchRunID == nil || p.researchRunID == runID else { return }
    if p.kind == .researchStop { stop(reason: "Сеанс завершён на iPhone") }
    else if p.kind == .researchReceipt { log.append(p) }
  }

  /// Exercises the actual delayed/background cue path; never counts as a REM detection.
  func scheduleTest() {
    guard isRunning else { return }
    testTask?.cancel()
    status("Проба через 60 секунд · погасите оба экрана")
    testTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
      guard let self, self.isRunning else { return }
      let now = Date()
      self.cue(REMEpisode(date: now, features: FeatureSnapshot(date: now, source: .watch)), test: true)
    }
  }

  private func evaluate() {
    guard isRunning, session?.state == .running, let id = sessionID else { return }
    let now = Date()
    heart.removeAll { now.timeIntervalSince($0.date) > 30 * 60 }
    guard let d = detector?.consume(heart: heart, motion: motion.epochs, now: now) else { return }
    var p = WirePacket(kind: .researchStatus)
    p.sessionID = id; p.researchRunning = true
    p.researchSample = d.evaluation.features
    // Keep overlapping recent measurements in the local diagnostic log, not just
    // one selected BPM value. The receiver deduplicates samples by timestamp.
    p.heart = heart.filter { now.timeIntervalSince($0.date) <= 30 }
    p.motion = motion.epochs
    p.message = d.evaluation.evidence.explanation
    transmit(p)
    onStatus?(p.message ?? "Сбор данных", true)
    if let episode = d.episode { cue(episode, test: false) }
  }

  private func cue(_ episode: REMEpisode, test: Bool) {
    guard isRunning, let id = sessionID, haptics == nil else { return }
    let start = Date().addingTimeInterval(2)
    let count = signal.count.rawValue
    let duration = max(28, Double((count - 1) * signal.gapSeconds + 2))
    detector?.excludeCue(until: start.addingTimeInterval(duration + 90))
    var p = WirePacket(kind: .researchCue)
    p.sessionID = id; p.episodeID = episode.id; p.researchEpisode = episode
    p.signal = signal; p.cueDate = start; p.researchTest = test
    p.message = test ? "Проба — это не обнаружение REM" : "Вероятный REM · локальное решение часов"
    // No phone acknowledgement is required before starting local haptics.
    transmit(p)
    guard signal.output.watchEnabled else { return }
    let token = UUID(); cueToken = token
    let gap = signal.gapSeconds
    haptics = Task { @MainActor [weak self] in
      defer { if self?.cueToken == token { self?.haptics = nil } }
      do {
        try await Task.sleep(nanoseconds: UInt64(max(0, start.timeIntervalSinceNow) * 1_000_000_000))
        for index in 0..<count {
          guard let self, !Task.isCancelled, self.cueToken == token,
            self.isRunning, self.session?.state == .running else { return }
          // Each call is a finite system haptic. No Smart Alarm / looping alert.
          WKInterfaceDevice.current().play(.notification)
          if index < count - 1 { try await Task.sleep(nanoseconds: UInt64(gap) * 1_000_000_000) }
        }
      } catch { return }
      guard let self, self.cueToken == token else { return }
      var receipt = WirePacket(kind: .researchReceipt)
      receipt.sessionID = id; receipt.episodeID = episode.id
      receipt.message = "Конечная серия вибраций запрошена: \(count). Физическое ощущение API не подтверждает."
      self.transmit(receipt)
    }
  }

  private func status(_ text: String) {
    onStatus?(text, isRunning)
    guard let id = sessionID else { return }
    var p = WirePacket(kind: .researchStatus)
    p.sessionID = id; p.message = text; p.researchRunning = isRunning
    transmit(p)
  }
  private func transmit(_ p: WirePacket) {
    var packet = p; packet.researchRunID = runID
    log.append(packet)
    onPacket?(packet)
    guard let session, let data = try? JSONEncoder().encode(packet) else { return }
    session.sendToRemoteWorkoutSession(data: data) { _, _ in }
  }
  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
    didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
    Task { @MainActor [weak self] in
      guard let self, self.session === workoutSession else { return }
      if toState == .ended || toState == .stopped || toState == .paused {
        self.stop(reason: "Системная сессия остановилась · начните тест заново")
      }
    }
  }
  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
    Task { @MainActor [weak self] in
      guard let self, self.session === workoutSession else { return }
      self.stop(reason: "Ошибка сессии: \(error.localizedDescription)")
    }
  }
  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
    didReceiveDataFromRemoteWorkoutSession data: [Data]) {
    for bytes in data where bytes.count < 256_000 {
      guard let p = try? JSONDecoder().decode(WirePacket.self, from: bytes) else { continue }
      Task { @MainActor [weak self] in
        guard let self, self.session === workoutSession else { return }
        self.receive(p)
      }
    }
  }
  nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) { }
  nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
    didCollectDataOf collectedTypes: Set<HKSampleType>) {
    let type = HKQuantityType(.heartRate)
    guard collectedTypes.contains(type), let stats = workoutBuilder.statistics(for: type),
      let quantity = stats.mostRecentQuantity(), let date = stats.mostRecentQuantityDateInterval()?.end
    else { return }
    let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
    Task { @MainActor [weak self] in
      guard let self, self.builder === workoutBuilder, self.isRunning,
        bpm.isFinite, (30...210).contains(bpm), date <= Date(),
        self.heart.last.map({ date > $0.date }) ?? true else { return }
      self.heart.append(HeartSample(date: date, bpm: bpm, source: "Luma.Watch.LiveWorkout"))
    }
  }
}
