import SwiftUI
import UIKit

/// Explain the concrete four-second WAV AlarmKit test before scheduling.
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
        Text("AlarmKit · короткий сигнал").font(LumaStyle.font(24, "Medium"))
        LumaCard {
          VStack(alignment: .leading, spacing: 18) {
            step("1", "Разрешите будильники", "Умный будильник и непрямой метод используют AlarmKit. Нужен iPhone с iOS 26 или новее и разрешение на будильники.")
            step("2", "WAV длиной 4 секунды", "В AlarmKit передаётся отдельный короткий WAV с плавным затуханием. Оригинал вашей записи сохраняется.")
            step("3", "Сначала проверьте с блокировкой", "В настройках есть проба через 60 секунд. Заблокируйте iPhone и проверьте, затих ли сигнал без прикосновений.")
          }
        }
        Text("Это проверочная версия. Повтор звука самим AlarmKit на устройстве ещё не исключён. Если сигнал продолжится, нажмите «Остановить». Перед ночью проверьте пробу с заблокированным iPhone.")
          .font(LumaStyle.font(13)).foregroundStyle(LumaStyle.amber).lineSpacing(4)
          .accessibilityIdentifier("signal.alarmkitWaveTest")
        Group {
          Text("Apple Watch могут показывать системный сигнал AlarmKit. Проверьте звук iPhone и вибрацию часов на вашей паре устройств. Обычное уведомление Luma для сигнала не используется.")
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
