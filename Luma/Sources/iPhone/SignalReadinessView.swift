import SwiftUI
import UIKit

/// Actual authorization and a concrete disclosure before an experimental system
/// alarm is armed. No claim that four-second audio disables AlarmKit looping.
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
        Text("Системные сигналы Luma").font(LumaStyle.font(24, "Medium"))
        LumaCard {
          VStack(alignment: .leading, spacing: 18) {
            step("1", "Через AlarmKit", "Системные сигналы iPhone проходят через беззвучный режим и фокусирование. Нужны iOS 26 или новее и разрешение на будильники.")
            step("2", "Четырёхсекундный звук", "Luma готовит отдельную копию мелодии или вашей записи длиной 4 секунды и отправляет команду остановки AlarmKit через 4 секунды.")
            step("3", "Сначала проверьте с блокировкой", "В настройках есть проба через 60 секунд. Заблокируйте iPhone и проверьте, затих ли сигнал без прикосновений.")
          }
        }
        Text("Автоостановка пока проверяется. Если iOS приостановит Luma, команда остановки может опоздать, а AlarmKit — повторить звук. Тогда понадобится остановить сигнал вручную. Короткий файл сам по себе этого не предотвращает.")
          .font(LumaStyle.font(13)).foregroundStyle(LumaStyle.amber).lineSpacing(4)
          .accessibilityIdentifier("alarmkit.stopLimitation")
        Group {
          Text("Система может показывать сигнал AlarmKit на Apple Watch, связанных с iPhone. Отдельное приложение Luma на часах не требуется. Проверьте звук и вибрацию на вашей паре устройств.")
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
