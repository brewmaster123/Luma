import UIKit
import UserNotifications

/// Installed before launch finishes. Foreground and background use the SAME
/// system sound; never start AVAudioPlayer here (that would double the cue).
final class LumaNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(_ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    guard notification.request.identifier.hasPrefix(FiniteCuePolicy.prefix) else {
      completionHandler([]); return
    }
    CueDiagnostics.event("foreground_presentation_requested", identifier: notification.request.identifier,
      detail: "system sound requested once; not an acoustic start callback")
    completionHandler([.sound, .banner, .list])
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void) {
    CueDiagnostics.event("notification_interaction", identifier: response.notification.request.identifier,
      detail: response.actionIdentifier)
    completionHandler()
  }
}
