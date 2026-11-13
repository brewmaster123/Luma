import Combine
import Foundation

/// iPhone state, AlarmKit deadlines, real night-audio runtime and Watch plan.
@MainActor final class AppModel: ObservableObject {
  @Published private(set) var archive = AppArchive()
  @Published private(set) var state = LumaState()
  @Published private(set) var sleep: [SleepSegment] = []
  @Published private(set) var busy = false
  @Published private(set) var isForeground = false
  @Published private(set) var queuedAlarmIDs = Set<UUID>()
  @Published private(set) var alarmOrderDate = Date()
  @Published private(set) var alarmPermissionSummary = "Проверяем системные будильники…"
  @Published private(set) var alarmPermissionReady = false
  @Published private(set) var alarmStopSeconds = AlarmSignalDuration.defaultSeconds
  @Published var message: String?
  @Published var showOnboarding = false
  @Published var showSignalMigration = false
  let audio = PhoneAudio()
  let systemAlarms = SystemAlarmService()
  let nightAudio = NightAudio()
  let watchLink = WatchCueLink()
  private var nightAudioChanges: AnyCancellable?
  private var watchChanges: AnyCancellable?
  private let health = HealthService()
  private var store: LocalStore?
  private var storageProblem: String?
  private var started = false
  private var rebuilding = false
  private var rebuildAgain = false
  private var timer: Timer?
  private var lastSystemRefill = Date.distantPast
  private var lastSystemQueueError: String?
  private var audioChanges: AnyCancellable?
  private var systemAlarmChanges: AnyCancellable?

