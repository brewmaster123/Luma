import SwiftUI

struct WatchRootView: View {
  @EnvironmentObject private var model: AppModel
  private let lavender = Color(red: 0.80, green: 0.74, blue: 0.96)
  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        HStack(spacing: 8) {
          Image(systemName: "moon.stars.fill").foregroundStyle(lavender)
          Text("luma").font(.custom("Manrope-SemiBold", size: 23, relativeTo: .title2))
        }.accessibilityAddTraits(.isHeader)

        VStack(spacing: 5) {
          Text(model.watchStatus)
            .font(.custom("Manrope-Medium", size: 12, relativeTo: .caption))
          Text(model.watchReachable ? "iPhone на связи" : "Для связи откройте Luma на iPhone")
            .font(.custom("Manrope-Regular", size: 11, relativeTo: .caption2))
            .foregroundStyle(.secondary)
          if !model.queuedAlarmIDs.isEmpty {
            Text("Будильников на часах: \(model.queuedAlarmIDs.count)")
              .font(.custom("Manrope-Regular", size: 11, relativeTo: .caption2))
              .foregroundStyle(.secondary)
          }
        }.multilineTextAlignment(.center)

        actionButton(
          model.watchPreviewRunning ? "Остановить пробу" : "Проба сигнала",
          subtitle: model.watchPreviewSummary,
          icon: model.watchPreviewRunning ? "stop.fill" : "waveform",
          color: lavender, identifier: "watch.preview"
        ) {
          if model.watchPreviewRunning { model.stopWatchPreview() }
          else { Task { await model.preview() } }
        }

        actionButton(
          model.watchNotificationNeedsRequest ? "Разрешить уведомления" : "Уведомления",
          subtitle: model.watchNotificationSummary,
          icon: model.watchNotificationsReady ? "checkmark.circle.fill" : "bell",
          busy: model.watchPermissionAction == .notifications,
          disabled: model.watchPermissionAction != nil,
          identifier: "watch.notifications"
        ) { Task { await model.requestWatchNotifications() } }

        actionButton(
          model.watchHealthRequestHandled ? "Данные сна" : "Разрешить данные сна",
          subtitle: model.watchHealthBackgroundWarning ?? model.watchHealthSummary,
          icon: "heart.text.square",
          busy: model.watchPermissionAction == .health,
          disabled: model.watchPermissionAction != nil,
          identifier: "watch.health"
        ) { Task { await model.requestWatchHealth() } }

        if model.watchSessionCanResume {
          actionButton("Возобновить на часах", subtitle: "Продолжить текущую ночь",
            icon: "play.fill", color: lavender, busy: model.watchSessionActionRunning,
            disabled: model.watchSessionActionRunning, identifier: "watch.resume"
          ) { Task { await model.resumeWatchSession() } }
        } else if model.watchSessionRunning {
          actionButton("Приостановить на часах", subtitle: "Наблюдение можно возобновить",
            icon: "pause.fill", color: .red, busy: model.watchSessionActionRunning,
            disabled: model.watchSessionActionRunning, identifier: "watch.pause"
          ) { Task { await model.endSession() } }
        }

        Text("Начните ночь на iPhone. Часы подключатся к сеансу автоматически. Проба вибрации работает при открытой Luma на часах.")
          .font(.custom("Manrope-Regular", size: 10, relativeTo: .caption2))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Text(model.versionLabel)
          .font(.custom("Manrope-Regular", size: 10, relativeTo: .caption2))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 8)
      .padding(.vertical, 10)
    }
    .alert("Luma", isPresented: Binding(
      get: { model.message != nil },
      set: { if !$0 { model.message = nil } }
    )) {
      Button("Понятно") { model.message = nil }
    } message: {
      Text(model.message ?? "")
    }
  }

  private func actionButton(
    _ title: String, subtitle: String, icon: String, color: Color = .white,
    busy: Bool = false, disabled: Bool = false, identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if busy { ProgressView().frame(width: 20) }
        else { Image(systemName: icon).frame(width: 20).foregroundStyle(color) }
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.custom("Manrope-SemiBold", size: 13, relativeTo: .body))
          Text(subtitle).font(.custom("Manrope-Regular", size: 10, relativeTo: .caption2))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(WatchActionStyle(color: color))
    .disabled(disabled)
    .accessibilityIdentifier(identifier)
  }
}

private struct WatchActionStyle: ButtonStyle {
  var color: Color
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
          .fill(color.opacity(configuration.isPressed ? 0.28 : 0.12))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
          .strokeBorder(color.opacity(configuration.isPressed ? 0.55 : 0.22), lineWidth: 1)
      }
      .opacity(enabled ? 1 : 0.65)
  }
}
