import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var recorder = false
  @State private var confirmDelete = false
  @State private var showReadiness = false
  @State private var wantsPreview = false
  @State private var readyToPreview = false
  @State private var previewDelay: TimeInterval = 3
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("Настройки").font(LumaStyle.font(30, "Medium", relativeTo: .largeTitle))
        Text("Ваша ночь, ваш ритм.").foregroundStyle(LumaStyle.secondary)
        LumaCard {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("REM всю ночь").font(LumaStyle.font(16, "SemiBold"))
              Spacer()
              Text("Premium").font(LumaStyle.font(11, "Medium"))
                .foregroundStyle(LumaStyle.lavender).padding(.horizontal, 10).padding(.vertical, 5)
                .background(LumaStyle.lavender.opacity(0.1), in: Capsule())
            }
            Text("Готовится для будущей подписки. Сейчас функция недоступна.")
              .font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
          }
        }
        LumaCard {
          VStack(alignment: .leading, spacing: 18) {
            SmallLabel(text: "СИГНАЛ БУДИЛЬНИКА")
            SignalEditor(
              signal: Binding(get: { model.state.signal }, set: { model.updateSignal($0) }),
              voices: model.state.voices)
            Button {
              previewDelay = 3
              wantsPreview = true; showReadiness = true
            } label: {
              Label("Проба AlarmKit через 3 секунды", systemImage: "play.circle")
            }.frame(maxWidth: .infinity, minHeight: 44).disabled(model.audio.recording || model.audio.playing || model.busy || model.systemAlarms.preparing)
            Text("Для AlarmKit создаётся отдельный WAV длиной 4 секунды с плавным завершением. Исходная запись сохраняется.")
              .font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary)
          }
        }
        SoundLibraryView(audio: model.audio) { recorder = true }
        LumaCard {
          VStack(alignment: .leading, spacing: 14) {
            SmallLabel(text: "ПРОВЕРКА ALARMKIT")
            Button {
              previewDelay = 60; wantsPreview = true; showReadiness = true
            } label: {
              Label("Проба с блокировкой через 60 секунд", systemImage: "lock.iphone")
                .font(LumaStyle.font(13, "Medium")).frame(minHeight: 44)
            }.disabled(model.busy || model.systemAlarms.preparing)
            Text(model.systemAlarms.lastStopReport)
              .font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
            Text("После запуска заблокируйте iPhone. Проверьте один звук длиной 4 секунды без повтора. Журнал показывает состояние AlarmKit и резервную Stop; фактическое окончание звука нужно измерить на устройстве.")
              .font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary)
            if let log = model.systemAlarms.logURL,
              FileManager.default.fileExists(atPath: log.path) {
              ShareLink(item: log) { Label("Журнал проверки", systemImage: "square.and.arrow.up") }
                .font(LumaStyle.font(13)).frame(minHeight: 44)
            }
            Button("Отменить все системные сигналы", role: .destructive) {
              Task { await model.stopAllSystemAlarms() }
            }.font(LumaStyle.font(12)).frame(minHeight: 44).disabled(model.busy)
          }
        }
        LumaCard {
          VStack(alignment: .leading, spacing: 12) {
            Button("Как настроить ночные сигналы") {
              wantsPreview = false; showReadiness = true
            }.frame(minHeight: 44)
            Text(model.alarmPermissionSummary).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
            Button("История сна из «Здоровья»") { Task { await model.connectHealth() } }.frame(
              minHeight: 44)
            Label {
              Text("Часы могут показывать системный будильник AlarmKit. Проверьте, что на заблокированном iPhone звучит WAV, а сигнал заканчивается самостоятельно. Обычные уведомления для сигналов отключены.")
                .font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
            } icon: { Image(systemName: "applewatch").foregroundStyle(LumaStyle.lavender) }

          }
        }
        Button("Удалить историю и отклики", role: .destructive) { confirmDelete = true }.frame(
          minHeight: 44)
        Text("\(model.versionLabel) · пространство осознанных снов").font(LumaStyle.font(11)).foregroundStyle(
          LumaStyle.secondary)
      }.padding(22)
    }.lumaScreen().toolbar(.hidden, for: .navigationBar)
      .sheet(isPresented: $showReadiness, onDismiss: {
        if readyToPreview { readyToPreview = false; Task { await model.testSystemAlarm(after: previewDelay) } }
      }) {
        SignalReadinessView(continueTitle: wantsPreview ? "Проверить сигнал"
          : (model.systemAlarms.acceptedLimitations ? "Понятно" : "Разрешить сигналы"),
          requiresPermission: wantsPreview || !model.systemAlarms.acceptedLimitations) { readyToPreview = wantsPreview }
          .environmentObject(model)
      }
      .sheet(isPresented: $recorder) { VoiceRecorderView(audio: model.audio) }
      .confirmationDialog(
        "Удалить сны, сеансы и отклики?", isPresented: $confirmDelete, titleVisibility: .visible
      ) { Button("Удалить историю", role: .destructive) { model.deleteHistory() } }
  }
}
struct SignalEditor: View {
  @Binding var signal: SignalSettings
  let voices: [VoiceClip]
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Звук", selection: $signal.voiceID) {
        Text("Мелодия Luma").tag(Optional<UUID>.none)
        ForEach(voices) { v in Text(v.name).tag(Optional(v.id)) }
      }.tint(LumaStyle.lavender)
      Text("Для будильника используется отдельная копия звука длиной 4 секунды.")
        .font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary)
    }
  }
}
struct VoiceRecorderView: View {
  @ObservedObject var audio: PhoneAudio
  @Environment(\.dismiss) private var dismiss
  @State private var name = "Моя подсказка"
  @State private var error: String?
  @State private var starting = false
  var body: some View {
    NavigationStack {
      VStack(spacing: 26) {
        Image(systemName: audio.recording ? "waveform" : "mic").font(.system(size: 44))
          .foregroundStyle(LumaStyle.lavender)
        Text("Подсказка вашим голосом").font(LumaStyle.font(24, "Medium")).multilineTextAlignment(
          .center)
        TextField("Название", text: $name).textFieldStyle(.roundedBorder)
        Text(String(format: "00:%02d / 00:28", Int(audio.recordSeconds))).font(
          LumaStyle.font(28, "Medium")
        ).monospacedDigit()
        ProgressView(value: audio.recordSeconds, total: 28).tint(LumaStyle.lavender)
        Text("Запись завершится сама через 28 секунд. Она сохранится только на iPhone.").font(
          LumaStyle.font(13)
        ).foregroundStyle(LumaStyle.secondary).multilineTextAlignment(.center)
        if let error { Text(error).foregroundStyle(LumaStyle.amber) }
        Button(audio.recording ? "Завершить запись" : "Начать запись") {
          if audio.recording {
            audio.finishRecording()
          } else {
            starting = true
            Task {
              do { try await audio.startRecording(name: name) } catch {
                self.error = error.localizedDescription
              }
              starting = false
            }
          }
        }.buttonStyle(PrimaryButtonStyle()).disabled(starting)
      }.padding(28).frame(maxHeight: .infinity).lumaScreen().toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Закрыть") { dismiss() }.disabled(audio.recording || starting)
        }
      }
    }
    .interactiveDismissDisabled(audio.recording || starting).onChange(of: audio.recording) {
      was, isNow in if was && !isNow { dismiss() }
    }
  }
}