  init() {
    alarmStopSeconds = AlarmSignalDuration.validated(
      UserDefaults.standard.object(forKey: AlarmSignalDuration.preferenceKey) as? Int)
    do {
      let local = try LocalStore()
      archive = try local.load()
      store = local
      if let saved = archive.v2 { state = saved }
      else {
        // Preserve a future, explicitly armed time alarm from the oldest format.
        if let plan = archive.plan, plan.windowStart > Date(),
          plan.settings.mode == .scheduled, archive.planState == .armed {
          var alarm = LumaAlarm(); alarm.onceAt = plan.windowStart
          alarm.hour = plan.settings.startHour; alarm.minute = plan.settings.startMinute
          state.alarms = [alarm]
        }
      }
      state.migrateToiPhoneOnly()
    } catch { storageProblem = error.localizedDescription; message = error.localizedDescription }
    showOnboarding = !archive.onboardingComplete
    audioChanges = audio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    systemAlarmChanges = systemAlarms.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    nightAudioChanges = nightAudio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    watchChanges = watchLink.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    systemAlarms.runtimeReady = { [weak self] in self?.nightAudio.ready == true }
    systemAlarms.onAlertObserved = { [weak self] deadline in self?.nightAudio.protectStopWindow(until: deadline) }
    systemAlarms.onQueueChanged = { [weak self] ledger in
      let owners = Set(ledger.cancelledOwners ?? [])
      self?.watchLink.publish(ledger.cancelAllRequested == true ? []
        : ledger.records.filter { !owners.contains($0.ownerID) })
    }
    nightAudio.onCheckAlarms = { [weak self] in
      guard let self else { return }
      self.nightAudio.protectStopWindow(until: self.systemAlarms.currentStopDeadline)
      try? await self.systemAlarms.refresh()
    }
    nightAudio.onStopRequested = { [weak self] in
      guard let self else { return }
      do { try await self.systemAlarms.disarmForRuntimeLoss() }
      catch { self.message = "Отмена системной очереди не подтверждена: " + error.localizedDescription; throw error }
      self.watchLink.publish(self.systemAlarms.ledger.records)
    }
    audio.externalPlaybackActive = { [weak self] in self?.nightAudio.enabled == true }
    audio.onClip = { [weak self] clip in self?.addSoundClip(clip) }
    audio.onError = { [weak self] text in self?.message = text }
    audio.onInterruption = { [weak self] text in self?.message = text }
  }
  var hasPlan: Bool { indirectRunning }
  @discardableResult func setAlarmStopSeconds(_ seconds: Int) -> Bool {
    guard AlarmSignalDuration.range.contains(seconds), !busy else { return false }
    do {
      try systemAlarms.setFutureStopDuration(seconds)
      UserDefaults.standard.set(seconds, forKey: AlarmSignalDuration.preferenceKey)
      alarmStopSeconds = seconds
      return true
    } catch { message = error.localizedDescription; return false }
  }
  var indirectRunning: Bool { systemAlarms.indirectSession != nil }
  var stateTitle: String { "Ночь начинается с вас" }
  var sortedAlarms: [LumaAlarm] { AlarmPlanner.sorted(state.alarms, after: alarmOrderDate) }
  var indirectIntervalMinutes: Int {
    (state.indirectMethod ?? IndirectMethodSettings()).validated.intervalMinutes
  }
  var newAlarmDelivery: PhoneAlarmDelivery { .systemAlarm }
  var versionLabel: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "Luma \(version) (\(build))"
  }
  private var systemAlarmOwners: Set<UUID> {
    var ids = Set(state.alarms.filter(\.enabled).map(\.id))
    if let session = systemAlarms.indirectSession { ids.insert(session.id) }
    return ids
  }
  func start() async {
    guard !started else { return }; started = true
    // A cold launch has no live sleep-audio runtime; remove unsafe old IDs.
    do {
      try await systemAlarms.bootstrap()
      if systemAlarms.authorized, !nightAudio.ready { try await systemAlarms.disarmForRuntimeLoss() }
      watchLink.publish(systemAlarms.ledger.records)
    }
    catch { message = error.localizedDescription }
    startTicker()
    guard storageProblem == nil, save() else { return }
    await rebuildAlarms()
    if systemAlarms.supported, !systemAlarms.acceptedLimitations, !showOnboarding,
      indirectRunning || state.alarms.contains(where: { $0.next(after: Date()) != nil }) {
      showSignalMigration = true
    }
  }
  func resume() async {
    isForeground = true; alarmOrderDate = Date()
    await refreshAlarmAccess()
    guard storageProblem == nil else { return }
    await rebuildAlarms()
    if archive.onboardingComplete { await refreshSleep() }
  }
  func suspend() { isForeground = false; systemAlarms.appBecameInactive() }
  private func startTicker() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.tick() }
    }
  }
  private func tick() async {
    await systemAlarms.poll()
    if Date().timeIntervalSince(alarmOrderDate) >= 30 { alarmOrderDate = Date() }
    if storageProblem == nil, nightAudio.ready, !rebuilding, !systemAlarms.preparing, systemAlarms.acceptedLimitations,
      Date().timeIntervalSince(lastSystemRefill) >= 60 {
      lastSystemRefill = Date(); await rebuildAlarms()
    }
  }
  func completeIntroduction() {
    archive.onboardingComplete = true; showOnboarding = false; save()
  }
  func refreshAlarmAccess() async {
    do { try await systemAlarms.bootstrap() } catch { message = error.localizedDescription }
    alarmPermissionSummary = systemAlarms.summary
    alarmPermissionReady = systemAlarms.authorized && systemAlarms.acceptedLimitations
  }
  func connectHealth() async {
    guard !busy else { return }; busy = true; defer { busy = false }
    do { try await health.requestReadAccess(); await refreshSleep() }
    catch { message = error.localizedDescription }
  }
  func refreshSleep() async { sleep = (try? await health.sleepSegments(now: Date())) ?? [] }
  @discardableResult func setIndirectInterval(_ minutes: Int) async -> Bool {
    guard !busy else { return false }
    if indirectRunning {
      message = "Завершите непрямой метод перед изменением интервала."
      return false
    }
    let previous = state.indirectMethod
    state.indirectMethod = IndirectMethodSettings(intervalMinutes: minutes)
    guard save() else { state.indirectMethod = previous; return false }
    return true
  }

  func requestIndirectMethodStart() async {
    guard !busy, !indirectRunning else { return }
    busy = true
    defer { busy = false }
    do {
      try await preparePhoneSignals()
      let signal = state.signal.systemAlarmSignal
      let session = IndirectAlarmSession(settings: .init(intervalMinutes: indirectIntervalMinutes), signal: signal)
      _ = try AlarmKitSoundBuilder.prepare(source: audio.soundURL(session.signal, clips: state.voices))
      try systemAlarms.setIndirect(session)
      await rebuildAlarms()
      guard !systemAlarms.indirectRecords.isEmpty else {
        try await systemAlarms.stopIndirect()
        throw AppError.message(message ?? "AlarmKit не принял сигналы. Режим не запущен.")
      }

    } catch { message = error.localizedDescription }
  }

  func stopIndirectMethod() async {
    guard !busy else { return }
    busy = true; defer { busy = false }
    do { try await systemAlarms.stopIndirect() }
    catch { message = "Не все сигналы отменены: \(error.localizedDescription)" }
  }

  func stopAllSystemAlarms() async {
    guard !busy else { return }
    busy = true; defer { busy = false }
    let previous = state
    for i in state.alarms.indices { state.alarms[i].enabled = false }
    guard save() else { state = previous; return }
    do {
      try await systemAlarms.stopAll()
      queuedAlarmIDs = []
    } catch { message = error.localizedDescription }
  }

  func testSystemAlarm(after seconds: TimeInterval = 60) async {
    guard !busy, !systemAlarms.preparing else { return }
    busy = true; defer { busy = false }
    do {
      try await preparePhoneSignals()
      try await systemAlarms.cancelProbes()
      let id = UUID(), date = Date().addingTimeInterval(max(3, min(60, seconds)))
      let signal = state.signal.systemAlarmSignal
      let request = SystemAlarmRequest(key: "luma.probe.\(id.uuidString)", ownerID: id,
        kind: .probe, fireAt: date, title: "Проба AlarmKit · Luma",
        source: try audio.soundURL(signal, clips: state.voices), stopAfterSeconds: alarmStopSeconds)
      let requests = try systemAlarmRequests() + [request]
      let queued = try await systemAlarms.reconcile(requests, activeOwners: systemAlarmOwners.union([id]))
      guard queued.contains(id) else {
        throw AppError.message("Пробный сигнал не поставлен. Повторите пробу с задержкой 60 секунд.")
      }
      message = "Проба через \(Int(max(3, min(60, seconds)))) сек. Остановка AlarmKit через \(alarmStopSeconds) сек. Заблокируйте iPhone и проверьте звук."
    } catch { message = error.localizedDescription }
  }

  func preparePhoneSignals(acceptLimitations: Bool = false) async throws {
    guard !audio.recording, !audio.playing else {
      throw AppError.message("Завершите запись или прослушивание перед ночным режимом.")
    }
    try await systemAlarms.authorize(acceptLimitations: acceptLimitations)
    try nightAudio.start()
    alarmPermissionSummary = systemAlarms.summary
    alarmPermissionReady = true
    // Resume the migrated cadence and saved alarms after the AlarmKit WAV
    // experiment has been explained. Do not require recreating an interval session.
    await rebuildAlarms()
  }

  func enableNightAudio() async {
    do { try await preparePhoneSignals() } catch { message = error.localizedDescription }
  }
  func stopNightAudio() async { await nightAudio.stopSafely() }

  func updateSignal(_ s: SignalSettings) {
    state.signal = s.systemAlarmSignal
    save()
  }

  @discardableResult func saveAlarm(_ input: LumaAlarm) async -> Bool {
    guard !busy else { return false }
    busy = true
    defer { busy = false }
    var alarm = input
    alarm.title = String(alarm.title.prefix(80)); alarm.signal = alarm.signal.systemAlarmSignal
    alarm.phoneDelivery = .systemAlarm
    alarm.signal.melodySeconds = 4
    if alarm.enabled {
      do {
        _ = try AlarmKitSoundBuilder.prepare(source: audio.soundURL(alarm.signal, clips: state.voices))
        try await preparePhoneSignals()
        try systemAlarms.resetHandled(ownerID: alarm.id)
      } catch { message = error.localizedDescription; return false }
    }
    let old = state
    if let i = state.alarms.firstIndex(where: { $0.id == alarm.id }) { state.alarms[i] = alarm }
    else { state.alarms.append(alarm) }
    guard save() else { state = old; return false }
    if old.alarms.first(where: { $0.id == alarm.id }) != alarm {
      do { try await systemAlarms.cancelOwner(alarm.id) }
      catch {
        state = old; save()
        message = "Не удалось отменить прежние сигналы будильника: \(error.localizedDescription)"
        await rebuildAlarms()
        return false
      }
    }
    alarmOrderDate = Date(); await rebuildAlarms()
    if alarm.enabled && alarm.next(after: Date()) != nil,
      !queuedAlarmIDs.contains(alarm.id) {
      let schedulingError = message ?? "AlarmKit не принял будильник."
      state = old; save(); await rebuildAlarms()
      message = schedulingError
      return false
    }

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
    guard !busy else { return }
    busy = true
    defer { busy = false }
    let old = state
    state.alarms.removeAll { $0.id == id }
    guard save() else { state = old; return }
    do { try await systemAlarms.cancelOwner(id) }
    catch { message = "Отмена удалённого будильника не завершена: \(error.localizedDescription)" }
    await rebuildAlarms()

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
    let used = Set((archive.diary.flatMap { $0.voiceNotes ?? [] } + state.feedback.flatMap { $0.voiceNotes ?? [] }).map(\.id))
    for voice in candidates where !used.contains(voice.id) {
      guard let url = try? audio.journalURL(voice) else { continue }
      if audio.playbackID == voice.id { audio.stopPlayback() }
      do { try FileManager.default.removeItem(at: url) } catch { message = error.localizedDescription }
    }
  }

  func deleteHistory() {
    guard !hasPlan else { message = "Сначала завершите сеанс."; return }
    let oldArchive = archive, oldState = state
    let clips = archive.diary.flatMap { $0.voiceNotes ?? [] } + state.feedback.flatMap { $0.voiceNotes ?? [] }
    archive.diary = []; archive.records = []; state.sessions = []; state.feedback = []
    guard save() else { archive = oldArchive; state = oldState; return }
    removeUnreferencedJournalAudio(clips)
  }

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
    guard !busy, !hasPlan, !nightAudio.enabled, !audio.recording else { message = "Добавляйте мелодии между сеансами."; return }
    busy = true; defer { busy = false }
    do { addSoundClip(try await audio.importSound(from: url)) } catch { message = error.localizedDescription }
  }

  func previewClip(_ clip: VoiceClip) {
    guard !audio.recording, !hasPlan else { return }
    do { var s = SignalSettings(); s.voiceID = clip.id; try audio.play(s, clips: state.voices) }
    catch { message = error.localizedDescription }
  }

  func deleteVoice(_ id: UUID) {
    guard !hasPlan, !busy, !audio.recording,
      systemAlarms.indirectSession?.signal.voiceID != id,
      !state.alarms.contains(where: { $0.signal.voiceID == id }) else {
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

  private func systemAlarmRequests() throws -> [SystemAlarmRequest] {
    let now = Date()
    var result = try AlarmPlanner.occurrences(state.alarms, after: now, limit: 80)
      .map { a -> SystemAlarmRequest in
        var signal = a.signal; signal.melodySeconds = 4
        return SystemAlarmRequest(key: a.id, ownerID: a.alarmID, kind: .smart,
          fireAt: a.date, title: a.title.isEmpty ? "Умный будильник · Luma" : a.title,
          source: try audio.soundURL(signal, clips: state.voices), stopAfterSeconds: alarmStopSeconds)
      }
    if let session = systemAlarms.indirectSession {
      let source = try audio.soundURL(session.signal, clips: state.voices)
      result += session.dates(after: now).map {
        SystemAlarmRequest(key: session.key(for: $0), ownerID: session.id, kind: .indirect,
          fireAt: $0, title: "Непрямой метод · Luma", source: source, stopAfterSeconds: alarmStopSeconds)
      }
    }
    return result
  }

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
  private func rebuildAlarms() async {
    guard storageProblem == nil else { return }
    if rebuilding {
      rebuildAgain = true
      while rebuilding {
        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
      }
      return
    }
    rebuilding = true; defer { rebuilding = false }
    repeat {
      rebuildAgain = false
      do {
        try await systemAlarms.bootstrap()
        if systemAlarms.acceptedLimitations && nightAudio.ready {
          queuedAlarmIDs = try await systemAlarms.reconcile(try systemAlarmRequests(), activeOwners: systemAlarmOwners)
          lastSystemQueueError = nil
        } else { queuedAlarmIDs = [] }
      } catch {
        queuedAlarmIDs = Set(systemAlarms.ledger.records.filter { !$0.pending }.map(\.ownerID))
        let text = "Очередь сигналов: \(error.localizedDescription)"
        if text != lastSystemQueueError { message = text; lastSystemQueueError = text }
      }
      alarmPermissionSummary = systemAlarms.summary
      alarmPermissionReady = systemAlarms.authorized && systemAlarms.acceptedLimitations
    } while rebuildAgain
  }
}
