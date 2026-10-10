import SwiftUI
import WatchKit
import HealthKit

@main
@MainActor
struct LumaWatchApp: App {
  @WKApplicationDelegateAdaptor(ResearchWatchDelegate.self) private var delegate
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
          if next == .active { Task { await model.resume() } } else { model.suspend() }
        }
    }
  }
}

/// Fail closed after a crash: don't leave an unobserved sensor workout running.
/// A new user-started run recalibrates instead of replaying a previous REM event.
final class ResearchWatchDelegate: NSObject, WKApplicationDelegate {
  private let health = HKHealthStore()
  func handleActiveWorkoutRecovery() {
    health.recoverActiveWorkoutSession { session, _ in
      session?.end()
      session?.associatedWorkoutBuilder().discardWorkout()
    }
  }
}
