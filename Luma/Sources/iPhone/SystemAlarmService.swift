import Foundation
import Combine

/// AlarmKit-only delivery. A four-second WAV is the primary EOF experiment.
/// A stop deadline is an execution-only backup; it cannot wake a suspended app.
@MainActor final class SystemAlarmService: ObservableObject {
  @Published private(set) var ledger = SystemAlarmLedger()
  @Published private(set) var summary = "РџСЂРѕРІРµСЂСЏРµРј AlarmKitвЂ¦"
  @Published private(set) var lastStopReport = "WAV вЂ” 4,0 СЃРµРє. РћРєРѕРЅС‡Р°РЅРёРµ СЃРёРіРЅР°Р»Р° AlarmKit РЅР° iPhone РµС‰С‘ РЅРµ РїСЂРѕРІРµСЂРµРЅРѕ."
  @Published private(set) var preparing = false
  @Published private(set) var authorized = false
  var supported: Bool { scheduler.supported }
  private let scheduler: any ShortAlarmScheduling
  private let cleanup: (Bool) throws -> Void
  private let legacyNotificationCleanup: () async throws -> Void
  private var deadlines: [UUID: Task<Void, Never>] = [:]
  private let prepareSound: (URL) throws -> String
  private let storageDirectory: URL?
  private let defaults: UserDefaults
  private var loaded = false
  private var bootstrapped = false
  private var bootstrapping = false
  private var bootstrapTask: Task<Void, Error>?
  private var generation = UUID()
  private var inFlightID: UUID?
  private var lastPoll = Date.distantPast
  private var summaryWarning: String?
  private var observedDeliveries = Set<String>()

  init(scheduler: (any ShortAlarmScheduling)? = nil, directory: URL? = nil,
    defaults: UserDefaults = .standard, legacyCleanup: ((Bool) throws -> Void)? = nil,
    soundBuilder: ((URL) throws -> String)? = nil,
    notificationCleanup: (() async throws -> Void)? = nil) {
    self.scheduler = scheduler ?? AlarmKitScheduler()
    storageDirectory = directory; self.defaults = defaults
    if let notificationCleanup { legacyNotificationCleanup = notificationCleanup }
    else {
      let notifications = NotificationService()
      legacyNotificationCleanup = { try await notifications.removeLegacySignals() }
    }
    prepareSound = soundBuilder ?? { try AlarmKitSoundBuilder.prepare(source: $0) }
    if let legacyCleanup { cleanup = legacyCleanup }
    else {
      let legacy = LegacyAlarmCleanup()
      cleanup = { try legacy.removeRemainingAlarms(requiresConfirmation: $0) }
    }
  }
  var acceptedLimitations: Bool { defaults.bool(forKey: FiniteCuePolicy.consentKey) }
  var indirectSession: IndirectAlarmSession? { ledger.indirectSession }
  var indirectRecords: [SystemAlarmRecord] {
    guard let id = indirectSession?.id else { return [] }
    return ledger.records.filter { $0.kind == .indirect && $0.ownerID == id && !$0.pending }
      .sorted { $0.fireAt < $1.fireAt }
  }
  var queueUntil: Date? { indirectRecords.last?.fireAt }
  var logURL: URL? { CueDiagnostics.logURL }

