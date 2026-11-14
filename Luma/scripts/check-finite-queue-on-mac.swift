import Foundation

private enum CheckError: Error { case failed(String), injected }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw CheckError.failed(message) }
}

@MainActor private final class FakeAlarmBackend: ShortAlarmScheduling {
  var queue: [String: FiniteCueSnapshot] = [:]
  var deliveredItems: [FiniteCueSnapshot] = []
  var adds = 0
  var failAddAfterAdmission = false
  var failCancel = false
  var failQuery = false
  var stops: [String] = []
  var permission = true
  var pauseNextAdd = false
  var pauseNextPending = false
  private var addObserver: (count: Int, continuation: CheckedContinuation<Void, Never>)?
  private var addGate: CheckedContinuation<Void, Never>?
  private var pendingPaused = false
  private var pendingObserver: CheckedContinuation<Void, Never>?
  private var pendingGate: CheckedContinuation<Void, Never>?
  func requestAuthorization() async throws {}
  func access() async -> AlarmAccess {
    .init(supported: true, authorized: permission)
  }
  func pending() async throws -> [FiniteCueSnapshot] {
    if failQuery { throw CheckError.injected }
    if pauseNextPending {
      pauseNextPending = false; pendingPaused = true
      pendingObserver?.resume(); pendingObserver = nil
      await withCheckedContinuation { pendingGate = $0 }
    }
    return Array(queue.values)
  }
  func delivered() async -> [FiniteCueSnapshot] { deliveredItems }
  func add(_ record: SystemAlarmRecord) async throws {
    adds += 1
    queue[record.notificationID] = Self.snapshot(record)
    if let observer = addObserver, adds >= observer.count {
      observer.continuation.resume(); addObserver = nil
    }
    if pauseNextAdd {
      pauseNextAdd = false
      await withCheckedContinuation { addGate = $0 }
    }
    if failAddAfterAdmission { throw CheckError.injected }
  }
  func cancel(_ identifiers: [String], includingDelivered: Bool) async throws {
    guard !identifiers.isEmpty else { return }
    if failCancel { throw CheckError.injected }
    identifiers.forEach { queue[$0] = nil }
    if includingDelivered { deliveredItems.removeAll { identifiers.contains($0.identifier) } }
  }
  func stop(_ identifier: String) async throws {
    stops.append(identifier)
    try await cancel([identifier], includingDelivered: true)
  }
  func waitForAdd(count: Int = 1) async {
    if adds >= count { return }
    await withCheckedContinuation { addObserver = (count, $0) }
  }
  func releaseAdd() { addGate?.resume(); addGate = nil }
  func waitForPausedPending() async {
    if pendingPaused { return }
    await withCheckedContinuation { pendingObserver = $0 }
  }
  func releasePending() { pendingGate?.resume(); pendingGate = nil }
  static func snapshot(_ record: SystemAlarmRecord) -> FiniteCueSnapshot {
    .init(identifier: record.notificationID, key: record.key,
      fireAt: Date(timeIntervalSince1970: record.fireAt.timeIntervalSince1970),
      title: record.title, soundName: record.soundName, repeats: false, hasSound: true)
  }
}

@MainActor private final class Fixture {
  let directory: URL
  let suite = "LumaFiniteCueCheck.\(UUID())"
  let defaults: UserDefaults
  let backend = FakeAlarmBackend()
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("Luma-queue-check-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: FiniteCuePolicy.consentKey)
  }
  func dispose() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
  func service(cleanup: ((Bool) throws -> Void)? = nil,
    soundBuilder: ((URL) throws -> String)? = nil) -> SystemAlarmService {
    SystemAlarmService(scheduler: backend, directory: directory, defaults: defaults,
      legacyCleanup: cleanup ?? { _ in }, soundBuilder: soundBuilder ?? { _ in "luma-alarm-4.wav" }, notificationCleanup: {})
  }
  func save(_ ledger: SystemAlarmLedger) throws {
    try JSONEncoder().encode(ledger).write(to: directory.appendingPathComponent("alarms.json"), options: .atomic)
  }
  func disk() throws -> SystemAlarmLedger {
    try JSONDecoder().decode(SystemAlarmLedger.self, from: Data(contentsOf: directory.appendingPathComponent("alarms.json")))
  }
  func request(key: String = "one", owner: UUID = UUID(), kind: SystemAlarmKind = .smart,
    seconds: Double = 3600, source: String = "sound.wav", stopAfterSeconds: Int = 4) -> SystemAlarmRequest {
    .init(key: key, ownerID: owner, kind: kind, fireAt: Date().addingTimeInterval(seconds),
      title: "Luma", source: directory.appendingPathComponent(source), stopAfterSeconds: stopAfterSeconds)
  }
}

