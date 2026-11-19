import SwiftUI
import UIKit

/// "Ночные сигналы": what has to be allowed and checked before signals are put in the queue.
/// The steps it performs are those of 0.9.7; only the wording and the look are new.
struct SignalReadinessView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.atelierDismiss) private var dismiss
  let continueTitle: String
  var requiresPermission = true
  var onReady: () -> Void = {}
  @State private var working = false
  @State private var error: String?

  var body: some View {
    AtelierSheet(tr("Ночные сигналы"), canClose: !working) {
      VStack(alignment: .leading, spacing: 13) {
        step(1, tr("Разрешите будильники"),
          tr("Умный будильник и непрямой метод работают через системные будильники iPhone. Нужна iOS 26 или новее."))
        step(2, tr("Оставьте ночной фон"),
          String(format: tr("Его не слышно: он лишь не даёт Lumenoir уснуть, чтобы каждый сигнал смолкал сам — сейчас через %@."),
            L10n.seconds(model.alarmStopSeconds)))
        step(3, tr("Проверьте с блокировкой"),
          tr("Запустите пробу через 60 секунд, заблокируйте iPhone и послушайте, затихнет ли сигнал без касаний."))
      }
      .padding(.bottom, 14)
      SheetNote(text: tr("Не закрывайте Lumenoir смахиванием: без приложения сигналы не смолкнут сами. Если сигнал всё же не смолк, нажмите «Остановить»."))
        .accessibilityIdentifier("signal.alarmkitWaveTest")
      SheetNote(text: L10n.show(model.systemAlarms.summary))
        .padding(.top, 8)
      if let error {
        Text(L10n.show(error)).font(Atelier.ui(12.5)).foregroundStyle(Atelier.ink.opacity(0.9))
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 8)
      }
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
        HStack(spacing: 10) {
          if working { ProgressView().tint(Atelier.ink) }
          Text(working ? tr("Подготавливаем…") : continueTitle)
        }
      }
      .buttonStyle(VelvetButtonStyle())
      .disabled(working || !model.systemAlarms.supported)
      .padding(.top, 16)
      .accessibilityIdentifier("signal.continue")
      Button(tr("Настройки Lumenoir в iPhone")) {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
      }
      .buttonStyle(VelvetButtonStyle(secondary: true))
      .padding(.top, 14)
    }
    .interactiveDismissDisabled(working)
    .task { await model.refreshAlarmAccess() }
  }

  private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)").font(Atelier.display(15)).foregroundStyle(Atelier.ink)
        .frame(width: 26, height: 26)
        .background(Circle().fill(Color(hex: 0x080C19))
          .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 0.5)))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(Atelier.ui(15)).foregroundStyle(Atelier.ink)
        Text(detail).font(Atelier.ui(13)).lineSpacing(4).foregroundStyle(Color(hex: 0xB9B4C6))
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
