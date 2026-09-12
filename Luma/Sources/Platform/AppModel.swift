import Combine
import Foundation

#if os(watchOS)
enum WatchPermissionAction: Equatable { case notifications, health }
#endif

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
  @Published private(set) var alarmOrderDate = Date()
  @Published private(set) var systemAlarmStatus = ""
  @Published var message: String?
  @Published var showOnboarding = false
  #if os(watchOS)
    @Published private(set) var watchPermissionAction: WatchPermissionAction?
    @Published private(set) var watchNotificationSummary = "Проверяем настройки…"
    @Published private(set) var watchNotificationNeedsRequest = true
    @Published private(set) var watchNotificationsReady = false
    @Published private(set) var watchHealthSummary = "Пульс, дыхание и сон"
    @Published private(set) var watchHealthRequestHandled = false
    @Published private(set) var watchHealthBackgroundWarning: String?
    @Published private(set) var watchPreviewRunning = false
    @Published private(set) var watchSessionActionRunning = false
    @Published private(set) var watchPreviewSummary = "Короткая вибрация на этих часах"
    private var offeredWatchSessionID: UUID?
    private var refreshingWatchPermissions = false
    private var watchPermissionRevision = 0
    private var enablingWatchHealthUpdates = false
    var watchSessionRunning: Bool { remoteSessionID != nil }
    var watchSessionCanResume: Bool { offeredWatchSessionID != nil && remoteSessionID == nil }
  #endif
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
    private let phoneAlarms = PhoneAlarmService()
    private var audioChanges: AnyCancellable?
  #else
    private let motion = MotionService()
    private let haptics = FiniteHaptics()
  #endif
  init() {
    #if os(watchOS)
      watchStatus = "Начните ночь в Luma на iPhone"
      haptics.onProgress = { [weak self] current, total in
        self?.watchPreviewRunning = true
        self?.watchPreviewSummary = current == 0 ? "Начинаем пробу…" : "Сигнал \(current) из \(total)"
      }
      haptics.onFinished = { [weak self] cancelled in
        guard let self else { return }
        self.watchPreviewRunning = false
        self.watchPreviewSummary = cancelled ? "Проба остановлена" : "Проба завершена"
        if self.isForeground && self.remoteSessionID != nil { self.motion.startUpdates() }
      }
    #endif
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
      state.signal = state.signal.validated()
      for i in state.alarms.indices { state.alarms[i].signal = state.alarms[i].signal.validated() }
      #if os(iOS)
      // The user explicitly requested a single AlarmKit route, including existing alarms.
      state.defaultPhoneDelivery = .systemAlarm
      for i in state.alarms.indices where state.alarms[i].signal.output.phoneEnabled {
        state.alarms[i].phoneDelivery = .systemAlarm
      }
      #endif
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
      audioChanges = audio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
      // Suppress any stale foreground notification left by a previous app version.
      notifications.onForeground = { _ in true }
      audio.isLumaSystemAlarm = { [weak self] in self?.phoneAlarms.hasAlertingAlarm == true }
      phoneAlarms.onWillSignal = { [weak self] in
        guard let self else { return }
        self.excludedUntil = Date().addingTimeInterval(120)
        self.resetStreak()
        self.audio.stopMonitoring()
        self.audio.stopPlayback()
        if self.audio.recording { self.audio.finishRecording() }
      }
      phoneAlarms.onSignalsFinished = { [weak self] in
        Task { @MainActor in
          guard let self, let session = self.activeSession, session.status == .running,
            session.source.usesMicrophone, !self.phoneAlarms.hasAlertingAlarm else { return }
          do {
            try await self.audio.startMonitoring()
            if self.activeSession?.id != session.id || self.activeSession?.status != .running {
              self.audio.stopMonitoring()
            }
          } catch {
            guard self.activeSession?.id == session.id, let i = self.activeIndex else { return }
            self.state.sessions[i].status = .paused; self.save(); self.syncConfiguration()
            self.message = "Не удалось возобновить микрофон после сигнала: \(error.localizedDescription)"
          }
        }
      }
      phoneAlarms.onStatus = { [weak self] id, status in
        self?.result(id, phone: status); self?.save()
      }
      phoneAlarms.onError = { [weak self] in self?.message = $0 }
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
        self.addSoundClip(clip)
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
  var versionLabel: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "Luma \(version) (\(build))"
  }
  var sortedAlarms: [LumaAlarm] { AlarmPlanner.sorted(state.alarms, after: alarmOrderDate) }
  #if os(iOS)
    var supportsSystemAlarms: Bool { phoneAlarms.supported }
    var newAlarmDelivery: PhoneAlarmDelivery { .systemAlarm }
    func setPhoneVibration(_ enabled: Bool) { let old = state; state.phoneVibration = enabled; if !save() { state = old } }
    func requestSystemAlarmAccess() async {
      do { try await phoneAlarms.requestPermission(); await rebuildAlarms() } catch { message = error.localizedDescription }
      systemAlarmStatus = phoneAlarms.authorizationDescription
    }
  #endif
  func start() async {
    guard !started else { return }
    started = true
    if migrated {
      await notifications.cancelPrefix("luma.")
      save()
    }
    if storageProblem != nil {
      await notifications.cancelPrefix("luma.")
      #if os(iOS)
      phoneAlarms.cancelAll()
      #endif
      return
    }
    #if os(iOS)
    // Remove legacy notification sounds before installing AlarmKit alarms; no double playback.
    await notifications.cancelPrefix("luma.")
    phoneAlarms.start()
    save()
    #endif
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
    alarmOrderDate = Date()
    #if os(iOS)
    phoneAlarms.refresh()
    #else
    await refreshWatchPermissions()
    #endif
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
    if Date().timeIntervalSince(alarmOrderDate) >= 30 { alarmOrderDate = Date() }
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
  #if os(watchOS)
    func refreshWatchPermissions() async {
      guard !refreshingWatchPermissions, watchPermissionAction == nil else { return }
      refreshingWatchPermissions = true
      defer { refreshingWatchPermissions = false }
      let revision = watchPermissionRevision
      let access = await notifications.access()
      guard watchPermissionAction == nil, revision == watchPermissionRevision else { return }
      applyWatchNotificationAccess(access)
      do {
        let request = try await health.readRequestState()
        guard watchPermissionAction == nil, revision == watchPermissionRevision else { return }
        switch request {
        case .needed:
          watchHealthRequestHandled = false; watchHealthSummary = "Нужно разрешение на чтение"
        case .handled:
          watchHealthRequestHandled = true; watchHealthSummary = "Запрос уже обработан"
        case .unavailable:
          watchHealthSummary = "«Здоровье» недоступно"
        case .unknown:
          watchHealthSummary = "Проверьте доступ к данным"
        }
      } catch {
        if revision == watchPermissionRevision { watchHealthSummary = "Не удалось проверить доступ" }
      }
    }
    private func applyWatchNotificationAccess(_ access: NotificationService.Access) {
      watchNotificationNeedsRequest = access.needsRequest
      watchNotificationsReady = access.canSignal
      watchNotificationSummary = access.summary
    }
    func requestWatchNotifications() async {
      guard watchPermissionAction == nil else { return }
      watchPermissionRevision += 1
      watchPermissionAction = .notifications
      watchNotificationSummary = "Проверяем разрешение…"
      defer { watchPermissionAction = nil }
      do {
        try await notifications.requestPermission()
        let access = await notifications.access()
        applyWatchNotificationAccess(access)
        if access.canSignal {
          message = "Уведомления разрешены. Можно проверить вибрацию кнопкой «Проба сигнала». Ночь запускается в Luma на iPhone."
          await rebuildAlarms()
        } else { showWatchNotificationHelp() }
      } catch {
        applyWatchNotificationAccess(await notifications.access())
        message = error.localizedDescription + "\n\nЕсли системное окно не появляется, проверьте Luma в приложении Watch на iPhone → Уведомления."
      }
    }
    func requestWatchHealth() async {
      guard watchPermissionAction == nil else { return }
      watchPermissionRevision += 1
      watchPermissionAction = .health
      watchHealthSummary = "Ответьте на запрос на часах…"
      defer { watchPermissionAction = nil }
      do {
        try await health.requestReadAccess()
        completeIntroduction()
        watchHealthRequestHandled = true
        watchHealthSummary = "Запрос обработан"
        showWatchHealthHelp()
        // Background delivery is independent of completing the permission sheet.
        // Its failure must not leave the permission button waiting indefinitely.
        enableWatchHealthUpdates()
      } catch {
        watchHealthSummary = "Не удалось завершить запрос"
        message = error.localizedDescription
      }
    }
    private func enableWatchHealthUpdates() {
      guard !enablingWatchHealthUpdates else { return }
      enablingWatchHealthUpdates = true
      watchHealthBackgroundWarning = nil
      Task { [weak self] in
        guard let self else { return }
        defer { self.enablingWatchHealthUpdates = false }
        do { try await self.health.beginObserving() }
        catch { self.watchHealthBackgroundWarning = "Фоновые обновления недоступны: \(error.localizedDescription)" }
        await self.refreshSensors()
      }
    }
    func showWatchHealthHelp() {
      message = "Запрос обработан. Если окно не появилось, выбор уже сделан.\n\nИзменить доступ на iPhone: «Здоровье» → профиль → «Приложения» → Luma. Проверьте чтение пульса, дыхания и сна.\n\nЗатем начните ночь в Luma на iPhone."
    }
    func showWatchNotificationHelp() {
      message = "На iPhone откройте Watch → Уведомления → Luma и проверьте разрешение уведомлений. При ранее выбранном отказе системное окно не появится снова.\n\nДля пробы вибрации оставьте Luma открытой на часах."
    }
    func stopWatchPreview() { haptics.cancel() }
    func resumeWatchSession() async {
      guard let id = offeredWatchSessionID, remoteSessionID == nil, !watchSessionActionRunning else { return }
      watchSessionActionRunning = true
      defer { watchSessionActionRunning = false }
      let old = state
      state.mutedWatchSessions.removeAll { $0 == id }
      guard save() else { state = old; return }
      remoteSessionID = id
      watchStatus = "Сеанс подключён к iPhone"
      if isForeground { motion.startUpdates() }
      var packet = WirePacket(kind: .acknowledgement)
      packet.revision = state.configurationRevision
      packet.message = "Наблюдение на часах возобновлено"
      bridge.send(packet)
      await refreshSensors()
    }
  #endif
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
  @discardableResult func saveAlarm(_ input: LumaAlarm) async -> Bool {
    var alarm = input
    alarm.title = String(alarm.title.prefix(80)); alarm.signal = alarm.signal.validated()
    #if os(iOS)
    alarm.phoneDelivery = .systemAlarm
    if alarm.enabled && alarm.signal.output.phoneEnabled {
      do {
        _ = try audio.alarmSound(alarm.signal, clips: state.voices)
        try await phoneAlarms.requestPermission()
      } catch { message = error.localizedDescription; return false }
    }
    #endif
    let old = state
    if let i = state.alarms.firstIndex(where: { $0.id == alarm.id }) { state.alarms[i] = alarm }
    else { state.alarms.append(alarm) }
    guard save() else { state = old; return false }
    alarmOrderDate = Date(); await rebuildAlarms(); syncConfiguration()
    return true
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
    let old = state
    state.alarms.removeAll { $0.id == id }
    guard save() else { state = old; return }
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
          _ = try audio.alarmSound(state.signal, clips: state.voices)
          try await phoneAlarms.requestPermission()
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
        if state.sessions[i].signal.output.phoneEnabled { try await phoneAlarms.requestPermission() }
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
      phoneAlarms.cancelSession(state.sessions[i].id)
      phoneAlarms.cancelPreviews()
      resetStreak()
      audio.stopMonitoring()
      audio.stopPlayback()
      save()
      syncConfiguration()
    #else
      guard let id = remoteSessionID, !watchSessionActionRunning else { return }
      watchSessionActionRunning = true
      defer { watchSessionActionRunning = false }
      state.mutedWatchSessions.append(id)
      state.mutedWatchSessions = Array(state.mutedWatchSessions.suffix(100))
      save()
      remoteSessionID = nil
      motion.stopUpdates()
      haptics.cancel()
      watchStatus = "Сеанс на часах приостановлен"
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
        if state.signal.output.phoneEnabled {
          phoneAlarms.cancelPreviews()
          try await phoneAlarms.cue(id: UUID(), sessionID: nil, title: "Проба сигнала · Luma",
            sound: audio.alarmSound(state.signal, clips: state.voices))
        }
        if state.signal.output.watchEnabled && !state.signal.output.phoneEnabled {
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
          try await phoneAlarms.cue(id: e.id, sessionID: session.id, title: "REM · Luma",
            sound: audio.alarmSound(session.signal, clips: state.voices))
          if session.signal.output.watchEnabled {
            result(e.id, watch: "Отображением сигнала AlarmKit на Apple Watch управляет iOS")
          }
        } catch { result(e.id, phone: error.localizedDescription) }
      }
      guard activeSession?.id == session.id, activeSession?.status == .running else { return }
      if session.signal.output.watchEnabled && !session.signal.output.phoneEnabled {
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
  @discardableResult func saveFeedback(_ input: SessionFeedback) -> Bool {
    var feedback = input; feedback.note = String(feedback.note.prefix(12000)); feedback.updatedAt = Date()
    guard state.sessions.contains(where: { $0.id == feedback.sessionID && $0.status == .ended }) else { return false }
    let old = state
    if let i = state.feedback.firstIndex(where: { $0.id == feedback.id }) { state.feedback[i] = feedback }
    else { state.feedback.append(feedback) }
    guard save() else { state = old; return false }
    removeUnreferencedJournalAudio(old.feedback.flatMap { $0.voiceNotes ?? [] })
    return true
  }
  @discardableResult func deleteFeedback(_ id: UUID) -> Bool {
    let old = state; state.feedback.removeAll { $0.id == id }
    guard save() else { state = old; return false }
    removeUnreferencedJournalAudio(old.feedback.flatMap { $0.voiceNotes ?? [] }); return true
  }
  @discardableResult func saveDream(_ input: DreamEntry) -> Bool {
    var dream = input; dream.text = String(dream.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12000))
    guard dream.hasContent else { return false }
    let old = archive
    if let i = archive.diary.firstIndex(where: { $0.id == dream.id }) { archive.diary[i] = dream }
    else { archive.diary.insert(dream, at: 0) }
    guard save() else { archive = old; return false }
    removeUnreferencedJournalAudio(old.diary.flatMap { $0.voiceNotes ?? [] }); return true
  }
  @discardableResult func deleteDream(id: UUID) -> Bool {
    let old = archive; archive.diary.removeAll { $0.id == id }
    guard save() else { archive = old; return false }
    removeUnreferencedJournalAudio(old.diary.flatMap { $0.voiceNotes ?? [] }); return true
  }
  func removeUnreferencedJournalAudio(_ candidates: [JournalVoice]) {
    #if os(iOS)
    let used = Set((archive.diary.flatMap { $0.voiceNotes ?? [] } + state.feedback.flatMap { $0.voiceNotes ?? [] }).map(\.id))
    for voice in candidates where !used.contains(voice.id) {
      guard let url = try? audio.journalURL(voice) else { continue }
      if audio.playbackID == voice.id { audio.stopPlayback() }
      do { try FileManager.default.removeItem(at: url) } catch { message = error.localizedDescription }
    }
    #endif
  }
  func deleteHistory() {
    guard !hasPlan else { message = "Сначала завершите сеанс."; return }
    let oldArchive = archive, oldState = state
    let clips = archive.diary.flatMap { $0.voiceNotes ?? [] } + state.feedback.flatMap { $0.voiceNotes ?? [] }
    archive.diary = []; archive.records = []; state.sessions = []; state.feedback = []
    guard save() else { archive = oldArchive; state = oldState; return }
    removeUnreferencedJournalAudio(clips)
  }
  #if os(iOS)
    private func addSoundClip(_ clip: VoiceClip) {
      let old = state
      state.voices.append(clip); state.signal.voiceID = clip.id
      if !save() {
        state = old
        if let url = try? audio.soundURL({ var s = SignalSettings(); s.voiceID = clip.id; return s }(), clips: [clip]) {
          try? FileManager.default.removeItem(at: url)
        }
      }
    }
    func importMelody(_ url: URL) async {
      guard !busy, !hasPlan, !audio.recording else { message = "Добавляйте мелодии между сеансами."; return }
      busy = true; defer { busy = false }
      do { addSoundClip(try await audio.importSound(from: url)) } catch { message = error.localizedDescription }
    }
    func previewClip(_ clip: VoiceClip) {
      guard !audio.recording, !hasPlan else { return }
      do { var s = SignalSettings(); s.voiceID = clip.id; try audio.play(s, clips: state.voices) }
      catch { message = error.localizedDescription }
    }
    func deleteVoice(_ id: UUID) {
      guard !hasPlan, !busy, !audio.recording, !state.alarms.contains(where: { $0.signal.voiceID == id }) else {
        message = "Завершите сеанс и выберите другой звук в будильниках с этой дорожкой."; return
      }
      guard let clip = state.voices.first(where: { $0.id == id }) else { return }
      do {
        var signal = SignalSettings(); signal.voiceID = id
        let url = try audio.soundURL(signal, clips: [clip]), old = state
        state.voices.removeAll { $0.id == id }; if state.signal.voiceID == id { state.signal.voiceID = nil }
        guard save() else { state = old; return }
        if audio.playbackID == id { audio.stopPlayback() }
        try FileManager.default.removeItem(at: url)
      } catch { message = error.localizedDescription }
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
      #if os(iOS)
      let queued = state.alarms.filter { !$0.signal.output.phoneEnabled }
      #else
      let queued = state.alarms
      #endif
      occurrences = AlarmPlanner.occurrences(
        queued, after: Date().addingTimeInterval(2), limit: 80)
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
      #if os(iOS)
      let system = await phoneAlarms.rebuild(state.alarms) { try audio.alarmSound($0, clips: state.voices) }
      queuedAlarmIDs.formUnion(system.scheduled)
      systemAlarmStatus = phoneAlarms.authorizationDescription
      if let warning = system.warning { message = warning }
      #endif
    } while rebuildAgain
  }
  func syncConfiguration() {
    #if os(iOS)
      state.configurationRevision = Date()
      guard save() else { return }
      let ids = Set(AlarmPlanner.occurrences(state.alarms, after: Date(), limit: 80).map(\.alarmID))
      var p = WirePacket(kind: .configuration)
      p.revision = state.configurationRevision
      p.alarms = state.alarms.filter { ids.contains($0.id) && !$0.signal.output.phoneEnabled }
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
      offeredWatchSessionID = p.sessionID
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
      watchStatus = remoteSessionID != nil ? "Сеанс подключён к iPhone"
        : (offeredWatchSessionID == nil ? "Начните ночь в Luma на iPhone" : "Сеанс на часах приостановлен")
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
