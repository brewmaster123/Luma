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
  @Published var message: String?
  @Published var showOnboarding = false
  @Published private(set) var researchStatus = "REM Lab · требуется запуск на часах"
  @Published private(set) var researchRunning = false
  @Published private(set) var researchStarting = false
  @Published private(set) var researchLastUpdate: Date?
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
    var watchSessionRunning: Bool { researchRunning }
    var watchSessionCanResume: Bool { offeredWatchSessionID != nil && remoteSessionID == nil }
    var researchNightAvailable: Bool { offeredWatchSessionID != nil && state.source.usesWatch }
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
    private let researchPhone = ResearchPhoneLink()
    private let researchLog = ResearchLog()
    private let legacyAlarms = LegacyAlarmCleanup()
    @Published private(set) var phoneNotificationSummary = "Проверяем уведомления…"
    @Published private(set) var phoneNotificationsReady = false
    @Published private(set) var phonePreviewRunning = false
    private var previewReset: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var attemptedPairedAlarms = Set<String>()
    private var pairedAlarmWake: Task<Void, Never>?
    private var pairedAlarmWakeID: String?
    private var pairedAlarmRuntimeStarting = false
    private var cueExclusions: [DateInterval] = []
    private var audioChanges: AnyCancellable?
  #else
    private let motion = MotionService()
    private let haptics = FiniteHaptics()
    private let researchWatch = ResearchWatchRuntime()
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
      state.useNotificationDelivery()
      #endif
      for i in state.sessions.indices where state.sessions[i].status == .running
        && state.sessions[i].watchResearch != true {
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
    #if os(watchOS)
      researchWatch.onPacket = { [weak self] p in self?.bridge.send(p) }
      researchWatch.onStatus = { [weak self] text, running in
        self?.researchStatus = text; self?.researchRunning = running
        self?.watchStatus = running ? "Ночной тест работает на часах" : text
      }
    #else
      researchPhone.onPacket = { [weak self] in self?.receive($0) }
      researchPhone.onStatus = { [weak self] in self?.researchStatus = $0 }
      if let s = activeSession, s.watchResearch == true { researchLog.start(s.id) }
    #endif
    health.onChange = { [weak self] in await self?.refreshSensors() }
    #if os(iOS)
      bridge.onCueFailure = { [weak self] packet in
        guard let self else { return }
        if let id = packet.episodeID {
          self.result(id, watch: "Пропущен: сообщение не дошло до часов"); self.save()
        } else if packet.id == self.previewGeneration {
          self.message = "Часы не получили пробу. Откройте Luma на Apple Watch и повторите."
        }
      }
      audioChanges = audio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
      // Phone-only cues and paired fallbacks keep their system sound.
      // Never start a second player in response to a notification delivery.
      notifications.onForeground = { [weak self] id in
        guard id.hasPrefix("luma.") else { return }
        self?.excludeCue(at: Date(), duration: 28)
      }
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
        guard let self else { return }
        self.pairedAlarmWake?.cancel(); self.pairedAlarmWake = nil; self.pairedAlarmWakeID = nil
        if self.activeSession?.watchResearch == true {
          self.researchStatus = "Аудио iPhone прервано; часы продолжают свой тест. \(text)"
          self.message = text
          return
        }
        if let i = self.activeIndex, self.state.sessions[i].status == .running {
          self.state.sessions[i].status = .paused
          self.resetStreak()
          self.save()
          self.syncConfiguration()
        }
        self.message = text
      }
    #endif
  }
  var activeIndex: Int? { state.sessions.firstIndex { $0.status != .ended } }
  var activeSession: NightSession? { activeIndex.map { state.sessions[$0] } }
  var hasPlan: Bool { activeIndex != nil }
  var stateTitle: String {
    if let s = activeSession, s.watchResearch == true, s.status == .running {
      return researchRunning && researchLastUpdate.map({ Date().timeIntervalSince($0) < 90 }) == true
        ? "Ночной тест на часах" : "Ждём данные Apple Watch"
    }
    return activeSession.map { $0.status == .paused ? "Сеанс на паузе" : "Наблюдаем за сном" }
      ?? "Ночь начинается с вас"
  }
  var researchLogURL: URL? {
    #if os(iOS)
      return researchLog.fileURL
    #else
      return researchWatch.logURL
    #endif
  }
  var personalizationCount: Int { Personalization.examples(state: state).count }
  var versionLabel: String {
    let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    let buildNumber = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
    return "Luma \(version) (\(buildNumber))"
  }
  var sortedAlarms: [LumaAlarm] { AlarmPlanner.sorted(state.alarms, after: alarmOrderDate) }
  #if os(iOS)
    var newAlarmDelivery: PhoneAlarmDelivery { .shortCue }
    var hasPairedAlarms: Bool {
      state.alarms.contains {
        $0.enabled && $0.signal.output == .both
          && $0.next(after: Date().addingTimeInterval(-PairedCuePolicy.maximumAlarmLateness)) != nil
      }
    }
    var pairedNightReady: Bool {
      audio.hasLiveInput && ((activeSession?.status == .running && activeSession?.signal.output == .both)
        || hasPairedAlarms)
    }
    var pairedNightSummary: String {
      if activeSession?.watchResearch == true {
        return "REM Lab · отдельный звук iPhone по команде часов. Проверьте пробой с погашенными экранами."
      }
      if pairedNightReady && hasPairedAlarms && activeSession?.signal.output != .both {
        return "Парный будильник готов · iPhone и Watch подадут независимые сигналы"
      }
      return pairedNightReady ? "Микрофон активен · звук iPhone напрямую"
        : "Для двух сигналов оставьте Luma запущенной перед сном"
    }
    private var livePhoneRuntimeAvailable: Bool { isForeground || audio.hasLiveInput || researchPhone.running }
    func refreshPhoneNotificationAccess() async {
      let access = await notifications.access()
      phoneNotificationSummary = access.summary
      phoneNotificationsReady = access.canSignal
    }
    /// Called on user action; Focus and the silent switch cannot be verified here.
    func preparePhoneSignals() async throws {
      try legacyAlarms.removeRemainingAlarms()
      do {
        try await notifications.requestPermission()
        try await notifications.checkPermission()
        await refreshPhoneNotificationAccess()
      } catch {
        await refreshPhoneNotificationAccess()
        throw error
      }
    }
    private func excludeCue(at date: Date, duration: TimeInterval) {
      let end = date.addingTimeInterval(duration + 90)
      cueExclusions.removeAll { $0.end < Date().addingTimeInterval(-900) }
      let interval = DateInterval(start: date.addingTimeInterval(-2), end: end)
      if !cueExclusions.contains(interval) { cueExclusions.append(interval) }
      audio.excludeFromDetection(from: date.addingTimeInterval(-2), until: end)
    }
    private var pairedAlarmRuntimeNeeded: Bool {
      let completed = Set(state.completedAlarmIDs).union(attemptedPairedAlarms)
      return PairedCuePolicy.needsPhoneRuntime(occurrences, now: Date(), completedIDs: completed)
    }
    /// A standalone iPhone+Watch alarm must keep a real iPhone audio session alive
    /// before the screen locks. This runtime is independent from REM detection.
    /// The same microphone engine is reference-counted with the REM owner so ending
    /// one feature never silently disables the other.
    private func refreshPairedAlarmRuntime() async {
      guard !pairedAlarmRuntimeStarting else { return }
      guard pairedAlarmRuntimeNeeded else {
        audio.stopMonitoring(owner: .pairedAlarm)
        armNextPairedAlarm()
        return
      }
      pairedAlarmRuntimeStarting = true
      defer { pairedAlarmRuntimeStarting = false }
      do {
        try await audio.startMonitoring(owner: .pairedAlarm)
        armNextPairedAlarm()
      } catch {
        pairedAlarmWake?.cancel(); pairedAlarmWake = nil; pairedAlarmWakeID = nil
        message = "Для будильника «iPhone + Watch» нужен активный фоновый аудиосеанс iPhone. \(error.localizedDescription)"
      }
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
      try? legacyAlarms.removeRemainingAlarms()
      #endif
      return
    }
    #if os(iOS)
    // Resume-paused sessions must not replay a previously queued REM cue or preview.
    await notifications.cancelPrefix("luma.rem.")
    await notifications.cancelPrefix("luma.preview.")
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
    await refreshPhoneNotificationAccess()
    #else
    await refreshWatchPermissions()
    #endif
    await rebuildAlarms()
    #if os(iOS)
    await refreshPairedAlarmRuntime()
    #endif
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
      // ResearchWatchRuntime owns its own motion stream and finite cue task.
      // A lowered wrist must not stop the active sensor experiment.
    #endif
  }
  private func tick() async {
    #if os(iOS)
    audio.checkInputLiveness()
    if activeSession?.watchResearch == true,
      researchLastUpdate.map({ Date().timeIntervalSince($0) > 90 }) == true {
      researchRunning = false
      researchStatus = "Нет свежего ответа часов · наблюдение не подтверждено"
    }
    if !rebuilding { playDuePairedAlarm() }
    #endif
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
    #if os(iOS)
    await refreshPhoneNotificationAccess()
    #endif
  }
  #if os(watchOS)
    func startResearchNight() async {
      guard let id = offeredWatchSessionID, state.source.usesWatch, !researchStarting else { return }
      researchStarting = true
      defer { researchStarting = false }
      state.mutedWatchSessions.removeAll { $0 == id }
      remoteSessionID = id
      guard save() else { return }
      do { try await researchWatch.start(id: id, signal: state.signal) }
      catch { message = error.localizedDescription }
    }
    func testResearchNight() { researchWatch.scheduleTest() }
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
    alarm.phoneDelivery = .shortCue
    if alarm.enabled && alarm.signal.output.phoneEnabled {
      do {
        _ = try audio.notificationSound(alarm.signal, clips: state.voices)
        try await preparePhoneSignals()
      } catch { message = error.localizedDescription; return false }
    }
    #endif
    let old = state
    if let i = state.alarms.firstIndex(where: { $0.id == alarm.id }) { state.alarms[i] = alarm }
    else { state.alarms.append(alarm) }
    guard save() else { state = old; return false }
    alarmOrderDate = Date(); await rebuildAlarms()
    #if os(iOS)
    await refreshPairedAlarmRuntime()
    #endif
    syncConfiguration()
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
    #if os(iOS)
    await refreshPairedAlarmRuntime()
    #endif
    syncConfiguration()
  }
  func beginSession() async {
    guard !busy, !hasPlan else { return }
    busy = true
    defer { busy = false }
    #if os(iOS)
      do {
        if state.source.usesWatch { try await researchPhone.authorize() }
        if state.source.usesWatch || state.signal.output.watchEnabled {
          guard watchInstalled else {
            throw AppError.message("Откройте Luma на часах или выберите «Только iPhone».")
          }
        }
        if state.signal.output.phoneEnabled {
          _ = try audio.notificationSound(state.signal, clips: state.voices)
          if state.source.usesWatch { try legacyAlarms.removeRemainingAlarms() }
          else { try await preparePhoneSignals() }
        }
        if !state.source.usesWatch && state.source.usesMicrophone { try await audio.startMonitoring(owner: .rem) }
        var s = NightSession(source: state.source.usesWatch ? .watch : state.source, signal: state.signal)
        s.watchResearch = state.source.usesWatch
        if s.watchResearch == true {
          researchLog.start(s.id); researchRunning = false; researchLastUpdate = nil
          researchStatus = "Откройте Luma на часах и нажмите «Начать REM · тест»"
        }
        state.sessions.insert(s, at: 0)
        state.episodeMemory = EpisodeMemory()
        acoustic = []
        excludedUntil = .distantPast
        do { try persist() } catch {
          state.sessions.removeAll { $0.id == s.id }
          audio.stopMonitoring(owner: .rem)
          throw error
        }
        syncConfiguration()
        armNextPairedAlarm()
        await refreshSensors()
      } catch { message = error.localizedDescription }
    #else
      message = "Начните ночной сеанс на iPhone."
    #endif
  }
  func resumeSession() async {
    guard let i = activeIndex, state.sessions[i].status == .paused, !busy else { return }
    let session = state.sessions[i]
    busy = true
    defer { busy = false }
    #if os(iOS)
      do {
        if session.source.usesWatch { try await researchPhone.authorize() }
        if session.signal.output.phoneEnabled {
          if session.source.usesWatch { try legacyAlarms.removeRemainingAlarms() }
          else { try await preparePhoneSignals() }
        }
        guard activeSession?.id == session.id, activeSession?.status == .paused else { return }
        if !session.source.usesWatch && session.source.usesMicrophone { try await audio.startMonitoring(owner: .rem) }
        guard let index = activeIndex, state.sessions[index].id == session.id,
          state.sessions[index].status == .paused else { audio.stopMonitoring(owner: .rem); return }
        state.sessions[index].status = .running
        state.sessions[index].watchResearch = session.source.usesWatch
        researchRunning = false; researchLastUpdate = nil
        researchStatus = "Возобновите ночной тест на Apple Watch"
        resetStreak(); try persist(); syncConfiguration(); armNextPairedAlarm()
      } catch {
        audio.stopMonitoring(owner: .rem)
        if let index = state.sessions.firstIndex(where: { $0.id == session.id && $0.status != .ended }) {
          state.sessions[index].status = .paused
        }
        message = error.localizedDescription
      }
    #endif
  }
  func endSession() async {
    #if os(iOS)
      guard let i = activeIndex else { return }
      if state.sessions[i].watchResearch == true {
        var p = WirePacket(kind: .researchStop); p.sessionID = state.sessions[i].id
        p.researchRunID = state.sessions[i].watchResearchRunID
        researchPhone.send(p); bridge.send(p)
        researchRunning = false; researchStatus = "Ночной тест завершён"
      }
      state.sessions[i].status = .ended
      state.sessions[i].endedAt = Date()
      previewGeneration = UUID()
      previewReset?.cancel(); phonePreviewRunning = false
      await notifications.cancelPrefix("luma.preview.")
      resetStreak()
      pairedAlarmWake?.cancel(); pairedAlarmWake = nil; pairedAlarmWakeID = nil
      audio.stopMonitoring(owner: .rem)
      audio.stopPlayback()
      save()
      syncConfiguration()
      await refreshPairedAlarmRuntime()
    #else
      guard let id = remoteSessionID, !watchSessionActionRunning else { return }
      watchSessionActionRunning = true
      defer { watchSessionActionRunning = false }
      researchWatch.stop()
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
      guard !phonePreviewRunning, !audio.recording else { return }
      phonePreviewRunning = true
      let signal = state.signal.validated()
      let generation = UUID(); previewGeneration = generation
      var cueDate: Date?
      var duration: TimeInterval = signal.output.watchEnabled ? Double(signal.count.rawValue) * 1.5 + 3 : 2
      do {
        if signal.output.phoneEnabled {
          try await preparePhoneSignals()
          let sound = try audio.notificationSound(signal, clips: state.voices)
          duration = max(duration, sound.duration + 3)
          await notifications.cancelPrefix("luma.preview.")
          guard generation == previewGeneration else { return }
          if signal.output == .both {
            cueDate = Date().addingTimeInterval(PairedCuePolicy.cueLeadTime)
            try audio.playCue(signal, clips: state.voices, at: cueDate, vibrate: state.vibratesOnPhone)
          } else {
            try await notifications.phoneCue(id: "luma.preview.\(generation.uuidString)",
              title: "Проба сигнала · Luma", sound: sound.name)
            guard generation == previewGeneration else {
              await notifications.cancelPrefix("luma.preview.\(generation.uuidString)"); return
            }
          }
          excludeCue(at: cueDate ?? Date().addingTimeInterval(2), duration: sound.duration)
        }
        if signal.output.watchEnabled {
          var p = WirePacket(kind: .cue)
          p.id = generation; p.signal = signal; p.cueDate = cueDate; p.message = "preview"
          if !bridge.send(p) { message = "Для пробы вибрации откройте Luma на часах." }
        }
        excludedUntil = Date().addingTimeInterval(120); resetStreak()
        // UI cooldown only; player and notification sounds finish independently.
        previewReset?.cancel()
        previewReset = Task { [weak self] in
          do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
          catch { return }
          if self?.previewGeneration == generation { self?.phonePreviewRunning = false }
        }
      } catch {
        if generation == previewGeneration { phonePreviewRunning = false; message = error.localizedDescription }
      }
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
      if state.source.usesWatch { return } // REM is evaluated locally by the live sensor runtime.
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
      if activeSession?.watchResearch == true {
        if researchLastUpdate.map({ now.timeIntervalSince($0) > 90 }) ?? true {
          evidence = .unavailable("Ожидаем свежие измерения и запуск ночного теста на часах")
        }
        return
      }
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
      guard now >= excludedUntil, !cueExclusions.contains(where: { $0.contains(now) }) else {
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
      var sharedCueDate: Date?
      if session.signal.output.phoneEnabled {
        do {
          try legacyAlarms.removeRemainingAlarms()
          let sound = try audio.notificationSound(session.signal, clips: state.voices)
          if session.signal.output == .both && livePhoneRuntimeAvailable {
            let start = Date().addingTimeInterval(PairedCuePolicy.cueLeadTime)
            try audio.playCue(session.signal, clips: state.voices, at: start, vibrate: state.vibratesOnPhone)
            sharedCueDate = start
            excludeCue(at: start, duration: sound.duration)
            result(e.id, phone: "Конечный звук iPhone подготовлен напрямую; слышимость не подтверждена")
          } else {
            let id = "luma.rem.\(e.id.uuidString)"
            try await notifications.phoneCue(id: id, title: "REM · Luma", sound: sound.name)
            guard activeSession?.id == session.id, activeSession?.status == .running else {
              await notifications.cancelPrefix(id); return
            }
            excludeCue(at: Date().addingTimeInterval(2), duration: sound.duration)
            result(e.id, phone: session.signal.output == .both
              ? "Резервное уведомление: совместный звук недоступен"
              : "Уведомление запланировано; звучание не подтверждено")
          }
        } catch { result(e.id, phone: error.localizedDescription) }
      }
      guard activeSession?.id == session.id, activeSession?.status == .running else { return }
      if session.signal.output.watchEnabled {
        var p = WirePacket(kind: .cue)
        p.sessionID = session.id
        p.signal = session.signal
        p.cueDate = sharedCueDate
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
  #if os(iOS)
    /// Arms the next paired alarm whenever the shared phone audio runtime is alive.
    /// That runtime may belong to REM, a standalone paired alarm, or both. The
    /// +5 s local notification remains the final fallback.
    private func armNextPairedAlarm() {
      pairedAlarmWake?.cancel()
      pairedAlarmWake = nil
      pairedAlarmWakeID = nil
      guard audio.monitoring, !audio.recording else { return }
      let now = Date()
      let completed = Set(state.completedAlarmIDs).union(attemptedPairedAlarms)
      guard let next = occurrences.filter({ occurrence in
        occurrence.signal.output == .both && queuedAlarmIDs.contains(occurrence.alarmID)
          && !completed.contains(occurrence.id)
          && occurrence.date >= now.addingTimeInterval(-PairedCuePolicy.maximumAlarmLateness)
      }).min(by: { $0.date < $1.date }) else { return }
      pairedAlarmWakeID = next.id
      let delay = max(0, next.date.timeIntervalSince(now))
      pairedAlarmWake = Task { @MainActor [weak self] in
        if delay > 0 {
          do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
          catch { return }
        }
        guard let self, !Task.isCancelled, self.pairedAlarmWakeID == next.id else { return }
        self.pairedAlarmWake = nil
        self.pairedAlarmWakeID = nil
        self.playDuePairedAlarm(preferredID: next.id)
      }
    }
    private func playDuePairedAlarm(preferredID: String? = nil) {
      guard livePhoneRuntimeAvailable, !audio.recording, !audio.playing else { return }
      let now = Date()
      let completed = Set(state.completedAlarmIDs).union(attemptedPairedAlarms)
      guard let a = occurrences.first(where: { occurrence in
        (preferredID == nil || occurrence.id == preferredID)
          && PairedCuePolicy.canPlayAlarm(occurrence, now: now, runtimeAvailable: true, completedIDs: completed)
          && queuedAlarmIDs.contains(occurrence.alarmID)
      }) else {
        if preferredID != nil { armNextPairedAlarm() }
        return
      }
      guard let current = state.alarms.first(where: { $0.id == a.alarmID && $0.enabled }),
        current.signal.validated() == a.signal,
        AlarmPlanner.occurrences([current], after: a.date.addingTimeInterval(-0.01), limit: 1).first?.id == a.id
      else { armNextPairedAlarm(); return }
      attemptedPairedAlarms.insert(a.id)
      if attemptedPairedAlarms.count > 512 { attemptedPairedAlarms = [a.id] }
      defer {
        armNextPairedAlarm()
        Task { @MainActor [weak self] in await self?.refreshPairedAlarmRuntime() }
      }
      do {
        let sound = try audio.notificationSound(a.signal, clips: state.voices)
        // PhoneAudio uses the already-active background playAndRecord session here,
        // so the iPhone sound is independent of notification forwarding to Apple Watch.
        try audio.playCue(a.signal, clips: state.voices, vibrate: state.vibratesOnPhone)
        let previous = state.completedAlarmIDs
        state.completedAlarmIDs.append(a.id)
        state.completedAlarmIDs = Array(state.completedAlarmIDs.suffix(512))
        guard save() else {
          state.completedAlarmIDs = previous; audio.stopPlayback(); return
        }
        // Watch has its own pre-scheduled local burst. Cancel the delayed phone
        // notification only after the direct iPhone player was accepted + persisted.
        notifications.completePhoneAlarm(a.id)
        excludeCue(at: now, duration: sound.duration)
        excludedUntil = now.addingTimeInterval(sound.duration + 90); resetStreak()
      } catch {
        message = "Звук iPhone не запущен: \(error.localizedDescription) Резервное уведомление сохранено."
      }
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
      let queued = state.alarms
      occurrences = AlarmPlanner.occurrences(
        queued, after: Date().addingTimeInterval(-60), limit: 80)
      do {
        #if os(iOS)
        try legacyAlarms.removeRemainingAlarms()
        #endif
        queuedAlarmIDs = try await notifications.rebuildAlarms(occurrences,
          completedPhoneIDs: Set(state.completedAlarmIDs)) { s in
          #if os(iOS)
            return try audio.notificationSound(s, clips: state.voices).name
          #else
            return ""
          #endif
        }
      } catch {
        queuedAlarmIDs = []
        message = error.localizedDescription
      }
      #if os(iOS)
      for occurrence in occurrences where queuedAlarmIDs.contains(occurrence.alarmID)
        && occurrence.signal.output.phoneEnabled {
        let duration = (try? audio.notificationSound(occurrence.signal, clips: state.voices).duration) ?? 28
        excludeCue(at: occurrence.date, duration: duration + (occurrence.signal.output == .both ? PairedCuePolicy.fallbackDelay : 0))
      }
      await refreshPhoneNotificationAccess()
      armNextPairedAlarm()
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
      p.alarms = state.alarms.filter { ids.contains($0.id) && $0.signal.output.watchEnabled }
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
  #if os(iOS)
    private func receiveResearch(_ p: WirePacket) {
      guard p.version == 2, let i = activeIndex, state.sessions[i].watchResearch == true,
        p.sessionID == state.sessions[i].id,
        (-2...120).contains(Date().timeIntervalSince(p.sentAt)) else { return }
      if state.sessions[i].status == .paused {
        // Only a newly user-started Watch run may resume a paused night.
        guard p.kind == .researchStatus, p.researchRunning == true,
          let run = p.researchRunID, run != state.sessions[i].watchResearchRunID,
          researchLastUpdate.map({ p.sentAt > $0 }) ?? true else { return }
        state.sessions[i].status = .running
      }
      guard state.sessions[i].status == .running else { return }
      let id = state.sessions[i].id
      if p.kind == .researchStatus {
        guard researchLastUpdate.map({ p.sentAt > $0 }) ?? true else { return }
        guard let run = p.researchRunID else { return }
        if state.sessions[i].watchResearchRunID != run {
          state.sessions[i].watchResearchRunID = run; save()
        }
        researchLastUpdate = p.sentAt; researchRunning = p.researchRunning == true
        researchStatus = p.message ?? "Сбор данных на часах"
        heart = mergeHeart(heart + (p.heart ?? []), now: Date())
        if let f = p.researchSample {
          evidence = REMEvidence(kind: f.score.map({ $0 >= 0.72 ? .candidate : .unlikely }) ?? .insufficient,
            heuristicScore: f.score, latestSampleAt: p.heart?.last?.date,
            explanation: researchStatus)
          if f.date.timeIntervalSince(state.sessions[i].samples.last?.date ?? .distantPast) >= 55 {
            state.sessions[i].samples.append(f)
            state.sessions[i].samples = Array(state.sessions[i].samples.suffix(1440))
            save()
          }
        }
        researchLog.append(p)
      } else if p.kind == .researchStopped {
        guard p.researchRunID == state.sessions[i].watchResearchRunID else { return }
        guard researchLastUpdate.map({ p.sentAt >= $0 }) ?? true else { return }
        researchRunning = false; researchStatus = p.message ?? "Сбор на часах остановлен"
        state.sessions[i].status = .paused
        audio.stopMonitoring(owner: .rem); audio.stopPlayback()
        researchLog.append(p); save()
      } else if p.kind == .researchReceipt {
        guard p.researchRunID == state.sessions[i].watchResearchRunID else { return }
        if let episode = p.episodeID { result(episode, watch: p.message) }
        researchLog.append(p); save()
      } else if p.kind == .researchCue {
        guard p.researchRunID == state.sessions[i].watchResearchRunID,
          p.researchRunID != nil else { return }
        guard ResearchCuePolicy.accepts(p, sessionID: id, now: Date(), processed: state.processedEvents),
          var episode = p.researchEpisode else { return }
        state.processedEvents.append(p.id)
        state.processedEvents = Array(state.processedEvents.suffix(256))
        episode.watchResult = "Решение принято на часах; конечная серия запрошена"
        if p.researchTest != true { state.sessions[i].episodes.append(episode) }
        // Reserve before any playback. The second transport must never replay this cue.
        guard save() else { return }
        researchLog.append(p)
        var receipt = WirePacket(kind: .researchReceipt)
        receipt.researchRunID = p.researchRunID
        receipt.sessionID = id; receipt.episodeID = episode.id; receipt.replyTo = p.id
        if state.sessions[i].signal.output.phoneEnabled {
          do {
            let signal = state.sessions[i].signal
            try audio.playCue(signal, clips: state.voices, at: p.cueDate, vibrate: state.vibratesOnPhone)
            excludeCue(at: p.cueDate ?? Date(), duration: 28)
            receipt.message = "iPhone: проигрыватель принял короткий сигнал без повтора"
          } catch {
            receipt.message = "iPhone: сигнал не запущен — \(error.localizedDescription)"
          }
        } else { receipt.message = "Звук iPhone выключен в настройках сеанса" }
        result(episode.id, phone: receipt.message)
        researchStatus = (p.researchTest == true ? "Проба. " : "") + (receipt.message ?? "")
        researchLog.append(receipt); save()
        researchPhone.send(receipt); bridge.send(receipt)
      }
    }
  #endif
  private func receive(_ p: WirePacket) {
    if [.researchStatus, .researchCue, .researchStopped, .researchStop, .researchReceipt].contains(p.kind) {
      #if os(iOS)
        receiveResearch(p)
      #else
        researchWatch.receive(p)
      #endif
      return
    }
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
        } else if p.replyTo == previewGeneration, Date().timeIntervalSince(p.sentAt) <= 20 {
          if let text = p.message, text != "Проба запущена" { message = "Apple Watch: " + text }
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
      state.source = p.source ?? .watch
      offeredWatchSessionID = p.sessionID
      if researchWatch.sessionID != nil && researchWatch.sessionID != p.sessionID {
        researchWatch.stop(reason: "Конфигурация ночного сеанса изменена")
      }
      remoteSessionID = p.sessionID.flatMap { state.mutedWatchSessions.contains($0) ? nil : $0 }
      if remoteSessionID == nil {
        motion.stopUpdates()
        haptics.cancel()
        await notifications.cancelPrefix("luma.rem.")
      } else if isForeground && !state.source.usesWatch {
        motion.startUpdates()
      }
      guard save() else { return }
      await rebuildAlarms()
      watchStatus = remoteSessionID != nil ? (researchRunning ? "Ночной тест работает" : "Нажмите «Начать REM · тест»")
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
      ack.replyTo = p.id
      do {
        if p.message == "preview" {
          if let date = p.cueDate, PairedCuePolicy.watchStart(requested: date, now: Date()) == nil {
            throw AppError.message("Проба опоздала и пропущена.")
          }
          if let e = haptics.preview(count: s.count.rawValue, at: p.cueDate) { throw AppError.message(e) }
          ack.message = "Проба запущена"
        } else {
          try await notifications.watchBurst(id: "luma.rem.\(p.id.uuidString)", signal: s, at: p.cueDate)
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