  func bootstrap() async throws {
    if let bootstrapTask { try await bootstrapTask.value; return }
    let task = Task { @MainActor in try await self.bootstrapBody() }
    bootstrapTask = task
    defer { bootstrapTask = nil }
    try await task.value
  }
  private func bootstrapBody() async throws {
    try load()
    await refreshAccess()
    guard supported, authorized else { return }
    if !bootstrapped {
      bootstrapping = true
      defer { bootstrapping = false }
      // Finish both old transports before assigning new AlarmKit occurrence IDs.
      try await legacyNotificationCleanup()
      try cleanup(ledger.schema < 3)
      let previous = ledger
      if ledger.migrateToAlarmKitWave(now: Date()) {
        do { try persist() } catch { ledger = previous; throw error }
        CueDiagnostics.event("ledger_migrated_to_alarmkit_wave",
          detail: "schema 3; owner IDs, interval origin and future keys retained")
      }
      bootstrapped = true
      scheduler.setUpdateHandler { [weak self] in
        Task { @MainActor [weak self] in
          guard let self else { return }
          do { try await self.refresh() } catch { self.summary = error.localizedDescription }
        }
      }
    }
    if !preparing {
      try await completeCancellations()
      try await refreshRecords()
    }
    updateSummary()
  }
  func authorize(acceptLimitations: Bool = false) async throws {
    try load()
    guard supported else {
      throw AppError.message("Р”Р»СЏ СЃРёРіРЅР°Р»РѕРІ С‡РµСЂРµР· AlarmKit РЅСѓР¶РµРЅ iPhone СЃ iOS 26 РёР»Рё РЅРѕРІРµРµ.")
    }
    guard acceptedLimitations || acceptLimitations else {
      throw AppError.message("РЎРЅР°С‡Р°Р»Р° РѕС‚РєСЂРѕР№С‚Рµ РЅР°СЃС‚СЂРѕР№РєСѓ РєРѕСЂРѕС‚РєРёС… СЃРёРіРЅР°Р»РѕРІ AlarmKit.")
    }
    // Authorization can be needed before cleanup of a pre-existing AlarmKit queue.
    try await scheduler.requestAuthorization()
    try await bootstrap()
    await refreshAccess()
    guard authorized else {
      throw AppError.message("Р Р°Р·СЂРµС€РёС‚Рµ Р±СѓРґРёР»СЊРЅРёРєРё Luma РІ РЅР°СЃС‚СЂРѕР№РєР°С… iPhone.")
    }
    defaults.set(true, forKey: FiniteCuePolicy.consentKey)
  }
  func setIndirect(_ session: IndirectAlarmSession?) throws {
    try load()
    let previous = ledger
    ledger.indirectSession = session
    do { try persist() } catch { ledger = previous; throw error }
  }
  func resetHandled(ownerID: UUID) throws {
    try load()
    let previous = ledger
    ledger.handledKeys.removeAll { $0.contains(ownerID.uuidString) }
    do { try persist() } catch { ledger = previous; throw error }
  }

