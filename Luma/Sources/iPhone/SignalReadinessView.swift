import SwiftUI
import UIKit

/// A reminder before arming phone audio. Neither Silent Mode nor Focus membership
/// has a public readiness check; only actual notification permission is displayed.
struct SignalReadinessView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var phase
  let continueTitle: String
  var signalOutput: SignalOutput = .phone
  var startsSession = false
  var requiresPermission = true
  var onReady: () -> Void = {}
  @State private var working = false
  @State private var error: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Image(systemName: "bell.badge").foregroundStyle(LumaStyle.lavender)
            .font(.system(size: 24, weight: .light))
          Spacer()
          Button { dismiss() } label: {
            Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("Закрыть памятку").disabled(working)
        }
        Text(signalOutput == .both ? "Сигналы на двух устройствах" : "Чтобы сигнал прозвучал")
          .font(LumaStyle.font(24, "Medium", relativeTo: .title2))
        Text("Короткий сигнал затихнет сам. Перед сном:")
          .font(LumaStyle.font(13)).foregroundStyle(LumaStyle.secondary)
        LumaCard {
          VStack(alignment: .leading, spacing: 20) {
            if signalOutput == .both {
              step(1, "Проверьте громкость iPhone", "Здесь используется громкость мультимедиа. Отключите наушники; для пробы откройте Luma на часах.")
              step(2, "Запустите ночь с микрофоном", "Выберите «Часы + микрофон» и нажмите «Начать ночь». Микрофон анализирует звуки сна без сохранения разговоров. Не закрывайте Luma принудительно.")
            } else {
              step(1, "Выключите беззвучный режим", "Проверьте громкость «Звонок и уведомления».")
              step(2, "Включите фокусирование «Сон»", "Чтобы приглушить звонки и лишние уведомления.")
            }
            step(3, "Разрешите уведомления от Luma", "Настройки → Фокусирование → Сон → Приложения → Разрешить уведомления от → Luma.")
          }
        }
        if signalOutput == .both {
          Text("iPhone проигрывает звук напрямую, часы получают отдельную серию. Если Luma не работает в этот момент, остаётся резервное уведомление будильника через 5 секунд: оно может уйти только на часы.")
            .font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
            .accessibilityIdentifier("signal.pairedConditions")
          if startsSession && !model.hasPlan && !model.state.source.usesMicrophone {
            Button("Использовать часы и микрофон") { model.setSource(.combined) }
              .font(LumaStyle.font(13, "Medium")).frame(minHeight: 44)
              .accessibilityIdentifier("signal.selectMicrophone")
          }
        } else {
          Label {
            Text("Если Apple Watch на руке, обычное уведомление может прийти только на часы. Для отдельного звука телефона выберите «iPhone + Watch» и запустите ночь с микрофоном.")
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "applewatch").foregroundStyle(LumaStyle.lavender)
          }
          .font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
          .accessibilityIdentifier("signal.watchRouting")
        }
        Text(model.phoneNotificationSummary)
          .font(LumaStyle.font(12))
          .foregroundStyle(model.phoneNotificationsReady ? LumaStyle.secondary : LumaStyle.amber)
          .accessibilityIdentifier("signal.permissionStatus")
        if let error {
          Text(error).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.amber)
        }
        Button { Task { await openNotificationSettings() } } label: {
          Label("Настройки уведомлений Luma", systemImage: "arrow.up.forward.square")
            .font(LumaStyle.font(13, "Medium"))
            .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(LumaStyle.lavender).disabled(working)
          .accessibilityIdentifier("signal.settings")
        Text("Кнопка откроет уведомления Luma. Исключение для «Сна» добавьте по пути выше. В разделе «Люди» можно ограничить звонки.")
          .font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary)
        Button {
          working = true
          Task { @MainActor in
            defer { working = false }
            do {
              if requiresPermission { try await model.preparePhoneSignals() }
              onReady()
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
        } label: {
          HStack {
            if working { ProgressView().tint(LumaStyle.background) }
            Text(working ? "Проверяем уведомления…" : continueTitle)
          }
        }.buttonStyle(PrimaryButtonStyle()).disabled(working)
          .accessibilityIdentifier("signal.continue")
      }.padding(24)
    }
    .background(LumaStyle.background).foregroundStyle(LumaStyle.text)
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(28)
    .interactiveDismissDisabled(working)
    .task { await model.refreshPhoneNotificationAccess() }
    .onChange(of: phase) { _, value in
      if value == .active { Task { await model.refreshPhoneNotificationAccess() } }
    }
  }

  private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)").font(LumaStyle.font(12, "SemiBold"))
        .foregroundStyle(LumaStyle.lavender).frame(width: 26, height: 26)
        .background(LumaStyle.lavender.opacity(0.1), in: Circle()).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(LumaStyle.font(14, "SemiBold"))
        Text(detail).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
      }.fixedSize(horizontal: false, vertical: true)
    }.accessibilityElement(children: .combine)
  }

  private func openNotificationSettings() async {
    if let url = URL(string: UIApplication.openNotificationSettingsURLString),
      await UIApplication.shared.open(url) { return }
    if let url = URL(string: UIApplication.openSettingsURLString),
      await UIApplication.shared.open(url) { return }
    error = "Откройте Настройки iPhone → Уведомления → Luma."
  }
}