@main private struct FiniteQueueCheck {
  @MainActor static func main() async throws {
    let tests: [(String, @MainActor (Fixture) async throws -> Void)] = [
      ("duration setting updates all future kinds without touching native IDs or cadence", { f in
        let s = f.service()
        let requests = [SystemAlarmKind.smart, .indirect, .probe].enumerated().map {
          f.request(key: "kind.\($0.offset)", kind: $0.element)
        }
        _ = try await s.reconcile(requests, activeOwners: Set(requests.map(\.ownerID)))
        let ids = s.ledger.records.map(\.id), times = s.ledger.records.map(\.fireAt)
        try s.setFutureStopDuration(10)
        try require(s.ledger.records.map(\.id) == ids && s.ledger.records.map(\.fireAt) == times,
          "Duration changed native identity or cadence")
        try require(s.ledger.records.allSatisfy { $0.stopDurationSeconds == 10 }, "A mode kept four seconds")
        try require(f.backend.adds == 3 && f.backend.queue.count == 3, "Duration rescheduled native alarms")
        let restarted = f.service(); try await restarted.bootstrap()
        try require(restarted.ledger.records.map(\.stopDurationSeconds) == [10, 10, 10], "Duration lost on relaunch")
      }),
      ("duration reconciliation reuses accepted UUID", { f in
        let s = f.service(); var r = f.request(stopAfterSeconds: 10)
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        let id = s.ledger.records.first!.id
        r.stopAfterSeconds = 3
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        try require(s.ledger.records.first?.id == id && f.backend.adds == 1, "Duration caused re-admission")
        try require(s.ledger.records.first?.stopDurationSeconds == 3, "Request duration not applied")
      }),
      ("active ten-second cue keeps its deadline through settings and rebuild", { f in
        let current = f.request(key: "current", seconds: -6, stopAfterSeconds: 10)
        let future = f.request(key: "future", owner: current.ownerID)
        let record = SystemAlarmRecord(request: current, soundName: "luma-alarm-4.wav")
        var ledger = SystemAlarmLedger(); ledger.records = [record]; try f.save(ledger)
        var snapshot = FakeAlarmBackend.snapshot(record); snapshot.alerting = true
        f.backend.queue[record.notificationID] = snapshot
        let s = f.service(); var observed: Date?
        s.onAlertObserved = { observed = $0 }
        try await s.bootstrap()
        try s.setFutureStopDuration(3)
        _ = try await s.reconcile([future], activeOwners: [current.ownerID])
        try require(s.ledger.records.contains { $0.id == record.id && $0.stopAt == record.stopAt },
          "Active ten-second cue cancelled or shortened")
        try require(observed == record.stopAt && s.currentStopDeadline == record.stopAt,
          "Audio interruption lost the active deadline")
        try require(f.backend.stops.isEmpty && f.backend.queue[record.notificationID] != nil, "Early Stop")
      }),
      ("duration writes preserve the original ledger backup once", { f in
        let r = f.request(), record = SystemAlarmRecord(request: r, soundName: "luma-alarm-4.wav")
        var ledger = SystemAlarmLedger(); ledger.records = [record]; try f.save(ledger)
        let original = try Data(contentsOf: f.directory.appendingPathComponent("alarms.json"))
        f.backend.queue[record.notificationID] = FakeAlarmBackend.snapshot(record)
        let s = f.service(); try await s.bootstrap()
        try s.setFutureStopDuration(10); try s.setFutureStopDuration(3)
        let backup = try Data(contentsOf: f.directory.appendingPathComponent("alarms-before-duration-setting.json"))
        try require(backup == original, "Pre-upgrade bytes lost or backup overwritten")
      }),
      ("failed duration persistence restores memory and accepted native queue", { f in
        let s = f.service(), r = f.request()
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        let original = s.ledger.records, file = f.directory.appendingPathComponent("alarms.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var rejected = false
        do { try s.setFutureStopDuration(10) } catch { rejected = true }
        try require(rejected && s.ledger.records == original && f.backend.adds == 1,
          "Failed setting damaged the working queue")
      }),
      ("invalid and in-flight duration edits cannot change the queue", { f in
        f.backend.pauseNextAdd = true
        let s = f.service(), r = f.request()
        let planning = Task { @MainActor in try await s.reconcile([r], activeOwners: [r.ownerID]) }
        await f.backend.waitForAdd()
        var rejected = 0
        for duration in [2, 11, 10] {
          do { try s.setFutureStopDuration(duration) } catch { rejected += 1 }
        }
        f.backend.releaseAdd(); _ = try await planning.value
        try require(rejected == 3 && s.ledger.records.first?.stopDurationSeconds == 4,
          "Unsafe setting accepted during admission")
      }),
      ("shorter duration replaces the previously armed Stop task", { f in
        let s = f.service(), r = f.request(seconds: 2, stopAfterSeconds: 10)
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        let id = s.ledger.records.first!.notificationID
        try s.setFutureStopDuration(3)
        try await Task.sleep(nanoseconds: 5_500_000_000)
        try require(f.backend.stops == [id] && s.ledger.records.isEmpty,
          "Shorter duration retained the old ten-second timer")
      }),
      ("longer duration cancels the old shorter Stop task", { f in
        let s = f.service(), r = f.request(seconds: 2, stopAfterSeconds: 3)
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        try s.setFutureStopDuration(10)
        try await Task.sleep(nanoseconds: 5_500_000_000)
        try require(f.backend.stops.isEmpty && s.ledger.records.first?.stopDurationSeconds == 10,
          "Old shorter timer stopped the extended signal")
        try await s.stopAll()
      }),
      ("accepted cues survive reconciliation without duplicate adds", { f in
        let s = f.service(), r = f.request()
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        let id = s.ledger.records.first!.id
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        try require(f.backend.adds == 1 && s.ledger.records.first?.id == id, "Duplicate cue")
        try require(f.backend.queue.values.allSatisfy { !$0.repeats && $0.hasSound }, "Unbounded cue")
      }),
      ("relaunch keeps admitted IDs", { f in
        let r = f.request(), s = f.service()
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        let id = s.ledger.records.first!.id
        let restarted = f.service()
        _ = try await restarted.reconcile([r], activeOwners: [r.ownerID])
        try require(f.backend.adds == 1 && restarted.ledger.records.first?.id == id, "Relaunch replay")
      }),
      ("missing future request is rearmed instead of marked delivered", { f in
        let r = f.request(), s = f.service()
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        f.backend.queue.removeAll()
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        try require(f.backend.adds == 2 && !s.ledger.handledKeys.contains(r.key), "Lost future cue")
      }),
      ("reservation survives crash after system admission", { f in
        let r = f.request()
        let record = SystemAlarmRecord(request: r, soundName: "luma-alarm-4.wav")
        var ledger = SystemAlarmLedger(); ledger.records = [record]; try f.save(ledger)
        f.backend.queue[record.notificationID] = FakeAlarmBackend.snapshot(record)
        let s = f.service()
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        try require(f.backend.adds == 0 && s.ledger.records.first?.pending == false, "Reservation recovery")
      }),
      ("elapsed cue cannot block or replay before the next interval", { f in
        let old = f.request(key: "elapsed", seconds: -1800)
        var ledger = SystemAlarmLedger()
        ledger.records = [.init(request: old, soundName: "luma-alarm-4.wav")]
        try f.save(ledger)
        let next = f.request(key: "next", owner: old.ownerID)
        let s = f.service()
        _ = try await s.reconcile([old, next], activeOwners: [old.ownerID])
        try require(s.ledger.handledKeys.contains("elapsed"), "Elapsed cue not retired")
        try require(s.ledger.records.map(\.key) == ["next"] && f.backend.adds == 1, "Next interval blocked")
      }),
      ("legacy migration preserves interval and requires new disclosure", { f in
        var ledger = SystemAlarmLedger(); ledger.schema = 1
        let session = IndirectAlarmSession(settings: .init(intervalMinutes: 30), signal: .init())
        ledger.indirectSession = session
        ledger.records = [.init(request: f.request(owner: session.id, kind: .indirect), soundName: "luma-ak4-old.caf")]
        try f.save(ledger)
        f.defaults.removeObject(forKey: FiniteCuePolicy.consentKey)
        f.defaults.set(true, forKey: "luma.alarmkit.short-stop-consent.v1")
        var confirmed = false
        let s = f.service(cleanup: { required in confirmed = required })
        try await s.bootstrap()
        try require(confirmed && s.ledger.schema == 3 && s.ledger.records.isEmpty, "Migration not gated")
        try require(s.indirectSession == session && !s.acceptedLimitations, "Session or consent damaged")
      }),
      ("failed legacy cancellation blocks new cues and retains old records", { f in
        var ledger = SystemAlarmLedger(); ledger.schema = 1
        ledger.records = [.init(request: f.request(), soundName: "luma-ak4-old.caf")]; try f.save(ledger)
        let s = f.service(cleanup: { _ in throw CheckError.injected })
        do {
          _ = try await s.reconcile([f.request()], activeOwners: [])
          throw CheckError.failed("Unsafe migration accepted")
        } catch CheckError.injected {}
        let disk = try f.disk()
        try require(f.backend.adds == 0 && disk == ledger, "Legacy queue forgotten")
      }),
      ("schema 2 notification migration preserves future interval origin", { f in
        var ledger = SystemAlarmLedger(); ledger.schema = 2
        let session = IndirectAlarmSession(settings: .init(intervalMinutes: 30), signal: .init())
        ledger.indirectSession = session
        let future = f.request(key: "future", owner: session.id, kind: .indirect)
        ledger.records = [.init(request: future, soundName: "luma-cue4-old.caf")]
        try f.save(ledger)
        let s = f.service()
        _ = try await s.reconcile([future], activeOwners: [session.id])
        try require(s.ledger.schema == 3 && s.indirectSession == session, "Notification migration lost session")
        try require(s.ledger.records.map(\.key) == ["future"] && f.backend.adds == 1, "Future key lost")
      }),
      ("missing real audio runtime rejects new admission", { f in
        let s = f.service(), r = f.request()
        s.runtimeReady = { false }
        do { _ = try await s.reconcile([r], activeOwners: [r.ownerID]); throw CheckError.failed("Runtime gate bypassed") }
        catch is AppError {}
        try require(f.backend.adds == 0 && s.ledger.records.isEmpty, "Unsafe queue admitted")
      }),
      ("runtime loss disarms all IDs but retains interval origin", { f in
        let s = f.service()
        let session = IndirectAlarmSession(settings: .init(intervalMinutes: 30), signal: .init())
        try s.setIndirect(session)
        let r = f.request(owner: session.id, kind: .indirect)
        _ = try await s.reconcile([r], activeOwners: [session.id])
        try await s.disarmForRuntimeLoss()
        try require(s.indirectSession == session && f.backend.queue.isEmpty, "Runtime loss lost cadence or kept alarms")
      }),
      ("prearmed deadline removes overdue ID without alarm update callback", { f in
        let s = f.service(), r = f.request(seconds: 2)
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        let identifier = s.ledger.records.first!.notificationID
        try await Task.sleep(nanoseconds: 6_500_000_000)
        try require(f.backend.stops == [identifier] && f.backend.queue.isEmpty,
          "Deadline required an alarmUpdates callback")
      }),
      ("queue query failure retains admitted records and prevents rescheduling", { f in
        let r = f.request(), s = f.service()
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        let before = try f.disk()
        f.backend.failQuery = true
        do { try await s.refresh(); throw CheckError.failed("Query failure was hidden") }
        catch CheckError.injected {}
        let after = try f.disk()
        try require(before == after && f.backend.adds == 1, "Query failure became an empty queue")
      }),
      ("observed overdue alert stops only itself and preserves next interval", { f in
        let old = f.request(key: "due", seconds: -10)
        let next = f.request(key: "next", owner: old.ownerID)
        let first = SystemAlarmRecord(request: old, soundName: "luma-alarm-4.wav")
        let second = SystemAlarmRecord(request: next, soundName: "luma-alarm-4.wav")
        var ledger = SystemAlarmLedger(); ledger.records = [first, second]; try f.save(ledger)
        f.backend.queue[first.notificationID] = .init(identifier: first.notificationID,
          metadataVisible: false, alerting: true)
        f.backend.queue[second.notificationID] = .init(identifier: second.notificationID,
          metadataVisible: false, alerting: false)
        let s = f.service(); try await s.bootstrap()
        try require(f.backend.stops == [first.notificationID], "Wrong occurrence stopped")
        try require(s.ledger.handledKeys.contains("due") && s.ledger.records.map(\.key) == ["next"], "Series stopped")
        try require(f.backend.queue[second.notificationID] != nil, "Next occurrence removed")
      }),
      ("ambiguous add is cancelled before returning its error", { f in
        f.backend.failAddAfterAdmission = true
        let s = f.service(), r = f.request()
        do {
          _ = try await s.reconcile([r], activeOwners: [r.ownerID])
          throw CheckError.failed("Injected failure lost")
        } catch CheckError.injected {}
        try require(f.backend.queue.isEmpty && s.ledger.records.isEmpty, "Orphan after failed add")
      }),
      ("stop-all during await cannot resurrect a cue", { f in
        f.backend.pauseNextAdd = true
        let s = f.service(), r = f.request()
        let planning = Task { @MainActor in try await s.reconcile([r], activeOwners: [r.ownerID]) }
        await f.backend.waitForAdd()
        try await s.stopAll()
        try require(s.ledger.cancelAllRequested == true, "Tombstone cleared while add outstanding")
        f.backend.releaseAdd()
        do { _ = try await planning.value; throw CheckError.failed("Cancelled plan succeeded") }
        catch is CancellationError {}
        try require(f.backend.queue.isEmpty && s.ledger.records.isEmpty, "Cue resurrected after stop")
        try require(s.ledger.cancelAllRequested == nil, "Completed tombstone not cleared")
      }),
      ("stopping interval leaves an independent smart alarm intact", { f in
        let s = f.service(), smart = f.request(key: "smart")
        _ = try await s.reconcile([smart], activeOwners: [smart.ownerID])
        let session = IndirectAlarmSession(settings: .init(), signal: .init())
        try s.setIndirect(session)
        let interval = f.request(key: "interval", owner: session.id, kind: .indirect)
        f.backend.pauseNextAdd = true
        let planning = Task { @MainActor in
          try await s.reconcile([smart, interval], activeOwners: [smart.ownerID, session.id])
        }
        await f.backend.waitForAdd(count: 2)
        try await s.stopIndirect()
        f.backend.releaseAdd()
        do { _ = try await planning.value; throw CheckError.failed("Cancelled interval succeeded") }
        catch is CancellationError {}
        try require(s.indirectSession == nil && s.ledger.records.map(\.key) == ["smart"], "Smart alarm cancelled")
        try require(f.backend.queue.count == 1, "Unexpected pending cues")
      }),
      ("failed cancellation remains durable and finishes on relaunch", { f in
        let s = f.service(), r = f.request()
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        f.backend.failCancel = true
        do { try await s.stopAll(); throw CheckError.failed("Cancel failure ignored") }
        catch CheckError.injected {}
        let disk = try f.disk()
        try require(disk.cancelAllRequested == true, "Cancellation intention lost")
        f.backend.failCancel = false
        let restarted = f.service(); try await restarted.bootstrap()
        try require(restarted.ledger.records.isEmpty && f.backend.queue.isEmpty, "Cancellation retry failed")
      }),
      ("probe and smart alarms share the bounded AlarmKit queue", { f in
        let owner = UUID(), s = f.service()
        let probe = f.request(key: "probe", kind: .probe)
        _ = try await s.reconcile([probe], activeOwners: [probe.ownerID])
        let requests = (0..<100).map { f.request(key: "cue.\($0)", owner: owner, seconds: 3600 + Double($0) * 600) }
        _ = try await s.reconcile(requests, activeOwners: [owner])
        try require(s.ledger.records.count == 60 && f.backend.queue.count == 60, "App queue bound exceeded")
        try require(s.ledger.records.filter { $0.kind == .smart }.count == 59, "Probe reservation ignored")
      }),
      ("revoked AlarmKit permission does not prevent cancellation", { f in
        let s = f.service(), r = f.request()
        let other = f.request(key: "other-smart")
        _ = try await s.reconcile([r, other], activeOwners: [r.ownerID, other.ownerID])
        f.backend.permission = false
        do {
          _ = try await s.reconcile([other], activeOwners: [other.ownerID])
          throw CheckError.failed("Unauthorized add was not rejected")
        } catch is AppError {}
        try require(s.ledger.records.map(\.key) == ["other-smart"], "Disabled owner survived revoked permission")
        try await s.stopAll()
        try require(f.backend.queue.isEmpty && s.ledger.records.isEmpty, "Permission blocked cancellation")
      }),
      ("invalid replacement audio leaves accepted queue intact", { f in
        let s = f.service(soundBuilder: { url in
          if url.lastPathComponent == "bad.wav" { throw CheckError.injected }
          return "luma-alarm-4.wav"
        })
        let r = f.request()
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        let original = s.ledger.records
        var edited = r; edited.source = f.directory.appendingPathComponent("bad.wav")
        do { _ = try await s.reconcile([edited], activeOwners: [r.ownerID]); throw CheckError.failed("Bad audio accepted") }
        catch CheckError.injected {}
        try require(s.ledger.records == original && f.backend.queue.count == 1, "Working queue damaged")
      }),
      ("overlapping rebuild cannot add duplicate alarms", { f in
        f.backend.pauseNextAdd = true
        let s = f.service(), r = f.request()
        let first = Task { @MainActor in try await s.reconcile([r], activeOwners: [r.ownerID]) }
        await f.backend.waitForAdd()
        var rejected = false
        do { _ = try await s.reconcile([r], activeOwners: [r.ownerID]) } catch { rejected = true }
        f.backend.releaseAdd()
        _ = try await first.value
        try require(rejected && f.backend.adds == 1 && f.backend.queue.count == 1, "Concurrent duplicate")
      }),
      ("concurrent bootstrap shares one legacy migration", { f in
        var cleanupCalls = 0
        let s = f.service(cleanup: { _ in cleanupCalls += 1 })
        async let first: Void = s.bootstrap()
        async let second: Void = s.bootstrap()
        _ = try await (first, second)
        try require(cleanupCalls == 1, "Repeated migration")
      }),
      ("stop during bootstrap cannot rearm stale caller input", { f in
        f.backend.pauseNextPending = true
        let s = f.service(), r = f.request()
        let planning = Task { @MainActor in try await s.reconcile([r], activeOwners: [r.ownerID]) }
        await f.backend.waitForPausedPending()
        try await s.stopAll()
        f.backend.releasePending()
        do { _ = try await planning.value; throw CheckError.failed("Stale bootstrap input accepted") }
        catch is CancellationError {}
        try require(f.backend.adds == 0 && f.backend.queue.isEmpty, "Stopped cue rearmed before admission")
      }),
      ("deleted owner cannot return from an outstanding add", { f in
        let s = f.service(), keep = f.request(key: "keep")
        _ = try await s.reconcile([keep], activeOwners: [keep.ownerID])
        let removed = f.request(key: "delete")
        f.backend.pauseNextAdd = true
        let planning = Task { @MainActor in
          try await s.reconcile([keep, removed], activeOwners: [keep.ownerID, removed.ownerID])
        }
        await f.backend.waitForAdd(count: 2)
        try await s.cancelOwner(removed.ownerID)
        f.backend.releaseAdd()
        do { _ = try await planning.value; throw CheckError.failed("Deleted owner admitted") }
        catch is CancellationError {}
        try require(s.ledger.records.map(\.key) == ["keep"] && f.backend.queue.count == 1, "Deleted alarm resurrected")
      }),
      ("unexpected repeating request is replaced with a finite cue", { f in
        let r = f.request()
        var ledger = SystemAlarmLedger()
        let record = SystemAlarmRecord(request: r, soundName: "luma-alarm-4.wav")
        ledger.records = [record]; try f.save(ledger)
        var corrupt = FakeAlarmBackend.snapshot(record); corrupt.repeats = true
        f.backend.queue[record.notificationID] = corrupt
        let s = f.service()
        _ = try await s.reconcile([r], activeOwners: [r.ownerID])
        try require(f.backend.adds == 1 && f.backend.queue.values.allSatisfy { !$0.repeats }, "Repeat retained")
      })
    ]
    for (name, test) in tests {
      let fixture = try Fixture()
      do { try await test(fixture); fixture.dispose(); print("PASS: \(name)") }
      catch { fixture.dispose(); print("FAIL: \(name): \(error)"); throw error }
    }
    print("PASS: \(tests.count) queue integration scenarios with a fake system adapter; no physical-device claims.")
  }
}
