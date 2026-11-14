import Foundation
#if os(iOS) && canImport(AlarmKit)
import AlarmKit
import ActivityKit
import AppIntents
import SwiftUI

@available(iOS 26.0, *)
struct LumaAlarmMetadata: AlarmMetadata {
  var kind: String
  var soundSeconds: Double = 4
}

/// Manual system Stop button. It is not an alarm-fired or sound-EOF callback.
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
      let alarms = try manager.alarms
      if alarms.contains(where: { $0.id == id }) { try manager.stop(id: id) }
      CueDiagnostics.event("manual_alarmkit_stop", identifier: id.uuidString)
    }
    return .result()
  }
}
#endif

/// Single AlarmKit route for smart alarms, interval occurrences and probes.
/// The WAV ends after 88200 samples; OS-level replay remains a device test.
@MainActor final class AlarmKitScheduler: ShortAlarmScheduling {
  private var updates: Task<Void, Never>?
  private var updateHandler: (@MainActor () -> Void)?
  var supported: Bool {
    #if os(iOS) && canImport(AlarmKit)
    if #available(iOS 26.0, *) { return true }
    #endif
    return false
  }
  func requestAuthorization() async throws {
    #if os(iOS) && canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let state = try await AlarmManager.shared.requestAuthorization()
      guard state == .authorized else {
        throw AppError.message("Разрешите будильники Luma в настройках iPhone → Приложения → Luma.")
      }
      return
    }
    #endif
    throw unavailable()
  }
  func access() async -> AlarmAccess {
    #if os(iOS) && canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      return .init(supported: true, authorized: AlarmManager.shared.authorizationState == .authorized)
    }
    #endif
    return .init(supported: false, authorized: false)
  }
  func pending() async throws -> [FiniteCueSnapshot] {
    #if os(iOS) && canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let alarms = try AlarmManager.shared.alarms
      return alarms.map {
        FiniteCueSnapshot(identifier: FiniteCuePolicy.identifier(for: $0.id),
          metadataVisible: false, alerting: $0.state == .alerting)
      }
    }
    #endif
    throw unavailable()
  }
  func add(_ record: SystemAlarmRecord) async throws {
    guard record.fireAt.timeIntervalSinceNow > 1,
      FiniteCuePolicy.validSoundName(record.soundName),
      let source = try? AlarmKitSoundBuilder.soundURL(for: record.soundName),
      AlarmKitSoundBuilder.valid(source) else {
      throw AppError.message("AlarmKit не получил проверенный WAV длиной четыре секунды. Сигнал не поставлен.")
    }
    #if os(iOS) && canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let stop = AlarmButton(text: "Остановить", textColor: .white, systemImageName: "stop.fill")
      let alert = AlarmPresentation.Alert(
        title: LocalizedStringResource(stringLiteral: record.title),
        stopButton: stop, secondaryButton: nil, secondaryButtonBehavior: nil)
      let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert),
        metadata: LumaAlarmMetadata(kind: record.kind.rawValue),
        tintColor: Color(red: 0.72, green: 0.68, blue: 0.98))
      // No snooze/countdown/repeating schedule and no default sound fallback.
      // Sound duration is encoded in the WAV; metadata is not an OS timeout.
      let configuration = AlarmManager.AlarmConfiguration<LumaAlarmMetadata>.alarm(
        schedule: .fixed(record.fireAt), attributes: attributes,
        stopIntent: LumaStopAlarmIntent(id: record.id), sound: .named(record.soundName))
      CueDiagnostics.event("alarmkit_schedule_attempt", record: record,
        detail: "WAV \(record.soundName), 88200 frames, no embedded loop metadata")
      _ = try await AlarmManager.shared.schedule(id: record.id, configuration: configuration)
      return
    }
    #endif
    throw unavailable()
  }
  func cancel(_ identifiers: [String], includingDelivered: Bool) async throws {
    guard !identifiers.isEmpty else { return }
    let ids = try identifiers.map(self.id)
    #if os(iOS) && canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let manager = AlarmManager.shared
      let current = Set(try manager.alarms.map(\.id))
      for id in ids where current.contains(id) {
        do { try manager.cancel(id: id) }
        catch { if try manager.alarms.contains(where: { $0.id == id }) { throw error } }
      }
      let remaining = Set(try manager.alarms.map(\.id))
      guard remaining.isDisjoint(with: ids) else {
        throw AppError.message("AlarmKit ещё не подтвердил отмену прежнего сигнала.")
      }
      return
    }
    #endif
    throw unavailable()
  }
  func stop(_ identifier: String) async throws {
    let alarmID = try self.id(identifier)
    #if os(iOS) && canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      let manager = AlarmManager.shared
      let current = try manager.alarms
      if let alarm = current.first(where: { $0.id == alarmID }) {
        do {
          if alarm.state == .alerting { try manager.stop(id: alarmID) }
          else { try manager.cancel(id: alarmID) }
        } catch {
          if try manager.alarms.contains(where: { $0.id == alarmID }) { throw error }
        }
      }
      let afterStop = try manager.alarms
      if afterStop.contains(where: { $0.id == alarmID }) { try manager.cancel(id: alarmID) }
      let verified = try manager.alarms
      guard !verified.contains(where: { $0.id == alarmID }) else {
        throw AppError.message("AlarmKit не подтвердил остановку сигнала.")
      }
      return
    }
    #endif
    throw unavailable()
  }
  func setUpdateHandler(_ handler: (@MainActor () -> Void)?) {
    updateHandler = handler
    guard handler != nil else { updates?.cancel(); updates = nil; return }
    guard updates == nil else { return }
    #if os(iOS) && canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      updates = Task { @MainActor [weak self] in
        for await _ in AlarmManager.shared.alarmUpdates {
          guard !Task.isCancelled, let self else { return }
          self.updateHandler?()
        }
      }
    }
    #endif
  }
  private func id(_ identifier: String) throws -> UUID {
    guard identifier.hasPrefix(FiniteCuePolicy.prefix),
      let id = UUID(uuidString: String(identifier.dropFirst(FiniteCuePolicy.prefix.count))) else {
      throw AppError.message("Повреждён идентификатор системного будильника.")
    }
    return id
  }
  private func unavailable() -> AppError {
    .message("Для сигналов через AlarmKit нужен iPhone с iOS 26 или новее.")
  }
}