  @discardableResult
  func reconcile(_ requests: [SystemAlarmRequest], activeOwners: Set<UUID>) async throws -> Set<UUID> {
    // A stop/delete can arrive while bootstrap is awaiting the system
    // daemon, before preparing becomes true. Invalidate that stale input too.
    let operation = generation
    try await bootstrap()
    guard operation == generation, !Task.isCancelled else { throw CancellationError() }
    guard !preparing else { throw AppError.message("РџРѕРґРіРѕС‚РѕРІРєР° СЃРёРіРЅР°Р»РѕРІ РµС‰С‘ РІС‹РїРѕР»РЅСЏРµС‚СЃСЏ.") }
    guard supported, acceptedLimitations else {
      if requests.isEmpty { return [] }
      throw AppError.message("РћС‚РєСЂРѕР№С‚Рµ РЅР°СЃС‚СЂРѕР№РєСѓ СЃРёРіРЅР°Р»Р° Рё СЂР°Р·СЂРµС€РёС‚Рµ Р±СѓРґРёР»СЊРЅРёРєРё AlarmKit.")
    }
    preparing = true
    defer { preparing = false; updateSummary() }
    do {
      // Cancellation must also work if AlarmKit permission was revoked.
      try await completeCancellations()
      try await refreshRecords()
      guard operation == generation, !Task.isCancelled else { throw CancellationError() }
      await refreshAccess()
      // Removing disabled/deleted owners must not depend on permission to add.
      for record in ledger.records where record.kind != .probe && !activeOwners.contains(record.ownerID) {
        try await cancel(record, includingDelivered: false)
      }
      guard operation == generation, !Task.isCancelled else { throw CancellationError() }
      guard authorized || requests.isEmpty else {
        throw AppError.message("Р”РѕСЃС‚СѓРї Рє AlarmKit РІС‹РєР»СЋС‡РµРЅ. РџСЂРѕРІРµСЂСЊС‚Рµ СЂР°Р·СЂРµС€РµРЅРёРµ РЅР° Р±СѓРґРёР»СЊРЅРёРєРё Luma.")
      }
      let requestedKeys = Set(requests.map(\.key))
      let protectedProbes = ledger.records.filter { $0.kind == .probe && !requestedKeys.contains($0.key) }.count
      let capacity = max(0, SystemAlarmPolicy.queueLimit - protectedProbes)
      let desired = Array(SystemAlarmPolicy.desired(requests, after: Date(),
        handled: Set(ledger.handledKeys)).prefix(capacity))
      let wanted = Set(desired.map(\.key))
      // Prepare every asset before disturbing an accepted future queue.
      var sounds: [URL: String] = [:]
      for request in desired where sounds[request.source] == nil {
        do { sounds[request.source] = try prepareSound(request.source) }
        catch {
          CueDiagnostics.event("sound_prepare_failed", detail: error.localizedDescription)
          throw error
        }
      }
      for record in ledger.records {
        // Do not cancel a just-due pending delivery merely because its time is
        // no longer in the future. Its sound still ends independently of us.
        let justDue = activeOwners.contains(record.ownerID)
          && (-5...1).contains(record.fireAt.timeIntervalSinceNow)
        if !wanted.contains(record.key) && record.kind != .probe && !justDue {
          try await cancel(record, includingDelivered: false)
        }
      }
      for request in desired {
        guard operation == generation, !Task.isCancelled else { throw CancellationError() }
        guard let sound = sounds[request.source] else { continue }
        if let previous = ledger.records.first(where: { $0.key == request.key }) {
          if previous.soundName == sound && previous.title == request.title && !previous.pending { continue }
          try await cancel(previous, includingDelivered: false)
        }
        guard operation == generation, !Task.isCancelled else { throw CancellationError() }
        if request.fireAt.timeIntervalSinceNow <= 1 { continue }
        let record = SystemAlarmRecord(request: request, soundName: sound)
        ledger.records.append(record)
        do { try persist() } catch {
          ledger.records.removeAll { $0.id == record.id }; throw error
        }
        inFlightID = record.id
        do {
          CueDiagnostics.event("schedule_attempt", record: record)
          try await scheduler.add(record)
          guard operation == generation, !Task.isCancelled,
            ledger.records.contains(where: { $0.id == record.id }) else { throw CancellationError() }
          // Verify admission; add() returning is not acoustic confirmation.
          let admitted = try await scheduler.pending()
          guard operation == generation, !Task.isCancelled else { throw CancellationError() }
          guard admitted.contains(where: { $0.matches(record) }) else {
            throw AppError.message("AlarmKit РЅРµ РїРѕРґС‚РІРµСЂРґРёР» РїРѕСЃС‚Р°РЅРѕРІРєСѓ СЃРёРіРЅР°Р»Р° РІ РѕС‡РµСЂРµРґСЊ.")
          }
          if let i = ledger.records.firstIndex(where: { $0.id == record.id }) { ledger.records[i].pending = false }
          try persist()
          inFlightID = nil
          CueDiagnostics.event("schedule_accepted", record: record, detail: "AlarmKit fixed occurrence; verified 4-second PCM WAV")
        } catch {
          // A failed or cancelled await may still have admitted a request.
          let original = error
          do {
            try await scheduler.cancel([record.notificationID], includingDelivered: false)
            ledger.records.removeAll { $0.id == record.id }
            inFlightID = nil
            try persist()
          } catch {
            inFlightID = nil
            CueDiagnostics.event("ambiguous_schedule_cleanup_failed", record: record, detail: error.localizedDescription)
            throw AppError.message("РќРµ СѓРґР°Р»РѕСЃСЊ РїРѕРґС‚РІРµСЂРґРёС‚СЊ РѕС‚РјРµРЅСѓ СЃРёРіРЅР°Р»Р°. РћС‚РєСЂРѕР№С‚Рµ Luma Рё РѕС‚РјРµРЅРёС‚Рµ РѕС‡РµСЂРµРґСЊ. \(error.localizedDescription)")
          }
          CueDiagnostics.event("schedule_failed_or_cancelled", record: record, detail: original.localizedDescription)
          throw original
        }
      }
      try await completeCancellations()
      guard operation == generation else { throw CancellationError() }
      return Set(ledger.records.filter { !$0.pending }.map(\.ownerID))
    } catch {
      inFlightID = nil
      do { try await completeCancellations() }
      catch { summaryWarning = "РћС‚РјРµРЅР° РѕС‡РµСЂРµРґРё РЅРµ Р·Р°РІРµСЂС€РµРЅР°: \(error.localizedDescription)" }
      throw error
    }
  }

