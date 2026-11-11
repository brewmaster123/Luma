import SwiftUI
import UIKit

/// Explain notification settings that determine whether a finite cue is audible.
struct SignalReadinessView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let continueTitle: String
  var requiresPermission = true
  var onReady: () -> Void = {}
  @State private var working = false
  @State private var error: String?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Image(systemName: "alarm.waves.left.and.right").font(.system(size: 25))
            .foregroundStyle(LumaStyle.lavender)
          Spacer()
          Button { dismiss() } label: {
            Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("Закрыть").disabled(working)
        }
        Text("Короткие сигналы Luma").font(LumaStyle.font(24, "Medium"))
        LumaCard {
          VStack(alignment: .leading, spacing: 18) {
            step("1", "Разрешите уведомления", "Включите уведомления Luma, звуки и показ на экране блокировки. Они могут приходить, когда приложение закрыто.")
            step("2", "Один короткий звук", "Каждая подсказка использует отдельный звук длиной 4 секунды с плавным завершением. Исходная голосовая запись сохраняется.")
            step("3", "Сначала проверьте с блокировкой", "В настройках есть проба через 60 секунд. Заблокируйте iPhone и проверьте, затих ли сигнал без прикосновений.")
          }
        }
        Text("Для звука выключите беззвучный режим, проверьте громкость уведомлений и разрешите Luma в нужном Focus, включая «Сон». Выключите сводку уведомлений для Luma. Эти настройки могут заглушить или задержать сигнал. Проверка на вашем iPhone обязательна.")
          .font(LumaStyle.font(13)).foregroundStyle(LumaStyle.amber).lineSpacing(4)
          .accessibilityIdentifier("signal.notificationLimitations")
        Group {
          Text("С подключёнными Apple Watch система обычно направляет уведомление на часы вместо заблокированного iPhone. Для сигнала на iPhone выключите отражение уведомлений Luma в приложении Watch и проверьте результат. Одновременный сигнал на обоих устройствах не гарантируется.")
            .font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
        }
        Text(model.systemAlarms.summary).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
        if let error { Text(error).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.amber) }
        Button {
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
          Label("Настройки Luma в iPhone", systemImage: "arrow.up.forward.square")
            .font(LumaStyle.font(13, "Medium")).frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(LumaStyle.lavender)
        Button {
          guard !working else { return }
          working = true
          Task { @MainActor in
            defer { working = false }
            do {
              if requiresPermission { try await model.preparePhoneSignals(acceptLimitations: true) }
              onReady(); dismiss()
            } catch { self.error = error.localizedDescription }
          }
        } label: {
          HStack { if working { ProgressView() }; Text(working ? "Подготавливаем…" : continueTitle) }
        }.buttonStyle(PrimaryButtonStyle()).disabled(working || !model.systemAlarms.supported)
          .accessibilityIdentifier("signal.continue")
      }.padding(24)
    }.foregroundStyle(LumaStyle.text).background(LumaStyle.background)
      .presentationDetents([.large]).presentationDragIndicator(.visible)
      .presentationCornerRadius(28).interactiveDismissDisabled(working)
      .task { await model.refreshAlarmAccess() }
  }
  private func step(_ number: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(number).font(LumaStyle.font(12, "SemiBold"))
        .foregroundStyle(LumaStyle.lavender).frame(width: 26, height: 26)
        .background(LumaStyle.lavender.opacity(0.1), in: Circle())
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(LumaStyle.font(14, "SemiBold"))
        Text(detail).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
      }.fixedSize(horizontal: false, vertical: true)
    }
  }
}
