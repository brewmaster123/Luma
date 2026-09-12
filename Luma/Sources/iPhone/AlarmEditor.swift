import SwiftUI

struct AlarmEditor: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State var alarm: LumaAlarm
  @State private var confirmDelete = false
  @State private var saving = false
  @State private var saveError: String?
  private let days = [(2, "Пн"), (3, "Вт"), (4, "Ср"), (5, "Чт"), (6, "Пт"), (7, "Сб"), (1, "Вс")]
  private var time: Binding<Date> {
    Binding(
      get: {
        Calendar.current.date(
          bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: Date()) ?? Date()
      },
      set: {
        alarm.hour = Calendar.current.component(.hour, from: $0)
        alarm.minute = Calendar.current.component(.minute, from: $0)
      })
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          DatePicker("Время", selection: time, displayedComponents: .hourAndMinute).datePickerStyle(
            .wheel
          ).labelsHidden().frame(maxWidth: .infinity)
          TextField("Название", text: $alarm.title).padding(16).background(
            LumaStyle.surface, in: RoundedRectangle(cornerRadius: 15))
          SmallLabel(text: "ПОВТОРЯТЬ ПО ДНЯМ")
          HStack(spacing: 4) {
            ForEach(days, id: \.0) { day in
              Button {
                if alarm.weekdays.contains(day.0) {
                  alarm.weekdays.remove(day.0)
                } else {
                  alarm.weekdays.insert(day.0)
                }
              } label: {
                Text(day.1).font(LumaStyle.font(12, "Medium")).frame(
                  maxWidth: .infinity, minHeight: 44
                ).foregroundStyle(
                  alarm.weekdays.contains(day.0) ? LumaStyle.background : LumaStyle.text
                ).background(
                  alarm.weekdays.contains(day.0) ? LumaStyle.lavender : LumaStyle.surface,
                  in: Capsule())
              }
            }
          }
          Text(
            alarm.weekdays.isEmpty
              ? "Один раз, в ближайшее выбранное время" : "Повтор в выбранные дни"
          ).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
          LumaCard { SignalEditor(signal: $alarm.signal, voices: model.state.voices) }
          if alarm.signal.output.phoneEnabled {
            Text("Звук проходит через беззвучный режим. Luma отправляет команду остановки по длине дорожки. Если iOS приостановит приложение, звонок может продолжиться до ручной остановки.")
              .font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
          }
          if let saveError { Text(saveError).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.amber) }
          Button("Сохранить будильник") {
            saving = true
            Task {
              defer { saving = false }
              alarm.onceAt =
                Calendar.current.nextDate(
                  after: Date().addingTimeInterval(10),
                  matching: DateComponents(hour: alarm.hour, minute: alarm.minute),
                  matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
              if await model.saveAlarm(alarm) { dismiss() }
              else { saveError = model.message ?? "Не удалось сохранить будильник." }
            }
          }.buttonStyle(PrimaryButtonStyle()).disabled(saving)
          if model.state.alarms.contains(where: { $0.id == alarm.id }) {
            Button("Удалить будильник", role: .destructive) { confirmDelete = true }.frame(
              maxWidth: .infinity, minHeight: 44)
          }
        }.padding(22)
      }.lumaScreen().navigationTitle("Будильник").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving) }
      }
      .interactiveDismissDisabled(saving)
      .confirmationDialog(
        "Удалить этот будильник?", isPresented: $confirmDelete, titleVisibility: .visible
      ) {
        Button("Удалить", role: .destructive) {
          Task {
            await model.deleteAlarm(alarm.id)
            dismiss()
          }
        }
      }
    }
  }
}
