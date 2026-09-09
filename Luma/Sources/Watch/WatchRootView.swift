import SwiftUI

struct WatchRootView: View {
  @EnvironmentObject private var model: AppModel
  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Image(systemName: "moon.stars.fill").font(.system(size: 30)).foregroundStyle(
          Color(red: 0.8, green: 0.74, blue: 0.96))
        Text("luma").font(.custom("Manrope-SemiBold", size: 23))
        Text(model.watchStatus).font(.custom("Manrope-Regular", size: 12)).multilineTextAlignment(
          .center
        ).foregroundStyle(.secondary)
        Text("Будильников в очереди: \(model.queuedAlarmIDs.count)").font(
          .custom("Manrope-Regular", size: 11)
        ).foregroundStyle(.secondary)
        Button("Проба сигнала") { Task { await model.preview() } }.tint(.purple)
        Button("Разрешить уведомления") { Task { await model.requestSignalAccess() } }
        Button("Разрешить данные сна") { Task { await model.connectHealth() } }
        Button("Остановить REM на часах", role: .destructive) { Task { await model.endSession() } }
        Text(
          "Сигналы заканчиваются сами. Для вибрации без звука включите бесшумный режим часов. Доставка в фоне зависит от watchOS."
        ).font(.custom("Manrope-Regular", size: 10)).foregroundStyle(.secondary)
      }.padding(.horizontal, 6)
    }.font(.custom("Manrope-Medium", size: 13))
      .alert(
        "Luma",
        isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
      ) {
        Button("Понятно") { model.message = nil }
      } message: {
        Text(model.message ?? "")
      }
  }
}
