import SwiftUI

@main
@MainActor
struct LumaApp: App {
  @StateObject private var model = AppModel()
  @Environment(\.scenePhase) private var phase
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
