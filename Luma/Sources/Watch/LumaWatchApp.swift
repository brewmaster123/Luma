import SwiftUI
import WatchKit
import UserNotifications

@MainActor final class LumaWatchDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
  func applicationDidFinishLaunching() {
    UNUserNotificationCenter.current().delegate = self
    _ = WatchCueStore.shared
  }
  func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
    WatchCueStore.shared.retainBackgroundTasks(backgroundTasks)
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    // Allow the system's one sound/haptic even with the watch app open.
    // No second WKInterfaceDevice.play call, hence no duplicate foreground haptic.
    completionHandler([.sound, .banner])
  }
}

@main @MainActor struct LumaWatchApp: App {
  @WKApplicationDelegateAdaptor(LumaWatchDelegate.self) private var delegate
  @StateObject private var store = WatchCueStore.shared
  var body: some Scene {
    WindowGroup {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Luma").font(.title2)
          Text(store.summary).font(.footnote)
          if let next = store.next {
            Text("Следующий: \(next.formatted(date: .omitted, time: .shortened))").font(.caption)
          }
          Button("Разрешить и обновить") { Task { await store.authorizeAndRefresh() } }
          Text("Расписание хранится на часах. Для сигнала часы должны быть надеты, разблокированы, а уведомления Luma разрешены в текущем фокусировании.")
            .font(.caption2).foregroundStyle(.secondary)
        }.padding(8)
      }.task { await store.refreshFromPhone() }
    }
  }
}
