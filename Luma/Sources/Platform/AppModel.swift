import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var archive = AppArchive()
    @Published private(set) var watchInstalled = false
    @Published private(set) var watchReachable = false
    @Published private(set) var evidence = REMEvidence.unavailable("Начните с подключения данных.")
    @Published private(set) var heart: [HeartSample] = []
    @Published private(set) var sleep: [SleepSegment] = []
    @Published private(set) var busy = false
    @Published private(set) var isForeground = false
    @Published var message: String?
    @Published var showOnboarding = false
    private let health = HealthService()
    private let notifications = NotificationService()
    private let bridge = WatchBridge()
    private let estimator = REMEstimator()
    private let engine = CueEngine()
    private var store: LocalStore?
    private var storageProblem: String?
    private var refreshing = false
    private var started = false
    private var processingCommands = false
    private var inbox: [SyncPacket] = []
    private var previewUntil: Date = .distantPast
    #if os(watchOS)
    private let motion = MotionService()
    private let haptics = FiniteHaptics()
    #endif

    init() {
        do {
            let store = try LocalStore(); archive = try store.load(); self.store = store
        } catch { storageProblem = error.localizedDescription; message = error.localizedDescription }
        showOnboarding = !archive.onboardingComplete
        bridge.onStatus = { [weak self] installed, reachable in
            self?.watchInstalled = installed; self?.watchReachable = reachable
        }
        bridge.onPacket = { [weak self] packet in self?.receive(packet) }
        notifications.onDelivery = { [weak self] id, date in self?.markDelivered(id: id, date: date) }
        health.onChange = { [weak self] in await self?.refreshSensors() }
        #if os(watchOS)
        bridge.onPreview = { [weak self] count in
            guard let self else { return "Приложение недоступно." }
            return self.playPreview(count: count)
        }
        #endif
    }

    var settings: NightSettings { archive.settings }
    var hasPlan: Bool { archive.planState == .armed || archive.planState == .awaitingWatch }
    var isCancelling: Bool { archive.pendingCommand?.kind == .cancel }
    var stateTitle: String {
        switch archive.planState {
        case .none: return "Ночь начинается спокойно"
        case .awaitingWatch: return isCancelling ? "Ожидаем отмену на часах" : "Ожидаем подтверждение часов"
        case .armed: return settings.mode == .scheduled ? "Сигналы запланированы" : "Эксперимент включён"
        case .finished: return "Окно сессии завершено"
        case .cancelled: return "Сессия отменена"
        case .failed: return "Сессию не удалось включить"
        }
    }
    var planForDisplay: NightPlan? { hasPlan ? archive.plan : settings.nextPlan(now: Date()) }

    func start() async {
        guard !started else { return }; started = true
        #if os(watchOS)
        if storageProblem != nil { await notifications.cancelOwnedRequests(); return }
        if archive.planState == .armed && archive.plan?.settings.mode == .experimentalREM { try? await health.beginObserving() }
        #endif
        await notifications.reconcileDeliveries()
        #if os(watchOS)
        await recoverInterruptedPreparation()
        #endif
        expireIfNeeded()
        if archive.onboardingComplete { await refreshSensors() }
    }

    func resume() async {
        isForeground = true
        #if os(watchOS)
        if archive.planState == .armed && archive.plan?.settings.mode == .experimentalREM { motion.startUpdates() }
        #endif
        await notifications.reconcileDeliveries()
        expireIfNeeded()
        if archive.onboardingComplete { await refreshSensors(); await refreshSleep() }
        #if os(watchOS)
        sendSnapshot()
        #endif
    }

    func suspend() {
        isForeground = false
        #if os(watchOS)
        motion.stopUpdates(); haptics.cancel()
        archive.decision.candidateSince = nil
        try? persist()
        #endif
    }

    func connectHealth() async {
        busy = true; defer { busy = false }
        do {
            try await health.requestReadAccess()
            #if os(watchOS)
            try await notifications.requestPermission()
            #endif
            archive.onboardingComplete = true; try persist(); showOnboarding = false
            await refreshSensors(); await refreshSleep()
        } catch { message = error.localizedDescription }
    }
    func requestSignalAccess() async {
        do { try await notifications.requestPermission(); message = "Запрос выполнен. Проверьте бесшумный режим и разрешение Luma в фокусировании «Сон»." }
        catch { message = error.localizedDescription }
    }
    func completeIntroduction() {
        archive.onboardingComplete = true
        do { try persist(); showOnboarding = false } catch { message = error.localizedDescription }
    }

    func changeSettings(_ edit: (inout NightSettings) -> Void) {
        guard !hasPlan else { message = "Сначала отмените текущую сессию, чтобы изменить её настройки."; return }
        edit(&archive.settings); archive.settings = archive.settings.validated()
        do { try persist() } catch { message = error.localizedDescription }
    }

    func arm() async {
        guard !busy, !hasPlan else { return }
        guard let plan = settings.nextPlan(now: Date()) else { message = "Не удалось определить время сессии."; return }
        busy = true; defer { busy = false }
        #if os(iOS)
        guard watchInstalled else {
            message = "Установите и откройте Luma на связанных Apple Watch. Затем вернитесь сюда."; return
        }
        let command = SyncPacket(kind: .arm, plan: plan)
        archive.plan = plan; archive.pendingCommand = command; archive.planState = .awaitingWatch
        do { try persist(); bridge.send(command) } catch { archive.planState = .failed; message = error.localizedDescription }
        #else
        do { try await activateOnWatch(plan); sendSnapshot() }
        catch { message = error.localizedDescription }
        #endif
    }

    func retrySync() {
        guard let command = archive.pendingCommand else { return }
        bridge.send(command)
        message = "Запрос повторно отправлен. Откройте Luma на часах для синхронизации."
    }

    func cancel() {
        guard let plan = archive.plan else { return }
        #if os(iOS)
        let command = SyncPacket(kind: .cancel, plan: plan)
        archive.pendingCommand = command; archive.planState = .awaitingWatch
        do { try persist(); bridge.send(command) } catch { message = error.localizedDescription }
        #else
        cancelOnWatch(planID: plan.id); sendSnapshot()
        #endif
    }

    func preview() async {
        #if os(iOS)
        do { try await bridge.preview(count: settings.cueCount.rawValue) }
        catch { message = error.localizedDescription }
        #else
        if let error = playPreview(count: settings.cueCount.rawValue) { message = error }
        #endif
    }

    func refreshSensors() async {
        guard !refreshing, Date() >= previewUntil else { return }
        refreshing = true; defer { refreshing = false }
        #if os(watchOS)
        if isForeground && archive.planState == .armed && archive.plan?.settings.mode == .experimentalREM { motion.startUpdates() }
        #endif
        expireIfNeeded()
        do {
            heart = try await health.heartSamples(now: Date())
            #if os(watchOS)
            let evaluation = estimator.evaluate(heart: heart, motion: motion.epochs, now: Date())
            evidence = evaluation
            guard archive.planState == .armed, let plan = archive.plan,
                  plan.settings.mode == .experimentalREM else { return }
            let requests = engine.decide(plan: plan, evidence: evaluation, now: Date(), memory: &archive.decision)
            try persist()
            guard !requests.isEmpty else { return }
            archive.records.append(contentsOf: requests.map { CueRecord(request: $0) })
            try persist()
            do {
                try await notifications.schedule(requests)
                guard archive.plan?.id == plan.id, archive.planState == .armed else { notifications.cancel(planID: plan.id); return }
                setRecordStatus(ids: requests.map(\.id), to: .scheduled)
                try persist(); sendSnapshot()
            } catch {
                notifications.cancel(planID: plan.id)
                if archive.plan?.id == plan.id, archive.planState == .armed {
                    setRecordStatus(ids: requests.map(\.id), to: .failed)
                    archive.planState = .failed; message = error.localizedDescription
                    try? persist(); sendSnapshot()
                }
            }
            #else
            if heart.isEmpty { evidence = .unavailable("Измерений пока нет: часы могли их не записать, или доступ закрыт.") }
            #endif
        } catch {
            evidence = .unavailable("Измерения сейчас недоступны. Сигнал по REM не подаётся.")
            #if os(watchOS)
            archive.decision.candidateSince = nil; try? persist()
            #endif
        }
    }

    func refreshSleep() async {
        do { sleep = try await health.sleepSegments(now: Date()) }
        catch { sleep = [] }
    }

    func saveDream(_ entry: DreamEntry) {
        var entry = entry
        entry.text = String(entry.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12_000))
        guard !entry.text.isEmpty || entry.noticedCue || entry.reportedLucidity else { return }
        if let index = archive.diary.firstIndex(where: { $0.id == entry.id }) { archive.diary[index] = entry }
        else { archive.diary.insert(entry, at: 0) }
        do { try persist() } catch { message = error.localizedDescription }
    }
    func deleteDream(id: UUID) {
        archive.diary.removeAll { $0.id == id }
        do { try persist() } catch { message = error.localizedDescription }
    }
    func deleteHistory() {
        guard !hasPlan else { message = "Сначала дождитесь подтверждения отмены сессии на часах."; return }
        archive.diary.removeAll(); archive.records.removeAll()
        do { try persist() } catch { message = error.localizedDescription }
    }
    func exportData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    private func persist() throws {
        guard let store, storageProblem == nil else {
            throw AppError.message(storageProblem ?? "Не удалось открыть локальное хранилище. Сессия не включена.")
        }
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        archive.records.removeAll { $0.scheduledAt < cutoff }
        archive.processedCommands = Array(archive.processedCommands.suffix(64))
        archive.commandReceipts = Array(archive.commandReceipts.suffix(64))
        try store.save(archive)
    }
    private func expireIfNeeded() {
        // iPhone awaits authoritative watch receipts. Never silently imply that an offline cancel succeeded.
        #if os(watchOS)
        guard archive.planState == .armed, let plan = archive.plan, Date() >= plan.windowEnd else { return }
        notifications.cancel(planID: plan.id)
        archive.planState = .finished; motion.stopUpdates()
        try? persist(); sendSnapshot()
        #endif
    }
    private func markDelivered(id: String, date: Date) {
        guard let index = archive.records.firstIndex(where: { $0.id == id }) else { return }
        archive.records[index].deliveredAt = date; archive.records[index].status = .deliveryObserved
        do { try persist() } catch { message = error.localizedDescription }
    }
    private func setRecordStatus(ids: [String], to status: CueStatus) {
        let identifiers = Set(ids)
        for index in archive.records.indices where identifiers.contains(archive.records[index].id) {
            if archive.records[index].status != .deliveryObserved { archive.records[index].status = status }
        }
    }
    private func mergeRecords(_ records: [CueRecord]) {
        for record in records.suffix(150) {
            if let index = archive.records.firstIndex(where: { $0.id == record.id }) { archive.records[index] = record }
            else { archive.records.append(record) }
        }
        archive.records.sort { $0.scheduledAt > $1.scheduledAt }
    }

    private func receive(_ packet: SyncPacket) {
        #if os(iOS)
        if packet.kind == .receipt {
            guard packet.replyTo == archive.pendingCommand?.id else { return }
            archive.pendingCommand = nil; archive.planState = packet.planState ?? .failed
            archive.lastCommandAt = max(archive.lastCommandAt, packet.sentAt)
            if let plan = packet.plan { archive.plan = plan; archive.settings = plan.settings }
            if let records = packet.records { mergeRecords(records) }
            if archive.planState == .failed { message = packet.message ?? "Часы не подтвердили сессию." }
            try? persist()
        } else if packet.kind == .snapshot, archive.pendingCommand == nil,
                  packet.sentAt > archive.lastCommandAt {
            archive.lastCommandAt = packet.sentAt; archive.plan = packet.plan
            archive.planState = packet.planState ?? .none
            if packet.planState == .armed, let plan = packet.plan { archive.settings = plan.settings }
            if let records = packet.records { mergeRecords(records) }
            try? persist()
        }
        #else
        guard packet.kind == .arm || packet.kind == .cancel else { return }
        inbox.append(packet)
        guard !processingCommands else { return }
        processingCommands = true
        Task {
            while !inbox.isEmpty { await processOnWatch(inbox.removeFirst()) }
            processingCommands = false
        }
        #endif
    }

    #if os(watchOS)
    private func playPreview(count: Int) -> String? {
        // Haptics interfere with optical heart-rate collection; discard the motion window and pause evaluation.
        motion.stopUpdates(); previewUntil = Date().addingTimeInterval(Double(count) * 1.5 + 5)
        archive.decision.candidateSince = nil
        return haptics.preview(count: count)
    }

    private func activateOnWatch(_ plan: NightPlan) async throws {
        if archive.plan?.id == plan.id && archive.planState == .armed { return }
        guard plan.isValid, plan.windowEnd > Date(),
              plan.windowStart < Date().addingTimeInterval(36 * 3600) else {
            throw AppError.message("План устарел. Выберите новое время на телефоне.")
        }
        try await notifications.checkPermission()
        if plan.settings.mode == .experimentalREM { try await health.beginObserving() }
        if let old = archive.plan, archive.planState == .armed { cancelOnWatch(planID: old.id) }
        archive.plan = plan; archive.settings = plan.settings; archive.planState = .armed
        archive.decision = DecisionMemory(); archive.decision.planID = plan.id
        do {
            if plan.settings.mode == .scheduled {
                let requests = try engine.scheduledRequests(plan: plan, now: Date())
                archive.decision.reservedBurst = true
                archive.records.append(contentsOf: requests.map { CueRecord(request: $0) })
                try persist() // Must succeed before any external notification request.
                try await notifications.schedule(requests)
                setRecordStatus(ids: requests.map(\.id), to: .scheduled)
            } else if isForeground { motion.startUpdates() }
            try persist()
        } catch {
            notifications.cancel(planID: plan.id); archive.planState = .failed
            setRecordStatus(ids: archive.records.filter { $0.planID == plan.id }.map(\.id), to: .failed)
            try? persist(); throw error
        }
    }

    private func cancelOnWatch(planID: UUID) {
        notifications.cancel(planID: planID)
        setRecordStatus(ids: archive.records.filter { $0.planID == planID && $0.scheduledAt > Date() }.map(\.id), to: .cancelled)
        if archive.plan?.id == planID {
            archive.planState = .cancelled; archive.decision.reservedBurst = true
            motion.stopUpdates(); haptics.cancel()
        }
        do { try persist() } catch { message = error.localizedDescription }
    }

    private func processOnWatch(_ packet: SyncPacket) async {
        if let receipt = archive.commandReceipts.last(where: { $0.replyTo == packet.id }) { bridge.send(receipt); return }
        guard packet.sentAt >= archive.lastCommandAt else {
            bridge.send(SyncPacket(kind: .receipt, plan: archive.plan, replyTo: packet.id, planState: .failed,
                                   message: "Этот запрос заменён более новым.")); return
        }
        do {
            guard let plan = packet.plan else { throw AppError.message("В запросе отсутствует план.") }
            archive.lastCommandAt = packet.sentAt; try persist()
            if packet.kind == .cancel { cancelOnWatch(planID: plan.id) }
            else { try await activateOnWatch(plan) }
            archive.processedCommands.append(packet.id)
            let receipt = SyncPacket(kind: .receipt, plan: archive.plan, replyTo: packet.id,
                                     planState: archive.planState, records: archive.records)
            archive.commandReceipts.append(receipt); try persist(); bridge.send(receipt)
        } catch {
            if packet.kind == .arm, let plan = packet.plan, archive.plan?.id == plan.id {
                cancelOnWatch(planID: plan.id); archive.planState = .failed
            }
            let receipt = SyncPacket(kind: .receipt, plan: packet.plan, replyTo: packet.id, planState: .failed,
                                     message: error.localizedDescription, records: archive.records)
            archive.commandReceipts.append(receipt); try? persist(); bridge.send(receipt)
        }
    }
    private func recoverInterruptedPreparation() async {
        guard archive.planState == .armed, let plan = archive.plan, plan.settings.mode == .scheduled else { return }
        let reserved = archive.records.filter { $0.planID == plan.id && $0.status == .reserved }
        guard !reserved.isEmpty else { return }
        let pending = await notifications.pendingIDs()
        if reserved.allSatisfy({ pending.contains($0.id) }) {
            setRecordStatus(ids: reserved.map(\.id), to: .scheduled)
        } else {
            cancelOnWatch(planID: plan.id); archive.planState = .failed
            message = "Подготовка сессии прервалась. Включите её заново."
        }
        try? persist()
    }
    private func sendSnapshot() {
        bridge.send(SyncPacket(kind: .snapshot, plan: archive.plan, planState: archive.planState,
                               records: archive.records))
    }
    #endif
}
