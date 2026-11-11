import Foundation
import Combine

/// Historical name retained for callers/storage. All new cues are finite local
/// notifications. No app timer, background assertion, AlarmKit state or
/// notification callback is needed to stop their audio.
@MainActor final class SystemAlarmService: ObservableObject {
  @Published private(set) var ledger = SystemAlarmLedger()
  @Published private(set) var summary = "Проверяем уведомления Luma…"
  @Published private(set) var lastStopReport = "Звук — 4,0 сек. Акустическая проверка на iPhone ещё не выполнена."
  @Published private(set) var preparing = false
  @Published private(set) var authorized = false
  let supported = true // UserNotifications is supported throughout our iOS 17+ target.
  private let scheduler: any FiniteNotificationScheduling
  private let cleanup: (Bool) throws -> Void
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

  init(scheduler: (any FiniteNotificationScheduling)? = nil, directory: URL? = nil,
    defaults: UserDefaults = .standard, legacyCleanup: ((Bool) throws -> Void)? = nil,
    soundBuilder: ((URL) throws -> String)? = nil) {
    self.scheduler = scheduler ?? NotificationService()
    storageDirectory = directory; self.defaults = defaults
    prepareSound = soundBuilder ?? { try FiniteCueSoundBuilder.prepare(source: $0) }
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
    if !bootstrapped {
      bootstrapping = true
      defer { bootstrapping = false }
      // Do not erase schema-1 reservations until the old daemon queue is empty.
      // Even an empty legacy ledger can have lost an orphan daemon ID.
      try cleanup(ledger.schema == 1)
      let oldPending = await scheduler.pending()
      let oldDelivered = await scheduler.delivered()
      let oldIDs = Set((oldPending + oldDelivered).map(\.identifier)
        .filter { $0.hasPrefix("luma.") && !$0.hasPrefix(FiniteCuePolicy.prefix) })
      try await scheduler.cancel(Array(oldIDs), includingDelivered: true)
      let previous = ledger
      if ledger.migrateToFiniteNotifications(now: Date()) {
        do { try persist() } catch { ledger = previous; throw error }
        CueDiagnostics.event("legacy_ledger_migrated", detail: "future owners and interval cadence retained")
      }
      bootstrapped = true
    }
    if !preparing {
      try await completeCancellations()
      try await refreshRecords()
    }
    await refreshAccess()
  }
  func authorize(acceptLimitations: Bool = false) async throws {
    try await bootstrap()
    guard acceptedLimitations || acceptLimitations else {
      throw AppError.message("Сначала ознакомьтесь с настройкой коротких уведомлений Luma.")
    }
    try await scheduler.requestAuthorization()
    await refreshAccess()
    guard authorized else {
      throw AppError.message("Разрешите уведомления Luma, звуки, баннеры и экран блокировки в настройках iPhone. Выключите беззвучный режим и разрешите Luma в Focus.")
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
    // A stop/delete can arrive while bootstrap is awaiting the notification
    // daemon, before preparing becomes true. Invalidate that stale input too.
    let operation = generation
    try await bootstrap()
    guard operation == generation, !Task.isCancelled else { throw CancellationError() }
    guard !preparing else { throw AppError.message("Подготовка сигналов ещё выполняется.") }
    guard acceptedLimitations else {
      if requests.isEmpty { return [] }
      throw AppError.message("Откройте настройку сигнала и разрешите уведомления Luma.")
    }
    preparing = true
    defer { preparing = false; updateSummary() }
    do {
      // Cancellation must also work if notification permission was revoked.
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
        throw AppError.message("Уведомления или звуки Luma выключены. Проверьте настройки iPhone.")
      }
      let pending = await scheduler.pending()
      guard operation == generation, !Task.isCancelled else { throw CancellationError() }
      let foreignCount = pending.filter { !$0.identifier.hasPrefix(FiniteCuePolicy.prefix) }.count
      let requestedKeys = Set(requests.map(\.key))
      let protectedProbes = ledger.records.filter { $0.kind == .probe && !requestedKeys.contains($0.key) }.count
      let capacity = max(0, FiniteCuePolicy.capacity(otherPending: foreignCount) - protectedProbes)
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
          let admitted = await scheduler.pending()
          guard operation == generation, !Task.isCancelled else { throw CancellationError() }
          guard admitted.contains(where: { $0.matches(record) }) else {
            throw AppError.message("Система не подтвердила постановку сигнала в очередь.")
          }
          if let i = ledger.records.firstIndex(where: { $0.id == record.id }) { ledger.records[i].pending = false }
          try persist()
          inFlightID = nil
          CueDiagnostics.event("schedule_accepted", record: record, detail: "nonrepeating; finite 4-second PCM sound")
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
            throw AppError.message("Не удалось подтвердить отмену сигнала. Откройте Luma и отмените очередь. \(error.localizedDescription)")
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
      catch { summaryWarning = "Отмена очереди не завершена: \(error.localizedDescription)" }
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
    try cleanup(ledger.schema == 1)
    try await completeCancellations(); updateSummary()
  }
  func cancelProbes() async throws {
    try load()
    guard !preparing else { throw AppError.message("Дождитесь подготовки очереди сигналов.") }
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
    // Cancel legacy alarms as well if bootstrap previously failed.
    try cleanup(ledger.schema == 1)
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
      let pending = await scheduler.pending(), delivered = await scheduler.delivered()
      ids.formUnion((pending + delivered).map(\.identifier).filter { $0.hasPrefix(FiniteCuePolicy.prefix) })
    }
    try await scheduler.cancel(Array(ids), includingDelivered: true)
    let remove = Set(records.map(\.id).filter { $0 != inFlightID })
    ledger.records.removeAll { remove.contains($0.id) }
    // Keep a durable tombstone until an outstanding add() continuation finishes.
    // A newer stop/delete may have persisted another intention during await.
    // An older continuation must not clear that newer durable intention.
    if inFlightID == nil && generation == cancellationGeneration {
      ledger.cancelAllRequested = nil; ledger.cancelledOwners = nil
    }
    try persist()
    CueDiagnostics.event("queue_cancel_verified", detail: "pending cancelled; an already playing finite sound may finish naturally")
  }
  func poll() async {
    guard !preparing, !bootstrapping, Date().timeIntervalSince(lastPoll) >= 30 else { return }
    lastPoll = Date()
    do { try await bootstrap() } catch { summary = error.localizedDescription }
  }
  func appBecameInactive() {
    CueDiagnostics.event("app_inactive", detail: "no stop timer; the OS owns admitted sounds")
  }
  func refresh() async throws {
    guard !preparing else { return }
    try await bootstrap()
  }

