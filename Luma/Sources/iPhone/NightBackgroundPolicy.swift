import Foundation
import UIKit

// 1.0 (the user's request, 19 Nov 2026): the silent night background switches itself on and off, and the
// Settings switch «Тишина» is gone, so nobody can switch it off by accident.
//
// The background (NightAudio) is what keeps Lumenoir running so that each AlarmKit signal falls silent by
// itself; stopping it always takes the whole queue with it (NightAudio.stopSafely → disarmForRuntimeLoss).
// iOS lets an app start playback only while it is on screen, so:
// - it is switched ON while the app is on screen, when a session runs or an enabled alarm is due within
//   one run (16 hours); saving an alarm, starting a session or a test switch it on as before;
// - it is LENGTHENED (never restarted) to cover a session's 16 hours, and, while the app is on screen,
//   an alarm that lies beyond the end of this run;
// - it is switched OFF, on screen or not, once nothing before the end of this run needs it: no session,
//   no queued or sounding signal, no test, no unconfirmed cancellation, no enabled alarm before its end,
//   and no «Непрямой метод после будильника» about to start;
// - a session ends by itself 16 hours after it began.
// Every call is one the old Settings switch, «Завершить сеанс» or saving an alarm already made; the signal
// engine itself is unchanged.

extension AppModel {
  /// Something needs the background between now and `end`.
  @MainActor func nightBackgroundNeeded(until end: Date, now: Date = Date()) -> Bool {
    if indirectRunning { return true }
    let ledger = systemAlarms.ledger
    // A signal waiting before the end, one sounding or not yet stopped, a test.
    if ledger.records.contains(where: { $0.fireAt <= end }) { return true }
    if systemAlarms.currentStopDeadline != nil { return true }
    // A cancellation that is not confirmed yet.
    if ledger.cancelAllRequested == true || !(ledger.cancelledOwners ?? []).isEmpty { return true }
    let flagged = SmartAlarmFollowUpPreference.ids()
    for alarm in state.alarms where alarm.enabled {
      if let next = alarm.next(after: now), next <= end { return true }
      // «Непрямой метод после будильника»: it has just rung, and its session may start in a moment.
      if flagged.contains(alarm.id), let last = alarm.next(after: now.addingTimeInterval(-180)), last <= now {
        return true
      }
    }
    return SmartAlarmFollowUp.shared.holdsNightBackground
  }

  /// Worth having the background now: a session younger than one run, or an enabled alarm within one run.
  @MainActor func nightBackgroundWanted(now: Date = Date()) -> Bool {
    let reach = NightAudio.longest - 60
    if let session = systemAlarms.indirectSession, now.timeIntervalSince(session.startedAt) < reach { return true }
    let latest = now.addingTimeInterval(reach)
    return state.alarms.contains { ($0.next(after: now) ?? .distantFuture) <= latest }
  }
}

@MainActor final class NightBackgroundPolicy {
  static let shared = NightBackgroundPolicy()

  private weak var model: AppModel?
  private var timer: Timer?
  private var attachedAt = Date.distantFuture
  private var working = false
  private var wasOn = false
  /// When the background was last seen to come on (by this policy or by a save, a session, a test).
  private var onSince = Date.distantPast
  private var idleSince: Date?
  private var retryAt = Date.distantPast
  private var toldError = false
  /// Recording or listening asked the background to step aside; it comes back once they are over.
  private var asideSince: Date?
  private var asideUsedAt = Date.distantPast

