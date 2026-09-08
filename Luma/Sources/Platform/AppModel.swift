import Combine
import Foundation

@MainActor final class AppModel: ObservableObject {
  @Published private(set) var archive = AppArchive()
  @Published private(set) var state = LumaState()
  @Published private(set) var watchInstalled = false
  @Published private(set) var watchReachable = false
  @Published private(set) var watchStatus = "Ожидаем Apple Watch"
  @Published private(set) var evidence = REMEvidence.unavailable("Начните сеанс перед сном.")
  @Published private(set) var heart: [HeartSample] = []
  @Published private(set) var sleep: [SleepSegment] = []
  @Published private(set) var busy = false
  @Published private(set) var isForeground = false
  @Published private(set) var queuedAlarmIDs = Set<UUID>()
  @Published var message: String?
  @Published var showOnboarding = false
  private let health = HealthService()
  private let notifications = NotificationService()
  private let bridge = WatchBridge()
  private var store: LocalStore?
  private var storageProblem: String?
  private var migrated = false
  private var started = false
  private var refreshing = false
  private var rebuilding = false
  private var rebuildAgain = false
  private var timer: Timer?
  private var lastRefresh = Date.distantPast
  private var acoustic: [AudioEpoch] = []
  private var breath: [BreathSample] = []
  private var remoteMotion: [MotionEpoch] = []
  private var occurrences: [AlarmOccurrence] = []
  private var excludedUntil = Date.distantPast
  private var remoteSessionID: UUID?
  private var inbox: WirePacket?
  private var processing = false
  #if os(iOS)
    let audio = PhoneAudio()
  #else
    private let motion = MotionService()
    private let haptics = FiniteHaptics()
  #endif
  init() {
    do {
      let store = try LocalStore()
      archive = try store.load()
      self.store = store
      if let saved = archive.v2 {
        state = saved
      } else {
        migrated = true
        if archive.onboardingComplete {
          state.signal.output = .watch
          state.signal.count = archive.settings.cueCount
          state.signal.gapSeconds = archive.settings.intervalSeconds
        }
        if let p = archive.plan, p.windowStart > Date(), p.settings.mode == .scheduled,
          archive.planState == .armed
        {
          var a = LumaAlarm()
          a.onceAt = p.windowStart
          a.hour = p.settings.startHour
          a.minute = p.settings.startMinute
          a.signal = state.signal
          state.alarms = [a]
        }
      }
      for i in state.sessions.indices where state.sessions[i].status == .running {
        state.sessions[i].status = .paused
      }
    } catch {
      storageProblem = error.localizedDescription
      message = error.localizedDescription
    }
    showOnboarding = !archive.onboardingComplete
    bridge.onStatus = { [weak self] installed, reachable in
      self?.watchInstalled = installed
      self?.watchReachable = reachable
    }
    bridge.onPacket = { [weak self] in self?.receive($0) }
    health.onChange = { [weak self] in await self?.refreshSensors() }
    #if os(iOS)
      notifications.onForeground = { [weak self] in self?.handleAlarm($0) ?? false }
      audio.onEpoch = { [weak self] e in
        guard let self, let s = self.activeSession, s.status == .running,
          e.start >= s.startedAt.addingTimeInterval(-1)
        else { return }
        self.acoustic.append(e)
        self.acoustic.removeAll { $0.end < Date().addingTimeInterval(-900) }
        Task { await self.refreshSensors() }
      }
      audio.onClip = { [weak self] clip in
        guard let self else { return }
        self.state.voices.append(clip)
        self.state.signal.voiceID = clip.id
        self.save()
      }
      audio.onError = { [weak self] in self?.message = $0 }
      audio.onInterruption = { [weak self] text in
        guard let self, let i = self.activeIndex else { return }
        self.state.sessions[i].status = .paused
        self.resetStreak()
        self.save()
        self.syncConfiguration()
        self.message = text
      }
    #endif
  }
  var activeIndex: Int? { state.sessions.firstIndex { $0.status != .ended } }
  var activeSession: NightSession? { activeIndex.map { state.sessions[$0] } }
  var hasPlan: Bool { activeIndex != nil }
  var stateTitle: String {
    activeSession.map { $0.status == .paused ? "Сеанс на паузе" : "Наблюдаем за сном" }
      ?? "Ночь начинается с вас"
  }
  var personalizationCount: Int { Personalization.examples(state: state).count }
  func start() async {
    guard !started else { return }
    started = true
    if migrated {
      await notifications.cancelPrefix("luma.")
      save()
    }
    if storageProblem != nil {
      await notifications.cancelPrefix("luma.")
      return
    }
    await rebuildAlarms()
    syncConfiguration()
    if archive.onboardingComplete { try? await health.beginObserving() }
    startTicker()
  }
  private func startTicker() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.tick() }
    }
  }
  func resume() async {
    isForeground = true
    await rebuildAlarms()
    if archive.onboardingComplete {
      await refreshSensors()
      await refreshSleep()
    }
  }
  func suspend() {
    isForeground = false
    #if os(watchOS)
      motion.stopUpdates()
      haptics.cancel()
    #endif
  }
  private func tick() async {
    #if os(iOS)
      if isForeground || audio.monitoring {
        for a in occurrences
        where a.date <= Date() && Date().timeIntervalSince(a.date) < 3
          && a.signal.output.phoneEnabled
        { _ = handleAlarm(a.id + ".0") }
      }
    #endif
    if Date().timeIntervalSince(lastRefresh) >= 30
      && (isForeground || activeSession?.status == .running)
    {
      lastRefresh = Date()
      await refreshSensors()
    }
  }
  func completeIntroduction() {
    archive.onboardingComplete = true
    showOnboarding = false
    save()
  }
  func connectHealth() async {
    busy = true
    defer { busy = false }
    do {
      try await health.requestReadAccess()
      try await health.beginObserving()
      completeIntroduction()
      await refreshSensors()
      await refreshSleep()
    } catch { message = error.localizedDescription }
  }
  func requestSignalAccess() async {
    do {
      try await notifications.requestPermission()
      await rebuildAlarms()
    } catch { message = error.localizedDescription }
  }
  func updateSignal(_ s: SignalSettings) {
    state.signal = s.validated()
    save()
  }
  func setSource(_ source: SensorSource) {
    guard !hasPlan else {
      message = "Завершите сеанс перед сменой источника."
      return
    }
    state.source = source
    if source == .phone { state.signal.output = .phone }
    save()
  }
  func setPersonalization(_ enabled: Bool) {
    state.personalizationEnabled = enabled
    save()
  }
  func saveAlarm(_ input: LumaAlarm) async {
    var a = input
    a.title = String(a.title.prefix(80))
    a.signal = a.signal.validated()
    #if os(iOS)
      if a.enabled && a.signal.output.phoneEnabled {
        do { _ = try audio.soundURL(a.signal, clips: state.voices) } catch {
          message = error.localizedDescription
          return
        }
        do { try await notifications.requestPermission() } catch {
          message = error.localizedDescription
        }
      }
    #endif
    if let i = state.alarms.firstIndex(where: { $0.id == a.id }) {
      state.alarms[i] = a
    } else {
      state.alarms.append(a)
    }
    guard save() else { return }
    await rebuildAlarms()
    syncConfiguration()
  }
  func toggleAlarm(_ id: UUID) async {
    guard var a = state.alarms.first(where: { $0.id == id }) else { return }
    a.enabled.toggle()
    if a.enabled && a.weekdays.isEmpty && a.onceAt <= Date() {
      a.onceAt =
        Calendar.current.nextDate(
          after: Date().addingTimeInterval(10),
          matching: DateComponents(hour: a.hour, minute: a.minute), matchingPolicy: .nextTime)
        ?? Date().addingTimeInterval(3600)
    }
    await saveAlarm(a)
  }
  func deleteAlarm(_ id: UUID) async {
    state.alarms.removeAll { $0.id == id }
    guard save() else { return }
    await rebuildAlarms()
    syncConfiguration()
  }
  func beginSession() async {
    guard !busy, !hasPlan else { return }
    busy = true
    defer { busy = false }
    #if os(iOS)
      do {
        if state.source.usesWatch || state.signal.output.watchEnabled {
          guard watchInstalled else {
            throw AppError.message("Откройте Luma на часах или выберите «Только iPhone».")
          }
        }
        if state.signal.output.phoneEnabled {
          _ = try audio.soundURL(state.signal, clips: state.voices)
          if !state.source.usesMicrophone { try await notifications.requestPermission() }
        }
        if state.source.usesMicrophone { try await audio.startMonitoring() }
        let s = NightSession(source: state.source, signal: state.signal)
        state.sessions.insert(s, at: 0)
        state.episodeMemory = EpisodeMemory()
        acoustic = []
        excludedUntil = .distantPast
        do { try persist() } catch {
          state.sessions.removeAll { $0.id == s.id }
          audio.stopMonitoring()
          throw error
        }
        syncConfiguration()
        await refreshSensors()
      } catch { message = error.localizedDescription }
    #else
      message = "Начните ночной сеанс на iPhone."
    #endif
  }
  func resumeSession() async {
    guard let i = activeIndex, state.sessions[i].status == .paused, !busy else { return }
    busy = true
    defer { busy = false }
    #if os(iOS)
      do {
        if state.sessions[i].source.usesMicrophone { try await audio.startMonitoring() }
        state.sessions[i].status = .running
        resetStreak()
        try persist()
        syncConfiguration()
      } catch {
        audio.stopMonitoring()
        state.sessions[i].status = .paused
        message = error.localizedDescription
      }
    #endif
  }
  func endSession() async {
    #if os(iOS)
      guard let i = activeIndex else { return }
      state.sessions[i].status = .ended
      state.sessions[i].endedAt = Date()
      resetStreak()
      audio.stopMonitoring()
      audio.stopPlayback()
      save()
      syncConfiguration()
    #else
      if let id = remoteSessionID {
        state.mutedWatchSessions.append(id)
        state.mutedWatchSessions = Array(state.mutedWatchSessions.suffix(100))
        save()
      }
      remoteSessionID = nil
      motion.stopUpdates()
      haptics.cancel()
      watchStatus = "REM остановлен на часах"
      var p = WirePacket(kind: .acknowledgement)
      p.revision = state.configurationRevision
      p.message = watchStatus
      bridge.send(p)
    #endif
    await notifications.cancelPrefix("luma.rem.")
  }
  func preview() async {
    #if os(iOS)
      do {
        if state.signal.output.phoneEnabled { try audio.play(state.signal, clips: state.voices) }
        if state.signal.output.watchEnabled {
          var p = WirePacket(kind: .cue)
          p.signal = state.signal
          p.message = "preview"
          guard bridge.send(p) else { throw AppError.message("Для пробы откройте Luma на часах.") }
        }
        excludedUntil = Date().addingTimeInterval(120)
        resetStreak()
      } catch { message = error.localizedDescription }
    #else
      motion.stopUpdates()
      excludedUntil = Date().addingTimeInterval(Double(state.signal.count.rawValue) * 1.5 + 90)
      if let error = haptics.preview(count: state.signal.count.rawValue) { message = error }
    #endif
  }
  private func mergeHeart(_ values: [HeartSample], now: Date) -> [HeartSample] {
    var keys = Set<String>()
    return values.filter {
      $0.date > now.addingTimeInterval(-2700) && $0.date <= now
        && keys.insert("\($0.source):\($0.date.timeIntervalSince1970)").inserted
    }.sorted { $0.date < $1.date }
  }
  func refreshSensors() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    let now = Date()
    #if os(watchOS)
      guard remoteSessionID != nil, now >= excludedUntil else { return }
      if isForeground { motion.startUpdates() }
      do {
        heart = try await health.heartSamples(now: now)
        breath = try await health.breathSamples(now: now)
      } catch { return }
      var p = WirePacket(kind: .sensors)
      p.sessionID = remoteSessionID
      p.heart = heart
      p.breath = breath
      p.motion = motion.epochs
      bridge.send(p)
    #else
      if activeSession?.source.usesWatch == true
        || (activeSession == nil && archive.onboardingComplete)
      {
        do {
          heart = mergeHeart(heart + (try await health.heartSamples(now: now)), now: now)
          let b = try await health.breathSamples(now: now)
          breath = Array(
            (breath + b).filter { $0.date <= now && now.timeIntervalSince($0.date) < 3600 }.suffix(
              1000))
        } catch { /* Estimator rejects stale or missing measurements. */  }
      }
      guard let i = activeIndex, state.sessions[i].status == .running else { return }
      let session = state.sessions[i]
      guard now >= excludedUntil else {
        resetStreak()
        return
      }
      let r = MultimodalEstimator().evaluate(
        source: session.source, heart: heart, motion: remoteMotion, breath: breath, audio: acoustic,
        now: now, state: state)
      evidence = r.evidence
      if now.timeIntervalSince(state.sessions[i].samples.last?.date ?? .distantPast) >= 55 {
        state.sessions[i].samples.append(r.features)
        state.sessions[i].samples = Array(state.sessions[i].samples.suffix(1440))
      }
      let cue = state.episodeMemory.consume(r.evidence, now: now)
      var event: REMEpisode?
      if cue {
        let e = REMEpisode(date: now, features: r.features)
        state.sessions[i].episodes.append(e)
        event = e
      }
      guard save(), let e = event else { return }
      excludedUntil = now.addingTimeInterval(
        max(120, Double(session.signal.count.rawValue * session.signal.gapSeconds + 90)))
      if session.signal.output.phoneEnabled {
        do {
          if audio.monitoring || isForeground {
            try audio.play(session.signal, clips: state.voices)
            result(e.id, phone: "Воспроизведение запущено")
          } else {
            try await notifications.phoneCue(
              id: "luma.rem.\(e.id.uuidString).phone",
              sound: audio.soundURL(session.signal, clips: state.voices).lastPathComponent)
            guard activeSession?.id == session.id, activeSession?.status == .running else {
              await notifications.cancelPrefix("luma.rem.")
              return
            }
            result(e.id, phone: "Уведомление запланировано; звук не подтверждён")
          }
        } catch { result(e.id, phone: error.localizedDescription) }
      }
      guard activeSession?.id == session.id, activeSession?.status == .running else { return }
      if session.signal.output.watchEnabled {
        var p = WirePacket(kind: .cue)
        p.sessionID = session.id
        p.signal = session.signal
        p.episodeID = e.id
        result(e.id, watch: bridge.send(p) ? "Ожидаем ответ часов" : "Пропущен: часы недоступны")
      }
      save()
    #endif
  }
  func refreshSleep() async { sleep = (try? await health.sleepSegments(now: Date())) ?? [] }
  private func resetStreak() {
    state.episodeMemory.candidateSince = nil
    state.episodeMemory.exitSince = nil
    state.episodeMemory.lastEvaluation = nil
  }
  func saveFeedback(_ input: SessionFeedback) {
    var f = input
    f.note = String(f.note.prefix(12000))
    f.updatedAt = Date()
    guard state.sessions.contains(where: { $0.id == f.sessionID && $0.status == .ended }) else {
      return
    }
    if let i = state.feedback.firstIndex(where: { $0.id == f.id }) {
      state.feedback[i] = f
    } else {
      state.feedback.append(f)
    }
    save()
  }
  func deleteFeedback(_ id: UUID) {
    state.feedback.removeAll { $0.id == id }
    save()
  }
  func saveDream(_ input: DreamEntry) {
    var d = input
    d.text = String(d.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12000))
    guard !d.text.isEmpty else { return }
    if let i = archive.diary.firstIndex(where: { $0.id == d.id }) {
      archive.diary[i] = d
    } else {
      archive.diary.insert(d, at: 0)
    }
    save()
  }
  func deleteDream(id: UUID) {
    archive.diary.removeAll { $0.id == id }
    save()
  }
  func deleteHistory() {
    guard !hasPlan else {
      message = "Сначала завершите сеанс."
      return
    }
    archive.diary = []
    archive.records = []
    state.sessions = []
    state.feedback = []
    save()
  }
  #if os(iOS)
    func deleteVoice(_ id: UUID) {
      guard !hasPlan, !audio.recording, !state.alarms.contains(where: { $0.signal.voiceID == id })
      else {
        message = "Завершите сеанс и выберите другой звук в будильниках с этой дорожкой."
        return
      }
      guard let v = state.voices.first(where: { $0.id == id }) else { return }
      do {
        try FileManager.default.removeItem(
          at: audio.soundsDirectory().appendingPathComponent(v.filename))
        state.voices.removeAll { $0.id == id }
        if state.signal.voiceID == id { state.signal.voiceID = nil }
        try persist()
      } catch { message = error.localizedDescription }
    }
    private func handleAlarm(_ id: String) -> Bool {
      guard let a = occurrences.first(where: { id == $0.id + ".0" }), a.signal.output.phoneEnabled
      else { return false }
      if state.completedAlarmIDs.contains(a.id) { return true }
      guard abs(Date().timeIntervalSince(a.date)) < 5 else { return false }
      state.completedAlarmIDs.append(a.id)
      state.completedAlarmIDs = Array(state.completedAlarmIDs.suffix(512))
      guard save() else { return true }
      notifications.remove(ids: [id])
      do {
        try audio.play(a.signal, clips: state.voices)
        excludedUntil = Date().addingTimeInterval(120)
        resetStreak()
      } catch { message = error.localizedDescription }
      Task { await rebuildAlarms() }
      return true
    }
  #endif
  private func rebuildAlarms() async {
    if rebuilding {
      rebuildAgain = true
      return
    }
    rebuilding = true
    defer { rebuilding = false }
    repeat {
      rebuildAgain = false
      occurrences = AlarmPlanner.occurrences(
        state.alarms, after: Date().addingTimeInterval(2), limit: 80)
      do {
        queuedAlarmIDs = try await notifications.rebuildAlarms(occurrences) { s in
          #if os(iOS)
            return try audio.soundURL(s, clips: state.voices).lastPathComponent
          #else
            return ""
          #endif
        }
      } catch {
        queuedAlarmIDs = []
        message = error.localizedDescription
      }
    } while rebuildAgain
  }
  func syncConfiguration() {
    #if os(iOS)
      state.configurationRevision = Date()
      guard save() else { return }
      let ids = Set(AlarmPlanner.occurrences(state.alarms, after: Date(), limit: 80).map(\.alarmID))
      var p = WirePacket(kind: .configuration)
      p.revision = state.configurationRevision
      p.alarms = state.alarms.filter { ids.contains($0.id) }
      p.sessionID = activeSession?.status == .running ? activeSession?.id : nil
      p.source = activeSession?.source ?? state.source
      p.signal = activeSession?.signal ?? state.signal
      watchStatus = "Изменения ожидают подтверждения часов"
      bridge.send(p)
    #endif
  }
  private func result(_ id: UUID, phone: String? = nil, watch: String? = nil) {
    for i in state.sessions.indices {
      if let j = state.sessions[i].episodes.firstIndex(where: { $0.id == id }) {
        if let phone { state.sessions[i].episodes[j].phoneResult = phone }
        if let watch { state.sessions[i].episodes[j].watchResult = watch }
      }
    }
  }
  private func receive(_ p: WirePacket) {
    #if os(iOS)
      if p.kind == .sensors, let id = p.sessionID, id == activeSession?.id,
        activeSession?.status == .running, Date().timeIntervalSince(p.sentAt) < 90
      {
        heart = mergeHeart(heart + (p.heart ?? []), now: Date())
        remoteMotion = p.motion ?? []
        breath = Array((breath + (p.breath ?? [])).suffix(1000))
        Task { await refreshSensors() }
      } else if p.kind == .acknowledgement {
        if let id = p.episodeID {
          result(id, watch: p.message)
          save()
        } else if p.revision == state.configurationRevision {
          watchStatus = p.message ?? "Настройки подтверждены"
        }
      }
    #else
      if p.kind == .configuration, let rev = p.revision, rev >= state.configurationRevision {
        inbox = p
        guard !processing else { return }
        processing = true
        Task {
          while let next = inbox {
            inbox = nil
            await configure(next)
          }
          processing = false
        }
      } else if p.kind == .cue {
        Task { await receiveCue(p) }
      }
    #endif
  }
  #if os(watchOS)
    private func configure(_ p: WirePacket) async {
      guard let rev = p.revision, rev >= state.configurationRevision else { return }
      state.configurationRevision = rev
      state.alarms = p.alarms ?? []
      state.signal = p.signal?.validated() ?? SignalSettings()
      remoteSessionID = p.sessionID.flatMap { state.mutedWatchSessions.contains($0) ? nil : $0 }
      if remoteSessionID == nil {
        motion.stopUpdates()
        haptics.cancel()
        await notifications.cancelPrefix("luma.rem.")
      } else if isForeground {
        motion.startUpdates()
      }
      guard save() else { return }
      await rebuildAlarms()
      watchStatus = remoteSessionID == nil ? "Настройки получены" : "Сеанс подключён к iPhone"
      let total = state.alarms.filter { $0.enabled && $0.signal.output.watchEnabled }.count
      var ack = WirePacket(kind: .acknowledgement)
      ack.revision = rev
      ack.message =
        queuedAlarmIDs.count < total
        ? "На часах в очереди \(queuedAlarmIDs.count) из \(total) будильников"
        : "Настройки подтверждены часами"
      bridge.send(ack)
    }
    private func receiveCue(_ p: WirePacket) async {
      guard !state.processedEvents.contains(p.id), Date().timeIntervalSince(p.sentAt) <= 20,
        let s = p.signal, s.output.watchEnabled
      else { return }
      if p.message != "preview" {
        guard let id = p.sessionID, id == remoteSessionID else { return }
      }
      state.processedEvents.append(p.id)
      state.processedEvents = Array(state.processedEvents.suffix(256))
      guard save() else { return }
      var ack = WirePacket(kind: .acknowledgement)
      ack.episodeID = p.episodeID
      do {
        if p.message == "preview" {
          if let e = haptics.preview(count: s.count.rawValue) { throw AppError.message(e) }
          ack.message = "Проба запущена"
        } else {
          try await notifications.watchBurst(id: "luma.rem.\(p.id.uuidString)", signal: s)
          guard remoteSessionID == p.sessionID else {
            await notifications.cancelPrefix("luma.rem.")
            return
          }
          ack.message = "Запланировано на часах; вибрация не подтверждена"
        }
        motion.stopUpdates()
        excludedUntil = Date().addingTimeInterval(Double(s.count.rawValue * s.gapSeconds + 90))
      } catch { ack.message = error.localizedDescription }
      bridge.send(ack)
    }
  #endif
  @discardableResult private func save() -> Bool {
    do {
      try persist()
      return true
    } catch {
      message = error.localizedDescription
      return false
    }
  }
  private func persist() throws {
    guard let store, storageProblem == nil else {
      throw AppError.message(storageProblem ?? "Хранилище недоступно.")
    }
    archive.v2 = state
    try store.save(archive)
  }
}