  func stopIndirect() async throws {
    try await bootstrap()
    try load()
    generation = UUID()
    guard let id = indirectSession?.id else { return }
    let previous = ledger
    ledger.indirectSession = nil
    ledger.cancelledOwners = Array(Set(ledger.cancelledOwners ?? []).union([id]))
    do { try persist() } catch { ledger = previous; throw error }
    try await completeCancellations(); updateSummary()
  }
  func cancelOwner(_ id: UUID) async throws {
    try load(); generation = UUID()
    let previous = ledger
    ledger.cancelledOwners = Array(Set(ledger.cancelledOwners ?? []).union([id]))
    do { try persist() } catch { ledger = previous; throw error }
    try cleanup(ledger.schema < 3)
    try await completeCancellations(); updateSummary()
  }
  func cancelProbes() async throws {
    try load()
    guard !preparing else { throw AppError.message("Р”РѕР¶РґРёС‚РµСЃСЊ РїРѕРґРіРѕС‚РѕРІРєРё РѕС‡РµСЂРµРґРё СЃРёРіРЅР°Р»РѕРІ.") }
    preparing = true
    defer { preparing = false }
    for record in ledger.records where record.kind == .probe { try await cancel(record, includingDelivered: true) }
    updateSummary()
  }
  func stopAll() async throws {
    try load(); generation = UUID()
    let previous = ledger
    ledger.indirectSession = nil; ledger.cancelAllRequested = true
    do { try persist() } catch { ledger = previous; throw error }
    try await legacyNotificationCleanup()
    // Cancel legacy alarms as well if bootstrap previously failed.
    try cleanup(ledger.schema < 3)
    try await completeCancellations(); updateSummary()
  }
  private func completeCancellations() async throws {
    guard ledger.cancelAllRequested == true || !(ledger.cancelledOwners ?? []).isEmpty else { return }
    let cancellationGeneration = generation
    let all = ledger.cancelAllRequested == true
    let owners = Set(ledger.cancelledOwners ?? [])
    let records = ledger.records.filter { all || owners.contains($0.ownerID) }
    var ids = Set(records.map(\.notificationID))
    if all {
      let pending = try await scheduler.pending(), delivered = await scheduler.delivered()
      ids.formUnion((pending + delivered).map(\.identifier).filter { $0.hasPrefix(FiniteCuePolicy.prefix) })
    }
    try await scheduler.cancel(Array(ids), includingDelivered: true)
    let remove = Set(records.map(\.id).filter { $0 != inFlightID })
    ledger.records.removeAll { remove.contains($0.id) }
    for id in remove { deadlines.removeValue(forKey: id)?.cancel() }
    // Keep a durable tombstone until an outstanding add() continuation finishes.
    // A newer stop/delete may have persisted another intention during await.
    // An older continuation must not clear that newer durable intention.
    if inFlightID == nil && generation == cancellationGeneration {
      ledger.cancelAllRequested = nil; ledger.cancelledOwners = nil
    }
    try persist()
    CueDiagnostics.event("queue_cancel_verified", detail: "AlarmKit IDs removed; other series occurrences retained")
  }
  func poll() async {
    guard !preparing, !bootstrapping, Date().timeIntervalSince(lastPoll) >= 0.5 else { return }
    lastPoll = Date()
    do { try await bootstrap() } catch { summary = error.localizedDescription }
  }
  func appBecameInactive() {
    CueDiagnostics.event("app_inactive", detail: "WAV EOF primary; backup Stop only while the process executes")
  }
  func refresh() async throws {
    guard !preparing else { return }
    try await bootstrap()
  }

