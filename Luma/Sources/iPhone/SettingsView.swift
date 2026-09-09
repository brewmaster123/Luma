import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var recorder = false
  @State private var confirmDelete = false
  @State private var confirmSystemAlarms = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("Настройки").font(LumaStyle.font(30, "Medium", relativeTo: .largeTitle))
        Text("Ваша ночь, ваш ритм.").foregroundStyle(LumaStyle.secondary)
        LumaCard {
          VStack(alignment: .leading, spacing: 16) {
            SmallLabel(text: "КАК НАБЛЮДАТЬ ЗА СНОМ")
            ForEach(SensorSource.allCases) { source in
              Button {
                model.setSource(source)
              } label: {
                HStack {
                  Image(systemName: source == .phone ? "iphone" : "applewatch").frame(width: 24)
                  Text(source.title).font(LumaStyle.font(14))
                  Spacer()
                  Image(
                    systemName: model.state.source == source ? "checkmark.circle.fill" : "circle")
                }.foregroundStyle(
                  model.state.source == source ? LumaStyle.lavender : LumaStyle.secondary
                ).frame(minHeight: 44)
              }.disabled(model.hasPlan)
            }
            if model.state.source == .phone {
              Text(
                "Без Apple Watch оценка REM менее надёжна: нет данных пульса и движений запястья. Насколько ниже точность в процентах, пока не измерено."
              ).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.amber)
            }
            if model.state.source.usesMicrophone {
              Text(
                "Положите iPhone рядом с кроватью, на открытую поверхность. Микрофон анализирует только признаки звука; запись ночных разговоров не сохраняется. Шум и другой спящий рядом могут мешать."
              ).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
            }
          }
        }
        LumaCard {
          VStack(alignment: .leading, spacing: 18) {
            SmallLabel(text: "СИГНАЛ ДЛЯ СЛЕДУЮЩЕГО СЕАНСА")
            SignalEditor(
              signal: Binding(get: { model.state.signal }, set: { model.updateSignal($0) }),
              voices: model.state.voices)
            Button {
              Task { await model.preview() }
            } label: {
              Label("Послушать и почувствовать", systemImage: "play.circle")
            }.frame(maxWidth: .infinity, minHeight: 44).disabled(model.audio.recording)
            Text(
              "REM-подсказки заканчиваются сами. В сеансе используются настройки, выбранные при его запуске."
            ).font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary)
          }
        }
        SoundLibraryView(audio: model.audio) { recorder = true }
        LumaCard {
          VStack(alignment: .leading, spacing: 12) {
            Toggle("Вибрация iPhone", isOn: Binding(get: { model.state.vibratesOnPhone }, set: { model.setPhoneVibration($0) }))
              .tint(LumaStyle.lavender)
            Text("Во время коротких звуковых подсказок Luma. Вибрацией системного будильника управляет iOS.")
              .font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
          }
        }
        LumaCard {
          VStack(alignment: .leading, spacing: 12) {
            Text("Будильник в беззвучном режиме").font(LumaStyle.font(16, "Medium"))
            Text(model.systemAlarmStatus).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
            if model.supportsSystemAlarms {
              Picker("Для новых будильников", selection: Binding(get: { model.newAlarmDelivery }, set: { model.setDefaultDelivery($0) })) {
                ForEach(PhoneAlarmDelivery.allCases) { Text($0.title).tag($0) }
              }
              Button("Разрешить системные будильники") { Task { await model.requestSystemAlarmAccess() } }.frame(minHeight: 44)
              if model.shortPhoneAlarmCount > 0 {
                Button("Перевести имеющиеся будильники") { confirmSystemAlarms = true }.frame(minHeight: 44).disabled(model.busy)
              }
            }
            Text("Системный будильник звучит сквозь беззвучный режим с iOS 26. Он может повторять звук до остановки. Короткие REM-подсказки затихают сами.")
              .font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
          }
        }
        LumaCard {
          VStack(alignment: .leading, spacing: 14) {
            Toggle(
              "Личная настройка",
              isOn: Binding(
                get: { model.state.personalizationEnabled }, set: { model.setPersonalization($0) })
            ).tint(LumaStyle.lavender)
            Text(
              "По желанию оставляйте отклик в дневнике. Настройка начинается от 12 подходящих ночей с часами, при наличии разных результатов. Одна неудача ничего не меняет."
            ).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
            Text("Подходящих ночей: \(model.personalizationCount)").font(
              LumaStyle.font(12, "Medium"))
            Text(
              "Успех осознанного сна не доказывает REM. Настройка лишь немного меняет предпочтение похожих условий; это эксперимент."
            ).font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary)
          }
        }
        LumaCard {
          VStack(alignment: .leading, spacing: 12) {
            Button("Разрешить данные Apple Health") { Task { await model.connectHealth() } }.frame(
              minHeight: 44)
            Button("Разрешить уведомления") { Task { await model.requestSignalAccess() } }.frame(
              minHeight: 44)
            Button("Обновить связь с часами") { model.syncConfiguration() }.frame(minHeight: 44)
            Text(model.watchStatus).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
            Text(
              "Для ночной вибрации включите бесшумный режим часов. Система определяет рисунок постукиваний и доставку уведомлений. REM-сигналы на часы требуют доступной связи; работу при погашенных экранах нужно проверить на ваших устройствах."
            ).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
          }
        }
        Button("Удалить историю и отклики", role: .destructive) { confirmDelete = true }.frame(
          minHeight: 44)
        Text("Luma 0.3 · пространство осознанных снов").font(LumaStyle.font(11)).foregroundStyle(
          LumaStyle.secondary)
      }.padding(22)
    }.lumaScreen().toolbar(.hidden, for: .navigationBar)
      .confirmationDialog("Перевести будильники в системный режим?", isPresented: $confirmSystemAlarms, titleVisibility: .visible) {
        Button("Перевести будильники") { Task { await model.enableSystemAlarmsForExisting() } }
      } message: {
        Text("Они будут звучать сквозь беззвучный режим и фокусирование. Системный звонок может повторяться до нажатия «Остановить»; короткие REM-подсказки по-прежнему затихают сами.")
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
  var systemAlarm = false
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(SignalOutput.allCases) { output in
        Button {
          signal.output = output
        } label: {
          HStack(spacing: 12) {
            Image(
              systemName: output == .watch
                ? "applewatch" : output == .phone ? "iphone" : "iphone.radiowaves.left.and.right"
            ).frame(width: 24)
            Text(output.title).font(LumaStyle.font(13))
            Spacer()
            Image(systemName: signal.output == output ? "checkmark.circle.fill" : "circle")
          }.frame(minHeight: 44).foregroundStyle(
            signal.output == output ? LumaStyle.lavender : LumaStyle.secondary)
        }
      }
      if signal.output.phoneEnabled {
        Picker("Звук iPhone", selection: $signal.voiceID) {
          Text("Мелодия Luma").tag(Optional<UUID>.none)
          ForEach(voices) { v in Text(v.name).tag(Optional(v.id)) }
        }.tint(LumaStyle.lavender)
        if signal.voiceID == nil {
          Picker("Длительность", selection: $signal.melodySeconds) {
            ForEach([4, 8, 15], id: \.self) { Text("\($0) сек").tag($0) }
          }.pickerStyle(.segmented)
        } else if !systemAlarm {
          Text("Дорожка проиграется один раз до конца.").font(LumaStyle.font(11)).foregroundStyle(
            LumaStyle.secondary)
        }
      }
      if signal.output.watchEnabled && !(systemAlarm && signal.output.phoneEnabled) {
        SmallLabel(text: "КОРОТКИХ СИГНАЛОВ НА ЧАСАХ")
        CountSelector(selected: signal.count) { signal.count = $0 }
        Picker("Интервал", selection: $signal.gapSeconds) {
          ForEach([3, 8, 12], id: \.self) { Text("\($0) сек").tag($0) }
        }.tint(LumaStyle.lavender)
        Text("Ночью это число уведомлений. Рисунок вибрации внутри каждого задаёт watchOS.").font(
          LumaStyle.font(11)
        ).foregroundStyle(LumaStyle.secondary)
      }
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