  private func refreshRecords() async throws {
    let pending = await scheduler.pending()
    let known = Set(ledger.records.map(\.notificationID))
    let orphanIDs = pending.map(\.identifier).filter { $0.hasPrefix(FiniteCuePolicy.prefix) && !known.contains($0) }
    try await scheduler.cancel(orphanIDs, includingDelivered: false)
    if !orphanIDs.isEmpty { CueDiagnostics.event("orphan_requests_cancelled", detail: "\(orphanIDs.count)") }
    let byID = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
    var changed = false
    for record in ledger.records {
      if let snapshot = byID[record.notificationID], snapshot.matches(record) {
        if record.pending, let i = ledger.records.firstIndex(where: { $0.id == record.id }) {
          ledger.records[i].pending = false; changed = true
          CueDiagnostics.event("reservation_recovered", record: record)
        }
      } else {
        if byID[record.notificationID] != nil {
          try await scheduler.cancel([record.notificationID], includingDelivered: false)
          CueDiagnostics.event("unexpected_request_configuration", record: record)
        }
        if record.fireAt <= Date().addingTimeInterval(1) {
          ledger.markHandled(record)
          CueDiagnostics.event("due_request_no_longer_pending", record: record,
            detail: "delivery/dismissal inferred; acoustic playback not observable")
        } else {
          // A missing FUTURE request can be re-created. Never mark it delivered.
          ledger.records.removeAll { $0.id == record.id }
          CueDiagnostics.event("future_request_missing", record: record)
        }
        changed = true
      }
    }
    if changed { try persist() }
    for item in await scheduler.delivered() where item.identifier.hasPrefix(FiniteCuePolicy.prefix) {
      if observedDeliveries.insert(item.identifier).inserted {
        CueDiagnostics.event("system_delivery_observed", identifier: item.identifier,
          detail: "finite sound end expected without a stop call; not an acoustic measurement")
      }
    }
  }
  private func cancel(_ record: SystemAlarmRecord, includingDelivered: Bool) async throws {
    CueDiagnostics.event("cancel_attempt", record: record)
    try await scheduler.cancel([record.notificationID], includingDelivered: includingDelivered)
    ledger.records.removeAll { $0.id == record.id }
    try persist()
    CueDiagnostics.event("cancel_verified", record: record)
  }
  private func refreshAccess() async {
    let access = await scheduler.access()
    authorized = access.ready
    summaryWarning = access.scheduledSummary ? "Выключите сводку уведомлений для Luma" : nil
    updateSummary()
  }
  private func updateSummary() {
    guard authorized else { summary = "Разрешите уведомления Luma, звуки и экран блокировки"; return }
    let count = ledger.records.filter { !$0.pending }.count
    summary = "Короткие сигналы · в очереди \(count)"
    if let summaryWarning { summary += " · \(summaryWarning)" }
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
      guard [1, 2].contains(value.schema),
        Set(value.records.map(\.id)).count == value.records.count,
        Set(value.records.map(\.key)).count == value.records.count,
        value.records.allSatisfy({ $0.fireAt.timeIntervalSince1970.isFinite
          && (value.schema == 1 ? ($0.soundName.hasPrefix("luma-ak4-")
            && !$0.soundName.contains("/") && !$0.soundName.contains("\\"))
            : FiniteCuePolicy.validSoundName($0.soundName)) }) else {
        throw AppError.message("Повреждён журнал сигналов. Новая очередь не поставлена.")
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
