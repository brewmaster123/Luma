import Foundation
import UserNotifications

/// Migration cleanup only. All current phone alarms are scheduled by AlarmKit.
@MainActor final class NotificationService {
  struct Sound { let name: String; let duration: TimeInterval }
  func cancelPrefix(_ prefix: String) async {
    let center = UNUserNotificationCenter.current()
    let pending = await center.pendingNotificationRequests()
    let delivered = await center.deliveredNotifications()
    center.removePendingNotificationRequests(withIdentifiers:
      pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
    center.removeDeliveredNotifications(withIdentifiers:
      delivered.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) })
  }
}
