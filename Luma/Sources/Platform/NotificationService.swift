import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var cancelledPlans: Set<UUID> = []
    var onDelivery: ((String, Date) -> Void)?
    override init() { super.init(); center.delegate = self }

    func requestPermission() async throws {
        let accepted = try await center.requestAuthorization(options: [.alert, .sound])
        guard accepted else { throw AppError.message("Разрешите уведомления Luma в настройках часов.") }
    }

    func checkPermission() async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized,
              settings.alertSetting == .enabled, settings.soundSetting == .enabled else {
            throw AppError.message("На часах нужны разрешённые уведомления со звуком/тактильным сигналом. Проверьте также режим «Сон».")
        }
    }

    func schedule(_ requests: [CueRequest]) async throws {
        try await checkPermission()
        guard (1...5).contains(requests.count) else { throw AppError.message("Некорректное число сигналов.") }
        let ids = requests.map(\.id)
        do {
            for cue in requests {
                guard !cancelledPlans.contains(cue.planID) else { throw CancellationError() }
                let delay = cue.fireAt.timeIntervalSinceNow
                guard delay >= 1 else { throw AppError.message("Время сигнала уже прошло. Выберите новое время.") }
                let content = UNMutableNotificationContent()
                content.title = "Luma"
                content.body = "Короткая подсказка. Можно продолжать отдыхать."
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.threadIdentifier = cue.planID.uuidString
                content.userInfo = ["lumaCueID": cue.id, "lumaPlanID": cue.planID.uuidString]
                // No repeating trigger, no AlarmKit/Smart Alarm, no dismiss action needed.
                // watchOS owns the tap pattern and can suppress/group notifications.
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
                try await center.add(UNNotificationRequest(identifier: cue.id, content: content, trigger: trigger))
                guard !cancelledPlans.contains(cue.planID) else { throw CancellationError() }
            }
        } catch {
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
            throw error
        }
    }

    func cancel(planID: UUID) {
        cancelledPlans.insert(planID)
        let ids = (0..<5).map { "luma.\(planID.uuidString).\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func reconcileDeliveries() async {
        for item in await center.deliveredNotifications() {
            guard let id = item.request.content.userInfo["lumaCueID"] as? String else { continue }
            onDelivery?(id, item.date)
        }
    }
    func pendingIDs() async -> Set<String> {
        let requests = await center.pendingNotificationRequests()
        return Set(requests.map(\.identifier))
    }
    func cancelOwnedRequests() async {
        let pending = await pendingIDs()
        let ids = pending.filter { $0.hasPrefix("luma.") }
        center.removePendingNotificationRequests(withIdentifiers: Array(ids))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier; let date = notification.date
        Task { @MainActor [weak self] in self?.onDelivery?(id, date) }
        completion([.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse,
                                           withCompletionHandler completion: @escaping () -> Void) {
        let id = response.notification.request.identifier; let date = response.notification.date
        Task { @MainActor [weak self] in self?.onDelivery?(id, date) }
        completion()
    }
}
