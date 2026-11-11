import SwiftUI

@main
@MainActor
struct LumaApp: App {
  @UIApplicationDelegateAdaptor(LumaNotificationDelegate.self) private var notificationDelegate
  @StateObject private var model: AppModel
  @Environment(\.scenePhase) private var phase
  init() {
    let instance = AppModel()
    _model = StateObject(wrappedValue: instance)
    // Recover the system alarm ledger before the first screen is shown.
    Task { await instance.start() }
  }
  var body: some Scene {
    WindowGroup {
      PhoneRootView()
        .environmentObject(model)
        .preferredColorScheme(.dark)
        .task {
          await model.start()
          await model.resume()
        }
        .onChange(of: phase) { _, phase in
          if phase == .active { Task { await model.resume() } } else { model.suspend() }
        }
    }
  }
}
