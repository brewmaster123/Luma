import Foundation
import UIKit
#if canImport(AlarmKit)
import AlarmKit
import SwiftUI
#endif

@MainActor
final class PhoneAlarmService {
  struct Sound { let name: String; let duration: TimeInterval }
  struct Result { var scheduled: Set<UUID> = []; var warning: String? }
  private struct Record: Codable {
    var window: AlarmStopWindow
    var alarm: LumaAlarm?
    var sessionID: UUID?
    var cancelRequested: Bool?
  }
  var onWillSignal: (() -> Void)?
  var onSignalsFinished: (() -> Void)?
  var onStatus: ((UUID, String) -> Void)?
  var onError: ((String) -> Void)?
  private let cacheKey = "luma.system-alarm.configurations.v1"
  private let recordsKey = "luma.alarmkit.stop-windows.v1"
  private var records: [UUID: Record] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var leases: [UUID: UIBackgroundTaskIdentifier] = [:]
  private var observing: Task<Void, Never>?
  private var scheduling = Set<UUID>()

  init() {
    if let data = UserDefaults.standard.data(forKey: recordsKey),
       let restored = try? JSONDecoder().decode([UUID: Record].self, from: data) { records = restored }
  }
  var supported: Bool {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) { return true }
    #endif
    return false
  }
  var authorizationDescription: String {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      switch AlarmManager.shared.authorizationState {
      case .authorized: return "Будильники разрешены"
      case .denied: return "Разрешите будильники: Настройки iPhone → Luma"
      case .notDetermined: return "Нужно разрешение на будильники"
      @unknown default: return "Проверьте разрешение на будильники"
      }
    }
    #endif
    return "Для звуковых сигналов нужна iOS 26 или новее"
  }
  var hasAlertingAlarm: Bool {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *), let alarms = try? AlarmManager.shared.alarms {
      return alarms.contains { records[$0.id] != nil && $0.state == .alerting }
    }
    #endif
    return false
  }
  func requestPermission() async throws {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let manager = AlarmManager.shared
      let state = manager.authorizationState == .notDetermined
        ? try await manager.requestAuthorization() : manager.authorizationState
      guard state == .authorized else { throw AppError.message("Разрешите будильники: Настройки iPhone → Luma.") }
      return
    }
    #endif
    throw AppError.message("Все звуковые сигналы Luma используют AlarmKit. Нужна iOS 26 или новее.")
  }
  func start() {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *), observing == nil {
      // REM sessions resume paused after termination; remove their orphaned cues.
      for id in Array(records.keys) where records[id]?.alarm == nil { cancel(id) }
      reconcile()
      observing = Task { [weak self] in
        for await _ in AlarmManager.shared.alarmUpdates {
          guard !Task.isCancelled else { return }
          self?.reconcile()
        }
      }
    }
    #endif
  }
  func refresh() {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) { reconcile() }
    #endif
  }
  func cancelSession(_ sessionID: UUID) {
    for id in Array(records.keys) where records[id]?.sessionID == sessionID { cancel(id) }
  }
  func cancelPreviews() {
    for id in Array(records.keys) where records[id]?.alarm == nil && records[id]?.sessionID == nil { cancel(id) }
  }
  func cancelAll() { for id in Array(records.keys) { cancel(id) } }

  /// The same AlarmKit path is used for REM and previews. No notification/audio fallback.
  func cue(id: UUID, sessionID: UUID?, title: String, sound: Sound) async throws {
    try await requestPermission()
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      guard records[id] == nil else { return }
      let date = Date().addingTimeInterval(1)
      guard let window = AlarmStopWindow(startsAt: date, duration: sound.duration) else {
        throw AppError.message("Длительность звука должна быть не больше 28 секунд.")
      }
      records[id] = Record(window: window, alarm: nil, sessionID: sessionID)
      persist(); scheduling.insert(id)
      defer { scheduling.remove(id) }
      protect(id)
      do {
        guard let lease = leases[id], lease != .invalid else {
          throw AppError.message("Сигнал пропущен: iOS не выделила время для его автоматической остановки.")
        }
        _ = try await AlarmManager.shared.schedule(id: id,
          configuration: configuration(title: title, schedule: .fixed(date), sound: sound))
        // Cancellation may occur while schedule() suspends.
        guard records[id] != nil, records[id]?.cancelRequested != true else {
          try AlarmManager.shared.cancel(id: id); throw CancellationError()
        }
        arm(id)
        onStatus?(id, "Сигнал передан AlarmKit; ожидаем срабатывание")
      } catch { cancel(id); throw error }
    }
    #endif
  }
  func rebuild(_ alarms: [LumaAlarm], sound: (SignalSettings) throws -> Sound) async -> Result {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) { return await rebuildSystem(alarms, sound: sound) }
    #endif
    return Result(warning: alarms.contains { $0.enabled && $0.signal.output.phoneEnabled }
      ? "Для звуковых сигналов нужна iOS 26 или новее." : nil)
  }
  private func persist() {
    if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: recordsKey) }
  }
  private func release(_ id: UUID) {
    let hadLease = leases[id] != nil
    if let lease = leases.removeValue(forKey: id), lease != .invalid { UIApplication.shared.endBackgroundTask(lease) }
    if hadLease && leases.isEmpty { onSignalsFinished?() }
  }
  private func protect(_ id: UUID) {
    guard leases[id] == nil else { return }
    // Finite grace for work already executing; this cannot wake a suspended app.
    let lease = UIApplication.shared.beginBackgroundTask(withName: "Finish Luma signal") { [weak self] in
      MainActor.assumeIsolated { self?.expire(id) }
    }
    leases[id] = lease
    if lease != .invalid { onWillSignal?() }
  }
  private func expire(_ id: UUID) {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) { stop(id, expired: true) }
    #endif
    release(id)
  }
  @discardableResult
  private func cancel(_ id: UUID) -> Bool {
    // Keep cancellation intent if the system call fails; retry on resume.
    records[id]?.cancelRequested = true
    persist()
    tasks.removeValue(forKey: id)?.cancel()
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      do {
        if (try AlarmManager.shared.alarms).contains(where: { $0.id == id }) { try AlarmManager.shared.cancel(id: id) }
      } catch { release(id); onError?("Не удалось отменить сигнал: \(error.localizedDescription)"); return false }
    }
    #endif
    records.removeValue(forKey: id); persist(); release(id)
    return true
  }
  #if canImport(AlarmKit)
  @available(iOS 26.0, *)
  private func configuration(title: String, schedule: Alarm.Schedule, sound: Sound)
    -> AlarmManager.AlarmConfiguration<LumaAlarmMetadata> {
    let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title),
      stopButton: AlarmButton(text: "Остановить", textColor: .white, systemImageName: "stop.fill"))
    let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert),
      metadata: LumaAlarmMetadata(), tintColor: Color(red: 0.8, green: 0.74, blue: 0.97))
    return .alarm(schedule: schedule, attributes: attributes, sound: .named(sound.name))
  }
  @available(iOS 26.0, *)
  private func arm(_ id: UUID) {
    guard tasks[id] == nil, let record = records[id], record.cancelRequested != true else { return }
    let window = record.window
    tasks[id] = Task { [weak self] in
      do {
        while window.startsAt > Date() {
          try await Task.sleep(nanoseconds: UInt64(max(0, min(window.startsAt.timeIntervalSinceNow, 86400)) * 1_000_000_000))
        }
        guard let self, !Task.isCancelled, self.records[id]?.window == window else { return }
        if !window.hasExpired(at: Date()) {
          self.protect(id)
          try await Task.sleep(nanoseconds: UInt64(window.remaining(at: Date()) * 1_000_000_000))
        }
        guard !Task.isCancelled, self.records[id]?.window == window else { return }
        self.tasks.removeValue(forKey: id)
        self.stop(id)
      } catch { /* Do not disturb a replacement deadline on cancellation. */ }
    }
  }
  @available(iOS 26.0, *)
  private func stop(_ id: UUID, expired: Bool = false) {
    guard let record = records[id] else { release(id); return }
    tasks.removeValue(forKey: id)?.cancel()
    do {
      let manager = AlarmManager.shared
      var status = "AlarmKit уже завершил сигнал"
      if let current = try manager.alarms.first(where: { $0.id == id }) {
        if current.state == .alerting {
          try manager.stop(id: id)
          status = expired ? "Сигнал остановлен: завершилось фоновое время" : "Команда автоматической остановки выполнена"
        } else if record.alarm?.weekdays.isEmpty != false {
          try manager.cancel(id: id); status = "Сигнал отменён: время короткой подсказки истекло"
        } else { status = "AlarmKit не сообщает о звучании; следующее повторение сохранено" }
      }
      onStatus?(id, status)
      if let alarm = record.alarm, !alarm.weekdays.isEmpty,
         let date = alarm.next(after: Date()), let window = AlarmStopWindow(startsAt: date, duration: record.window.duration) {
        records[id]?.window = window
      } else { records.removeValue(forKey: id) }
      persist(); release(id)
      if records[id] != nil { arm(id) }
    } catch {
      // Keep the deadline for retry when the app next resumes.
      release(id)
      let message = "Не удалось автоматически остановить сигнал. Нажмите «Остановить»: \(error.localizedDescription)"
      onStatus?(id, message); onError?(message)
    }
  }
  @available(iOS 26.0, *)
  private func reconcile() {
    do {
      let current = try AlarmManager.shared.alarms
      let ids = Set(current.map(\.id))
      for id in Array(records.keys) where !ids.contains(id) && !scheduling.contains(id) {
        tasks.removeValue(forKey: id)?.cancel(); records.removeValue(forKey: id); release(id)
      }
      for alarm in current {
        guard var record = records[alarm.id], !scheduling.contains(alarm.id) else { continue }
        if record.cancelRequested == true { cancel(alarm.id); continue }
        if alarm.state == .alerting {
          if let model = record.alarm, let date = model.mostRecentOccurrence(at: Date()),
             let window = AlarmStopWindow(startsAt: date, duration: record.window.duration), window != record.window {
            tasks.removeValue(forKey: alarm.id)?.cancel(); record.window = window; records[alarm.id] = record
          }
          onStatus?(alarm.id, "AlarmKit сообщил о срабатывании; ожидаем остановку")
          if record.window.hasExpired(at: Date()) { stop(alarm.id); continue }
          protect(alarm.id)
        } else if record.window.hasExpired(at: Date()), let model = record.alarm, !model.weekdays.isEmpty,
                  let date = model.next(after: Date()), let window = AlarmStopWindow(startsAt: date, duration: record.window.duration) {
          tasks.removeValue(forKey: alarm.id)?.cancel(); records[alarm.id]?.window = window; release(alarm.id)
        }
        arm(alarm.id)
      }
      persist()
    } catch { onError?(error.localizedDescription) }
  }
  @available(iOS 26.0, *)
  private func rebuildSystem(_ alarms: [LumaAlarm], sound: (SignalSettings) throws -> Sound) async -> Result {
    let manager = AlarmManager.shared
    var result = Result()
    do {
      let existing = try manager.alarms
      let wanted = alarms.filter { $0.enabled && $0.signal.output.phoneEnabled }
      let wantedIDs = Set(wanted.map(\.id))
      var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
      for old in existing where !wantedIDs.contains(old.id) &&
        (records[old.id]?.alarm != nil || cache[old.id.uuidString] != nil) {
        if cancel(old.id) { cache.removeValue(forKey: old.id.uuidString) }
      }
      for alarm in AlarmPlanner.sorted(wanted, after: Date()) {
        if alarm.weekdays.isEmpty && alarm.onceAt <= Date() {
          // Also clean up an old v0.3 alarm already ringing during the migration.
          if existing.contains(where: { $0.id == alarm.id }) { cancel(alarm.id) }
          cache.removeValue(forKey: alarm.id.uuidString)
          continue
        }
        do {
          guard manager.authorizationState == .authorized else { throw AppError.message("Разрешите будильники в настройках iPhone.") }
          let tone = try sound(alarm.signal)
          guard let date = alarm.next(after: Date()), let window = AlarmStopWindow(startsAt: date, duration: tone.duration) else {
            throw AppError.message("Проверьте время и длительность звука.")
          }
          let fingerprint = ["autostop-v1", alarm.title, String(alarm.hour), String(alarm.minute),
            alarm.weekdays.sorted().map(String.init).joined(separator: ","),
            alarm.weekdays.isEmpty ? String(alarm.onceAt.timeIntervalSince1970) : "weekly", tone.name, String(tone.duration)]
            .map { Data($0.utf8).base64EncodedString() }.joined(separator: ":")
          if existing.contains(where: { $0.id == alarm.id }), cache[alarm.id.uuidString] == fingerprint,
             records[alarm.id] != nil, records[alarm.id]?.cancelRequested != true {
            result.scheduled.insert(alarm.id); arm(alarm.id); continue
          }
          if existing.contains(where: { $0.id == alarm.id }) { try manager.cancel(id: alarm.id) }
          tasks.removeValue(forKey: alarm.id)?.cancel(); release(alarm.id)
          let schedule: Alarm.Schedule
          if alarm.weekdays.isEmpty { schedule = .fixed(alarm.onceAt) }
          else {
            let weekdays: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
            let selected = alarm.weekdays.sorted().filter { (1...7).contains($0) }.map { weekdays[$0 - 1] }
            guard !selected.isEmpty else { throw AppError.message("Выберите дни повтора будильника.") }
            schedule = .relative(.init(time: .init(hour: alarm.hour, minute: alarm.minute), repeats: .weekly(selected)))
          }
          records[alarm.id] = Record(window: window, alarm: alarm, sessionID: nil); persist()
          scheduling.insert(alarm.id)
          defer { scheduling.remove(alarm.id) }
          _ = try await manager.schedule(id: alarm.id, configuration: configuration(title: alarm.title, schedule: schedule, sound: tone))
          guard records[alarm.id] != nil, records[alarm.id]?.cancelRequested != true else {
            try manager.cancel(id: alarm.id); throw CancellationError()
          }
          cache[alarm.id.uuidString] = fingerprint; result.scheduled.insert(alarm.id); arm(alarm.id)
        } catch {
          cancel(alarm.id); cache.removeValue(forKey: alarm.id.uuidString)
          result.warning = "Не удалось установить «\(alarm.title)»: \(error.localizedDescription)"
        }
      }
      cache = cache.filter { entry in UUID(uuidString: entry.key).map { wantedIDs.contains($0) } ?? false }
      UserDefaults.standard.set(cache, forKey: cacheKey)
    } catch { result.warning = error.localizedDescription }
    return result
  }
  #endif
}
#if canImport(AlarmKit)
@available(iOS 26.0, *)
private struct LumaAlarmMetadata: AlarmMetadata {}
#endif
