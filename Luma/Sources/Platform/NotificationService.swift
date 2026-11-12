import Foundation
import UserNotifications

/// Cleanup only. New smart and indirect signals are never notification requests.
@MainActor final class NotificationService {
  struct Sound { let name: String; let duration: TimeInterval }
  func removeLegacySignals() async throws {
    let center = UNUserNotificationCenter.current()
    let pending = await center.pendingNotificationRequests()
    let delivered = await center.deliveredNotifications()
    let ids = Set(pending.map(\.identifier).filter { $0.hasPrefix("luma.") }
      + delivered.map { $0.request.identifier }.filter { $0.hasPrefix("luma.") })
    guard !ids.isEmpty else { return }
    center.removePendingNotificationRequests(withIdentifiers: Array(ids))
    center.removeDeliveredNotifications(withIdentifiers: Array(ids))
    let remaining = await center.pendingNotificationRequests()
    guard remaining.allSatisfy({ !$0.identifier.hasPrefix("luma.") }) else {
      throw AppError.message("Старая очередь уведомлений ещё не отменена. Откройте Luma повторно перед запуском AlarmKit.")
    }
    CueDiagnostics.event("legacy_notifications_empty_verified", detail: "removed \(ids.count)")
  }
}