  private func refreshRecords() async throws {
    let pending = try await scheduler.pending()
    let known = Set(ledger.records.map(\.notificationID))
    let orphanIDs = pending.map(\.identifier).filter { $0.hasPrefix(FiniteCuePolicy.prefix) && !known.contains($0) }
    try await scheduler.cancel(orphanIDs, includingDelivered: true)
    if !orphanIDs.isEmpty { CueDiagnostics.event("orphan_alarmkit_ids_cancelled", detail: "\(orphanIDs.count)") }
    let byID = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
    var changed = false
    for record in ledger.records {
      if let snapshot = byID[record.notificationID], snapshot.matches(record) {
        if record.pending, let i = ledger.records.firstIndex(where: { $0.id == record.id }) {
          ledger.records[i].pending = false; changed = true
          CueDiagnostics.event("reservation_recovered", record: record)
        }
        if snapshot.alerting {
          if observedDeliveries.insert(record.notificationID).inserted {
            CueDiagnostics.event("alarmkit_alert_observed", record: record,
              detail: "state observed in process; actual acoustic start/EOF not observable")
          }
          if Date() >= record.stopAt {
            CueDiagnostics.event("backup_stop_attempt", record: record)
            do {
              try await scheduler.stop(record.notificationID)
              ledger.markHandled(record); changed = true
              deadlines.removeValue(forKey: record.id)?.cancel()
              lastStopReport = "AlarmKit РїРѕРґС‚РІРµСЂРґРёР» СЂРµР·РµСЂРІРЅСѓСЋ Stop; РґР»РёС‚РµР»СЊРЅРѕСЃС‚СЊ Р·РІСѓС‡Р°РЅРёСЏ РЅСѓР¶РЅРѕ РёР·РјРµСЂРёС‚СЊ."
              CueDiagnostics.event("backup_stop_verified", record: record,
                detail: "system ID removed; not acoustic proof or a background guarantee")
            } catch {
              lastStopReport = "Р РµР·РµСЂРІРЅР°СЏ Stop РЅРµ РїРѕРґС‚РІРµСЂР¶РґРµРЅР°. РџСЂРё РїРѕРІС‚РѕСЂРµ РЅР°Р¶РјРёС‚Рµ В«РћСЃС‚Р°РЅРѕРІРёС‚СЊВ»."
              CueDiagnostics.event("backup_stop_failed", record: record, detail: error.localizedDescription)
              throw error
            }
          } else { armBackup(record) }
        }
      } else {
        if byID[record.notificationID] != nil {
          try await scheduler.cancel([record.notificationID], includingDelivered: true)
          CueDiagnostics.event("unexpected_alarm_configuration", record: record)
        }
        if record.fireAt <= Date().addingTimeInterval(1) {
          ledger.markHandled(record)
          CueDiagnostics.event("alarmkit_id_absent_or_dismissed", record: record)
        } else {
          ledger.records.removeAll { $0.id == record.id }
          CueDiagnostics.event("future_alarmkit_id_missing", record: record)
        }
        deadlines.removeValue(forKey: record.id)?.cancel()
        changed = true
      }
    }
    if changed { try persist() }
  }
  private func armBackup(_ record: SystemAlarmRecord) {
    guard deadlines[record.id] == nil else { return }
    let delay = max(0, record.stopAt.timeIntervalSinceNow)
    guard delay.isFinite else { return }
    // Execution-only backup after an observed alert, not a wake-up mechanism.
    // The finite WAV is used regardless of whether this task can execute.
    deadlines[record.id] = Task { @MainActor [weak self] in
      do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.deadlines[record.id] = nil
      do { try await self.refresh() } catch { self.summary = error.localizedDescription }
    }
  }
  private func cancel(_ record: SystemAlarmRecord, includingDelivered: Bool) async throws {
    CueDiagnostics.event("cancel_attempt", record: record)
    try await scheduler.cancel([record.notificationID], includingDelivered: includingDelivered)
    ledger.records.removeAll { $0.id == record.id }
    deadlines.removeValue(forKey: record.id)?.cancel()
    try persist()
    CueDiagnostics.event("cancel_verified", record: record)
  }
  private func refreshAccess() async {
    let access = await scheduler.access()
    authorized = access.ready
    summaryWarning = nil
    updateSummary()
  }
  private func updateSummary() {
    guard supported else { summary = "AlarmKit В· С‚СЂРµР±СѓРµС‚СЃСЏ iOS 26 РёР»Рё РЅРѕРІРµРµ"; return }
    guard authorized else { summary = "Р Р°Р·СЂРµС€РёС‚Рµ Р±СѓРґРёР»СЊРЅРёРєРё Luma С‡РµСЂРµР· AlarmKit"; return }
    let count = ledger.records.filter { !$0.pending }.count
    summary = "AlarmKit В· РІ РѕС‡РµСЂРµРґРё \(count) В· WAV 4,0 СЃРµРє"
    if let summaryWarning { summary += " В· \(summaryWarning)" }
  }
  private func directory() throws -> URL {
    if let storageDirectory {
      try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
      return storageDirectory
    }
    return try CueDiagnostics.directory()
  }
  private func load() throws {
    guard !loaded else { return }
    let file = try directory().appendingPathComponent("alarms.json")
    if FileManager.default.fileExists(atPath: file.path) {
      var value = try JSONDecoder().decode(SystemAlarmLedger.self, from: Data(contentsOf: file))
      guard [1, 2, 3].contains(value.schema),
        Set(value.records.map(\.id)).count == value.records.count,
        Set(value.records.map(\.key)).count == value.records.count,
        value.records.allSatisfy({ $0.fireAt.timeIntervalSince1970.isFinite
          && !$0.soundName.contains("/") && !$0.soundName.contains("\\")
          && (value.schema == 3 ? FiniteCuePolicy.validSoundName($0.soundName)
            : ($0.soundName == "luma-tone-4.wav" || $0.soundName.hasPrefix("luma-ak4-")
              || $0.soundName.hasPrefix("luma-cue4-"))) }) else {
        throw AppError.message("РџРѕРІСЂРµР¶РґС‘РЅ Р¶СѓСЂРЅР°Р» СЃРёРіРЅР°Р»РѕРІ. РќРѕРІР°СЏ РѕС‡РµСЂРµРґСЊ РЅРµ РїРѕСЃС‚Р°РІР»РµРЅР°.")
      }
      _ = value.migrateToiPhoneOnly()
      ledger = value
    }
    loaded = true
  }
  private func persist() throws {
    let file = try directory().appendingPathComponent("alarms.json")
    #if os(iOS)
    try JSONEncoder().encode(ledger).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try JSONEncoder().encode(ledger).write(to: file, options: .atomic)
    #endif
  }
}
