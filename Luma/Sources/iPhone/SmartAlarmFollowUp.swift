import Foundation
import UIKit

extension AppModel {
  /// 0.9.9: after the interface has switched the quiet rain off (end of a session, a deleted sound,
  /// a taken-back follow-up), the alarms on Night must show «пока вне очереди» again rather than look armed.
  /// The model's own return-to-foreground pass looks at the queue again; it is used only while the app
  /// is on screen. In the background the same pass runs by itself when the app comes back.
  @MainActor func refreshQueueAfterRainOff() async {
    guard UIApplication.shared.applicationState == .active else { return }
    await resume()
  }
}

/// 0.9.9, optional and off by default: «Непрямой метод после будильника».
/// Which smart alarms have it switched on is a UI-only preference, like IndirectMethodHelpPreference:
/// a list of alarm ids in UserDefaults. The alarm itself, the sound list and the signal ledger are stored
/// exactly as before, and older versions simply ignore the list.
enum SmartAlarmFollowUpPreference {
  static let key = "com.sevchlenko.luma.smartAlarm.indirectAfter.v1"

  static func ids(_ defaults: UserDefaults = .standard) -> Set<UUID> {
    Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
  }

  static func isOn(_ id: UUID) -> Bool { ids().contains(id) }

  static func set(_ id: UUID, _ on: Bool, _ defaults: UserDefaults = .standard) {
    var all = ids(defaults)
    if on { all.insert(id) } else { all.remove(id) }
    defaults.set(all.map(\.uuidString).sorted(), forKey: key)
  }
}

/// 1.0 (the user, 19 Nov 2026): the short note shown when an alarm with «Непрямой метод после будильника» is
/// saved — the volume set with the side buttons must not be all the way down. It is shown on every such save
/// until the person ticks «Больше не показывать». A UI-only preference like the one above; older versions
/// ignore it.
enum SmartAlarmVolumeNotePreference {
  static let key = "com.sevchlenko.luma.smartAlarm.volumeNote.skip.v1"
  static var skipped: Bool { UserDefaults.standard.bool(forKey: key) }
  static func skip() { UserDefaults.standard.set(true, forKey: key) }
}

/// When a smart alarm with the option on has rung and fallen silent, starts a session of the indirect
/// method with the current interval and sound, through the same model call as «Начать сеанс».
/// The session then runs until «Завершить сеанс», like any other (1.0: at most 16 hours).
///
/// Nothing about how alarms ring and stop changes. The coordinator only watches the signal ledger:
/// a smart signal that leaves the queue as "handled" has rung and stopped (by itself or by Stop).
/// While a signal sounds the quiet rain is interrupted, so the start waits until the rain plays again
/// (at most 90 s). It never starts the rain or any other sound itself, and never asks for anything:
/// the model call is made only when the rain is already playing and signals are already allowed.
/// It lives only while the app runs (the rain keeps it running); nothing is kept on disk, so a forced
/// quit can never start a session late.
@MainActor final class SmartAlarmFollowUp {
  static let shared = SmartAlarmFollowUp()

  private weak var model: AppModel?
  private var timer: Timer?
  /// Smart signals in the queue at the previous look, by key.
  private var previous: [String: SystemAlarmRecord] = [:]
  private var processed = Set<String>()
  private var pending: (record: SystemAlarmRecord, giveUpAt: Date)?
  private var working = false
  /// When the person last ended a session with «Завершить сеанс». An alarm that had already begun
  /// to ring by then does not start a new session: the person has just said the night's practice is over.
  private var sessionEndedAt: Date?

  /// 1.0: while a start is waiting or under way, the night background must not be switched off
  /// (NightBackgroundPolicy asks this).
  var holdsNightBackground: Bool { pending != nil || working }

  /// Called by «Завершить сеанс» once the session has really ended.
  func userEndedSession() {
    pending = nil
    sessionEndedAt = Date()
  }

  func attach(_ model: AppModel) {
    guard self.model == nil else { return }
    self.model = model
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.tick() }
    }
  }

  private func tick() async {
    guard let model, !working else { return }
    let now = Date()
    let ledger = model.systemAlarms.ledger
    let handled = Set(ledger.handledKeys)
    let current = Dictionary(ledger.records.filter { $0.kind == .smart }.map { ($0.key, $0) },
      uniquingKeysWith: { first, _ in first })
    let flagged = SmartAlarmFollowUpPreference.ids()
    // In the queue a second ago, gone now and marked handled: it has rung and stopped.
    for (key, record) in previous where current[key] == nil && handled.contains(key) && !processed.contains(key) {
      processed.insert(key)
      guard flagged.contains(record.ownerID), record.fireAt <= now, now.timeIntervalSince(record.fireAt) < 600,
        record.fireAt > (sessionEndedAt ?? .distantPast),
        model.state.alarms.contains(where: { $0.id == record.ownerID && $0.enabled }),
        model.nightAudio.enabled   // the rain was on: not a cold launch, not a cancelled queue
      else { continue }
      if pending == nil { pending = (record, now.addingTimeInterval(90)) }
      CueDiagnostics.event("smart_followup_armed", record: record)
    }
    previous = current
    guard let waiting = pending else { return }
    if model.indirectRunning {
      // A session is already running: it simply goes on.
      pending = nil
      CueDiagnostics.event("smart_followup_skipped_session_running", record: waiting.record)
      return
    }
    if !model.nightAudio.enabled {
      // The rain was switched off and the queue went with it: start nothing.
      pending = nil
      CueDiagnostics.event("smart_followup_dropped_no_rain", record: waiting.record)
      return
    }
    if now > waiting.giveUpAt {
      pending = nil
      CueDiagnostics.event("smart_followup_gave_up", record: waiting.record)
      if model.message == nil {
        model.message = "Непрямой метод после будильника не начат: ночной фон не возобновился."
      }
      return
    }
    // Wait (and look again in a second) until the start would neither start a sound nor ask for anything.
    guard model.nightAudio.ready, !model.busy, !model.systemAlarms.preparing,
      model.systemAlarms.currentStopDeadline == nil,
      model.systemAlarms.authorized, model.systemAlarms.acceptedLimitations,
      !model.audio.recording, !model.audio.playing else { return }
    pending = nil
    working = true
    defer { working = false }
    CueDiagnostics.event("smart_followup_start_attempt", record: waiting.record)
    // 1.0: the background switches itself on and off now (NightBackgroundPolicy), and it may be lengthened
    // while it plays, so its end is no longer a sign of a restart against the person's wish: the 0.9.9
    // take-back is gone.
    await model.requestIndirectMethodStart()
    CueDiagnostics.event(model.indirectRunning ? "smart_followup_started" : "smart_followup_failed",
      record: waiting.record)
  }
}
