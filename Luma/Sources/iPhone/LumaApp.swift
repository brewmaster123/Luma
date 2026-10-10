import SwiftUI

@main
@MainActor
struct LumaApp: App {
  @StateObject private var model: AppModel
  @Environment(\.scenePhase) private var phase
  init() {
    let instance = AppModel()
    _model = StateObject(wrappedValue: instance)
    // Register session mirroring and wire handlers on background launches too.
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
