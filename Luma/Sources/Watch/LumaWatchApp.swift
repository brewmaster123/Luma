import SwiftUI
import WatchKit

@main
@MainActor
struct LumaWatchApp: App {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    init() {
        let instance = AppModel()
        _model = StateObject(wrappedValue: instance)
        // Also runs on system launches for HealthKit updates, without relying on a visible view.
        Task { await instance.start() }
    }
    var body: some Scene {
        WindowGroup {
            WatchRootView().environmentObject(model).preferredColorScheme(.dark)
                .task { if phase == .active { await model.resume() } }
                .onChange(of: phase) { _, next in
                    if next == .active { Task { await model.resume() } }
                    else { model.suspend() }
                }
        }
    }
}