  func attach(_ model: AppModel) {
    guard self.model == nil else { return }
    self.model = model
    attachedAt = Date()
    wasOn = model.nightAudio.enabled
    if wasOn { onSince = Date() }
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.tick() }
    }
  }

  /// The person's own actions wait here, so they never meet a background halfway through stopping.
  func settled() async {
    while working { try? await Task.sleep(nanoseconds: 50_000_000) }
  }

  /// Look again at once (after «Завершить сеанс», a cancelled queue, an alarm switched off).
  func lookSoon() {
    Task { @MainActor in await self.tick() }
  }

  private func tick() async {
    guard let model, !working else { return }
    let now = Date()
    let night = model.nightAudio
    if let since = asideSince {
      if model.audio.recording || model.audio.playing { asideUsedAt = now }
      else if now.timeIntervalSince(max(since, asideUsedAt)) > 8 { asideSince = nil }
    }
    if night.enabled && !wasOn { onSince = now }
    if wasOn && !night.enabled {
      // It ended: its own end, an interruption, the lock screen, or this policy. Night shows «пока вне очереди».
      wasOn = false
      idleSince = nil
      working = true
      await model.refreshQueueAfterRainOff()
      working = false
      return
    }
    wasOn = night.enabled
    if await endLongSession(model, now) { return }
    if night.enabled {
      lengthen(model, now)
      await considerStop(model, now)
    } else {
      await considerStart(model, now)
    }
  }

  /// A session never outlives one run: it ends by itself 16 hours after it began.
  private func endLongSession(_ model: AppModel, _ now: Date) async -> Bool {
    guard let session = model.systemAlarms.indirectSession,
      now.timeIntervalSince(session.startedAt) >= NightAudio.longest,
      !model.busy, !model.systemAlarms.preparing else { return false }
    working = true
    await model.stopIndirectMethod()
    working = false
    CueDiagnostics.event("indirect_session_ended_after_16h")
    return true
  }

  /// Lengthens the run that plays now; nothing is restarted, so the queue stays as it is.
  private func lengthen(_ model: AppModel, _ now: Date) {
    let night = model.nightAudio
    guard night.ready, let until = night.until else { return }
    var target = until
    if let session = model.systemAlarms.indirectSession {
      target = max(target, session.startedAt.addingTimeInterval(NightAudio.longest))
    }
    if model.isForeground {
      let reach = now.addingTimeInterval(NightAudio.longest - 60)
      let beyond = model.state.alarms.contains {
        guard let next = $0.next(after: now) else { return false }
        return next > until && next <= reach
      }
      if beyond { target = max(target, now.addingTimeInterval(NightAudio.longest)) }
    }
    if target > until { night.extend(to: target) }
  }

  private func considerStart(_ model: AppModel, _ now: Date) async {
    idleSince = nil
    guard model.isForeground, UIApplication.shared.applicationState == .active else {
      toldError = false
      return
    }
    guard now.timeIntervalSince(attachedAt) >= 3, now >= retryAt, asideSince == nil,
      !model.busy, !model.systemAlarms.preparing,
      model.systemAlarms.supported, model.systemAlarms.authorized, model.systemAlarms.acceptedLimitations,
      !model.audio.recording, !model.audio.playing,
      model.nightBackgroundWanted(now: now) else { return }
    working = true
    defer { working = false }
    do {
      try await model.preparePhoneSignals()
      wasOn = model.nightAudio.enabled
      onSince = Date()
      toldError = false
      CueDiagnostics.event("night_background_auto_on")
    } catch {
      retryAt = Date().addingTimeInterval(60)
      if !toldError, model.message == nil { model.message = error.localizedDescription }
      toldError = true
    }
  }

  private func considerStop(_ model: AppModel, _ now: Date) async {
    let night = model.nightAudio
    guard night.ready, let until = night.until,
      // Just switched on: let what switched it on finish first (a save, a test, the readiness sheet).
      now.timeIntervalSince(onSince) >= 30,
      !model.busy, !model.systemAlarms.preparing, !model.audio.recording,
      !model.nightBackgroundNeeded(until: until, now: now),
      // On screen, an alarm that a start would cover keeps it on: no off and on again.
      !(model.isForeground && model.nightBackgroundWanted(now: now))
    else {
      idleSince = nil
      return
    }
    // Two looks at least 6 seconds apart must both say "not needed".
    guard let since = idleSince else { idleSince = now; return }
    guard now.timeIntervalSince(since) >= 6 else { return }
    idleSince = nil
    working = true
    defer { working = false }
    await model.stopNightAudio()
    wasOn = false
    CueDiagnostics.event("night_background_auto_off")
    await model.refreshQueueAfterRainOff()
  }

  /// Recording (a voice cue, a journal note) and listening to a journal note cannot share the audio with the
  /// background. They never take queued alarms away: while a session runs, or an alarm or a signal still needs
  /// the background (in this run, or an alarm within 16 hours), they are refused, as before 1.0. Otherwise the
  /// background, which nothing needs, is switched off at once instead of a few seconds later. Returns a
  /// refusal, or nil.
  func stepAside() async -> String? {
    guard let model else { return nil }
    await settled()
    let now = Date()
    asideSince = now
    asideUsedAt = now
    guard model.nightAudio.enabled else { return nil }
    if model.indirectRunning {
      asideSince = nil
      return tr("Пока идёт сеанс непрямого метода, запись и прослушивание недоступны.")
    }
    let end = model.nightAudio.until ?? now.addingTimeInterval(NightAudio.longest)
    if model.busy || model.systemAlarms.preparing {
      asideSince = nil
      return tr("Подождите: предыдущее действие ещё не закончено.")
    }
    if model.nightBackgroundNeeded(until: max(end, now), now: now) || model.nightBackgroundWanted(now: now) {
      asideSince = nil
      return tr("Пока впереди будильник или сигнал, запись и прослушивание недоступны. Они станут доступны после него или если выключить будильник.")
    }
    working = true
    defer { working = false }
    await model.stopNightAudio()
    wasOn = false
    idleSince = nil
    CueDiagnostics.event("night_background_stepped_aside")
    await model.refreshQueueAfterRainOff()
    return nil
  }
}
