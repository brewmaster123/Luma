import Foundation
import Combine
import UIKit
#if canImport(AlarmKit)
import AlarmKit
import ActivityKit
import AppIntents
import SwiftUI

@available(iOS 26.0, *)
struct LumaAlarmMetadata: AlarmMetadata { var kind: String }

/// A manual fallback, not an automatic alarm-fired callback. AlarmKit invokes
/// stopIntent after a person dismisses the system alarm.
@available(iOS 26.0, *)
struct LumaStopAlarmIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Остановить сигнал Luma"
  static var openAppWhenRun = false
  @Parameter(title: "Идентификатор будильника") var alarmID: String
  init() { alarmID = "" }
  init(id: UUID) { alarmID = id.uuidString }
  func perform() async throws -> some IntentResult {
    guard let id = UUID(uuidString: alarmID) else { return .result() }
    try await MainActor.run {
      let manager = AlarmManager.shared
      if try manager.alarms.contains(where: { $0.id == id }) { try manager.stop(id: id) }
    }
    return .result()
  }
}
#endif

/// Real AlarmKit scheduling plus a best-effort, app-driven four-second stop.
/// No timer, sound EOF, stopIntent or async sequence is a background execution
/// entitlement. A suspended/terminated process cannot promise this stop deadline.
@MainActor final class SystemAlarmService: ObservableObject {
  @Published private(set) var ledger = SystemAlarmLedger()
  @Published private(set) var summary = "AlarmKit · требуется iOS 26 или новее"
  @Published private(set) var lastStopReport = "Автоостановка на этом iPhone ещё не проверена"
  @Published private(set) var preparing = false
  private let consentKey = "luma.alarmkit.short-stop-consent.v1"
  private var loaded = false
  private var generation = UUID()
  private var updates: Task<Void, Never>?
  private var deadlines: [UUID: Task<Void, Never>] = [:]
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var stopAttempts: [UUID: Int] = [:]
  private var lastPoll = Date.distantPast
  var acceptedLimitations: Bool { UserDefaults.standard.bool(forKey: consentKey) }
  var indirectSession: IndirectAlarmSession? { ledger.indirectSession }
  var indirectRecords: [SystemAlarmRecord] {
    guard let id = indirectSession?.id else { return [] }
    return ledger.records.filter { $0.kind == .indirect && $0.ownerID == id && !$0.pending }
      .sorted { $0.fireAt < $1.fireAt }
  }
  var queueUntil: Date? { indirectRecords.last?.fireAt }
  var logURL: URL? { try? directory().appendingPathComponent("alarmkit-events.jsonl") }
  var supported: Bool {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) { return true }
    #endif
    return false
  }
  var authorized: Bool {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) { return AlarmManager.shared.authorizationState == .authorized }
    #endif
    return false
  }

  func bootstrap() throws {
    try load()
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      guard AlarmManager.shared.authorizationState == .authorized else {
        summary = "Разрешите системные будильники Luma"; return
      }
      try completeCancellations()
      observe()
      try refresh()
    }
    #endif
  }
  func authorize(acceptLimitations: Bool = false) async throws {
    try load()
    guard supported else {
      throw AppError.message("Для системных сигналов Luma нужен iPhone с iOS 26 или новее и сборка с Xcode 26 или новее.")
    }
    guard acceptedLimitations || acceptLimitations else {
      throw AppError.message("Сначала прочитайте условия проверки автоостановки AlarmKit.")
    }
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let state = try await AlarmManager.shared.requestAuthorization()
      guard state == .authorized else {
        throw AppError.message("Разрешите будильники: Настройки iPhone → Приложения → Luma → Будильники.")
      }
      UserDefaults.standard.set(true, forKey: consentKey)
      try completeCancellations()
      observe()
      try refresh()
    }
    #endif
  }
  func setIndirect(_ session: IndirectAlarmSession?) throws {
    try load()
    let previous = ledger
    ledger.indirectSession = session
    do { try persist() } catch { ledger = previous; throw error }
  }
  func resetHandled(ownerID: UUID) throws {
    try load()
    ledger.handledKeys.removeAll { $0.contains(ownerID.uuidString) }
    ledger.cancelledOwners?.removeAll { $0 == ownerID }
    try persist()
  }

  /// Keeps system-accepted records, reserves before scheduling, and cancels stale
  /// IDs before replacing them. No notification or AVAudioPlayer fallback here.
  @discardableResult
  func reconcile(_ requests: [SystemAlarmRequest], activeOwners: Set<UUID>) async throws -> Set<UUID> {
    try load()
    guard !preparing else { throw AppError.message("Подготовка будильников ещё выполняется.") }
    guard supported, acceptedLimitations else {
      if requests.isEmpty { return [] }
      throw AppError.message("Откройте настройку будильника и разрешите AlarmKit перед запуском.")
    }
    preparing = true
    let operation = generation
    defer {
      preparing = false; updateSummary()
      do { try completeCancellations() }
      catch { summary = "Отмена очереди не завершена: \(error.localizedDescription)" }
    }
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let manager = AlarmManager.shared
      guard manager.authorizationState == .authorized else {
        throw AppError.message("Доступ Luma к системным будильникам выключен в настройках iPhone.")
      }
      try completeCancellations()
      observe()
      try refresh()
      let desired = SystemAlarmPolicy.desired(requests, after: Date(), handled: Set(ledger.handledKeys))
      let wanted = Set(desired.map(\.key))
      let system = try manager.alarms
      let alerting = Set(system.filter { $0.state == .alerting }.map(\.id))
      for record in ledger.records {
        let keepRinging = alerting.contains(record.id) && activeOwners.contains(record.ownerID)
        if !wanted.contains(record.key) && record.kind != .probe && !keepRinging {
          try cancel(record)
        }
      }
      var soundCache: [URL: String] = [:]
      for request in desired {
        guard operation == generation, !Task.isCancelled else { throw CancellationError() }
        let sound: String
        if let cached = soundCache[request.source] { sound = cached }
        else { sound = try AlarmKitSoundBuilder.prepare(source: request.source); soundCache[request.source] = sound }
        if let previous = ledger.records.first(where: { $0.key == request.key }) {
          if previous.soundName == sound && previous.title == request.title && !previous.pending { continue }
          try cancel(previous)
        }
        if request.fireAt.timeIntervalSinceNow <= 1 { continue }
        let record = SystemAlarmRecord(request: request, soundName: sound)
        ledger.records.append(record)
        do { try persist() } catch { ledger.records.removeAll { $0.id == record.id }; throw error }
        do {
          let stop = AlarmButton(text: "Остановить", textColor: .white, systemImageName: "stop.fill")
          // Alert-only presentation: no countdown/snooze and no missing widget extension.
          let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: request.title),
            stopButton: stop, secondaryButton: nil, secondaryButtonBehavior: nil)
          let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert),
            metadata: LumaAlarmMetadata(kind: request.kind.rawValue),
            tintColor: Color(red: 0.72, green: 0.68, blue: 0.98))
          let configuration = AlarmManager.AlarmConfiguration<LumaAlarmMetadata>.alarm(
            schedule: .fixed(request.fireAt), attributes: attributes,
            stopIntent: LumaStopAlarmIntent(id: record.id), sound: .named(sound))
          _ = try await manager.schedule(id: record.id, configuration: configuration)
          guard operation == generation, !Task.isCancelled,
            ledger.records.contains(where: { $0.id == record.id }) else {
            try manager.cancel(id: record.id)
            ledger.records.removeAll { $0.id == record.id }; try persist()
            throw CancellationError()
          }
          if let i = ledger.records.firstIndex(where: { $0.id == record.id }) { ledger.records[i].pending = false }
          do { try persist() } catch {
            try? manager.cancel(id: record.id)
            throw error
          }
          event("scheduled", record: record)
          armDeadline(record)
        } catch {
          // A failed/ambiguous scheduling call must not leave an untracked alarm.
          let stillExists = (try? manager.alarms.contains(where: { $0.id == record.id })) ?? true
          if stillExists {
            do { try manager.cancel(id: record.id) }
            catch {
              if !ledger.records.contains(where: { $0.id == record.id }) { ledger.records.append(record) }
              try? persist(); armDeadline(record)
              throw AppError.message("Не удалось подтвердить отмену системного сигнала. Откройте Luma и проверьте очередь. \(error.localizedDescription)")
            }
          }
          ledger.records.removeAll { $0.id == record.id }
          try? persist()
          event("schedule_failed", record: record, detail: error.localizedDescription)
          throw error
        }
      }
      try refresh()
      return Set(ledger.records.filter { !$0.pending }.map(\.ownerID))
    }
    #endif
    throw AppError.message("AlarmKit недоступен в этой сборке.")
  }

  func stopIndirect() throws {
    try load()
    generation = UUID() // In-flight schedule must cancel itself on return.
    guard let id = indirectSession?.id else { return }
    ledger.indirectSession = nil
    ledger.cancelledOwners = Array(Set(ledger.cancelledOwners ?? []).union([id]))
    try persist()
    try completeCancellations(); updateSummary()
  }
  func cancelProbes() throws {
    try load()
    guard !preparing else { throw AppError.message("Дождитесь подготовки очереди AlarmKit.") }
    for record in ledger.records where record.kind == .probe { try cancel(record) }
  }
  func stopAll() throws {
    try load(); generation = UUID()
    ledger.indirectSession = nil; ledger.cancelAllRequested = true
    try persist()
    try completeCancellations()
    finishBackgroundTask(); updateSummary()
  }
  private func completeCancellations() throws {
    guard ledger.cancelAllRequested == true || !(ledger.cancelledOwners ?? []).isEmpty else { return }
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      if ledger.cancelAllRequested == true {
        // Includes orphan IDs from a killed scheduling call or an older release.
        let alarms = try AlarmManager.shared.alarms
        for alarm in alarms { try AlarmManager.shared.cancel(id: alarm.id) }
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        ledger.records.removeAll()
      } else {
        let owners = Set(ledger.cancelledOwners ?? [])
        for record in ledger.records where owners.contains(record.ownerID) { try cancel(record) }
      }
      // A schedule awaiting the daemon can still return after cancellation.
      // Keep the durable tombstone until that continuation has finished.
      if preparing { try persist(); return }
      ledger.cancelAllRequested = nil; ledger.cancelledOwners = nil
      try persist()
    }
    #endif
  }
  func poll() {
    guard Date().timeIntervalSince(lastPoll) >= 0.5 else { return }
    lastPoll = Date()
    do { try refresh() } catch { summary = error.localizedDescription }
  }
  func appBecameInactive() {
    // Only finish imminent work with finite UIKit background time. This does
    // not request a background assertion for the next 10–60 minute interval.
    if ledger.records.contains(where: {
      (-4...15).contains($0.fireAt.timeIntervalSinceNow)
    }) { beginBackgroundTask() }
    poll()
  }
  func refresh() throws {
    try load()
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .authorized {
      try handle(AlarmManager.shared.alarms)
    }
    #endif
    updateSummary()
  }

  #if canImport(AlarmKit)
  @available(iOS 26.0, *)
  private func observe() {
    guard updates == nil else { return }
    updates = Task { @MainActor [weak self] in
      for await alarms in AlarmManager.shared.alarmUpdates {
        guard !Task.isCancelled, let self else { return }
        do { try self.handle(alarms); self.updateSummary() }
        catch { self.summary = error.localizedDescription }
      }
    }
  }
  @available(iOS 26.0, *)
  private func handle(_ incoming: [Alarm]) throws {
    // An asynchronous update can be older than an interleaved schedule/cancel.
    // Re-read the daemon before treating an ID as absent.
    let alarms = try AlarmManager.shared.alarms
    let byID = Dictionary(uniqueKeysWithValues: alarms.map { ($0.id, $0) })
    var changed = false
    for record in ledger.records {
      if let alarm = byID[record.id] {
        // A reservation with a real daemon alarm survived an interrupted await.
        if record.pending, let i = ledger.records.firstIndex(where: { $0.id == record.id }) {
          ledger.records[i].pending = false; changed = true
        }
        switch SystemAlarmPolicy.stopAction(record: record, alerting: alarm.state == .alerting, now: Date()) {
        case .none: armDeadline(record)
        case .wait:
          beginBackgroundTask(); armDeadline(record)
        case .stop(let lateness):
          beginBackgroundTask()
          do {
            try AlarmManager.shared.stop(id: record.id)
            // Check the daemon rather than trusting an audio completion or timer.
            if try AlarmManager.shared.alarms.contains(where: { $0.id == record.id }) {
              try AlarmManager.shared.cancel(id: record.id)
            }
            ledger.markHandled(record); changed = true
            deadlines.removeValue(forKey: record.id)?.cancel()
            stopAttempts[record.id] = nil
            lastStopReport = lateness < 0.75
              ? "Команда автоостановки выполнена · акустическая проверка нужна на iPhone"
              : "Остановка опоздала на \(Int(lateness.rounded())) сек · фоновый тест не пройден"
            event("stop_succeeded", record: record, lateBy: lateness)
          } catch {
            stopAttempts[record.id, default: 0] += 1
            // Independent retry path; cancelling a fixed alarm also ends its alert.
            do {
              try AlarmManager.shared.cancel(id: record.id)
              ledger.markHandled(record); changed = true
              deadlines.removeValue(forKey: record.id)?.cancel()
              lastStopReport = "Выполнена резервная отмена сигнала · проверьте журнал"
              event("cancel_after_stop_error", record: record, lateBy: lateness)
            } catch {
              lastStopReport = "Не удалось остановить системный сигнал. Остановите его на экране iPhone."
              if stopAttempts[record.id] == 1 { event("stop_failed", record: record, detail: error.localizedDescription) }
              // Retain record. poll/alarmUpdates will retry while the process runs.
            }
          }
        }
      } else if !record.pending || !preparing {
        ledger.markHandled(record); changed = true
        deadlines.removeValue(forKey: record.id)?.cancel()
        event("absent_or_dismissed", record: record)
      }
    }
    if changed { try persist() }
    if !ledger.records.contains(where: { (-4...15).contains($0.fireAt.timeIntervalSinceNow) }) {
      finishBackgroundTask()
    }
  }
  #endif

  private func armDeadline(_ record: SystemAlarmRecord) {
    guard deadlines[record.id] == nil else { return }
    let delay = max(0.5, record.stopAt.timeIntervalSinceNow)
    guard delay.isFinite else { return }
    deadlines[record.id] = Task { @MainActor [weak self] in
      do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.deadlines[record.id] = nil
      // No polling assumption: fetch the real state at the original deadline.
      do { try self.refresh() } catch { self.summary = error.localizedDescription }
    }
  }
  private func cancel(_ record: SystemAlarmRecord) throws {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let manager = AlarmManager.shared
      if try manager.alarms.contains(where: { $0.id == record.id }) { try manager.cancel(id: record.id) }
    }
    #endif
    deadlines.removeValue(forKey: record.id)?.cancel()
    let retainReservation = preparing && record.pending
      && (ledger.cancelAllRequested == true || (ledger.cancelledOwners ?? []).contains(record.ownerID))
    if !retainReservation { ledger.records.removeAll { $0.id == record.id } }
    try persist(); event("cancelled", record: record)
  }
  private func beginBackgroundTask() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish Luma alarm") { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.event("background_time_expired")
        // Fail short if background time ends while already ringing.
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
          if let alarms = (try? AlarmManager.shared.alarms) {
            for alarm in alarms where alarm.state == .alerting {
              try? AlarmManager.shared.stop(id: alarm.id)
            }
          }
        }
        #endif
        self.finishBackgroundTask()
      }
    }
  }
  private func finishBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    let id = backgroundTask; backgroundTask = .invalid
    UIApplication.shared.endBackgroundTask(id)
  }
  private func updateSummary() {
    guard supported else { return }
    guard authorized else { summary = "Разрешите системные будильники Luma"; return }
    let count = ledger.records.filter { !$0.pending }.count
    summary = count > 0 ? "AlarmKit · в очереди \(count) сигналов" : "AlarmKit · очередь пуста"
  }
  private func directory() throws -> URL {
    let folder = try FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LumaAlarmKit")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    return folder
  }
  private func load() throws {
    guard !loaded else { return }
    let file = try directory().appendingPathComponent("alarms.json")
    if FileManager.default.fileExists(atPath: file.path) {
      var value = try JSONDecoder().decode(SystemAlarmLedger.self, from: Data(contentsOf: file))
      guard value.schema == 1,
        Set(value.records.map(\.id)).count == value.records.count,
        Set(value.records.map(\.key)).count == value.records.count,
        value.records.allSatisfy({ $0.fireAt.timeIntervalSince1970.isFinite
          && $0.soundName.hasPrefix("luma-ak4-") && !$0.soundName.contains("/") }) else {
        throw AppError.message("Повреждён журнал системных будильников. Новые сигналы не поставлены.")
      }
      let changed = value.migrateToiPhoneOnly()
      ledger = value
      if changed {
        do { try persist() } catch { loaded = false; throw error }
      }
    }
    loaded = true
  }
  private func persist() throws {
    let file = try directory().appendingPathComponent("alarms.json")
    try JSONEncoder().encode(ledger).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  private func event(_ name: String, record: SystemAlarmRecord? = nil,
    lateBy: TimeInterval? = nil, detail: String? = nil) {
    guard let file = logURL else { return }
    var item: [String: Any] = ["event": name, "at": Date().timeIntervalSince1970,
      "application_state": UIApplication.shared.applicationState.rawValue]
    if let record { item["id"] = record.id.uuidString; item["kind"] = record.kind.rawValue
      item["scheduled_at"] = record.fireAt.timeIntervalSince1970; item["stop_at"] = record.stopAt.timeIntervalSince1970 }
    if let lateBy { item["late_by_seconds"] = lateBy }
    if let detail { item["detail"] = String(detail.prefix(300)) }
    guard var data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else { return }
    data.append(10)
    do {
      if FileManager.default.fileExists(atPath: file.path) {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
      } else { try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    } catch { /* Diagnostics must not prevent stopping an alarm. */ }
  }
}
