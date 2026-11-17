import SwiftUI

struct AlarmEditor: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State var alarm: LumaAlarm
  @State private var confirmDelete = false
  @State private var saving = false
  @State private var saveError: String?
  @State private var showReadiness = false
  @State private var readyToSave = false
  @State private var choosingSound = false

  private func saveAlarm() {
    guard !saving else { return }
    saving = true
    saveError = nil
    Task { @MainActor in
      defer { saving = false }
      // Recalculate after returning from Settings, so a stale draft is not armed in the past.
      alarm.onceAt = Calendar.current.nextDate(after: Date().addingTimeInterval(10),
        matching: DateComponents(hour: alarm.hour, minute: alarm.minute), matchingPolicy: .nextTime)
        ?? Date().addingTimeInterval(3600)
      if await model.saveAlarm(alarm) { dismiss() }
      else {
        saveError = model.message ?? "Не удалось сохранить будильник."
        // The text is shown here, in the sheet; it does not need a second showing.
        model.message = nil
      }
    }
  }

  /// Monday first, Sunday last (Calendar numbers: 1 = Sunday).
  private let days = [2, 3, 4, 5, 6, 7, 1]

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

  private var exists: Bool { model.state.alarms.contains(where: { $0.id == alarm.id }) }

  private var title: String {
    if confirmDelete { return tr("Удалить этот будильник?") }
    return exists ? tr("Будильник") : tr("Новый будильник")
  }

  var body: some View {
    AtelierSheet(title, canClose: !saving) {
      if confirmDelete {
        deleteConfirmation
      } else {
        editorFields
        editorButtons
      }
    }
    .sheet(isPresented: $showReadiness, onDismiss: {
      if readyToSave { readyToSave = false; saveAlarm() }
    }) {
      SignalReadinessView(continueTitle: tr("Сохранить будильник")) { readyToSave = true }
        .environmentObject(model)
    }
    .sheet(isPresented: $choosingSound) {
      SoundPickerSheet(selection: $alarm.signal.voiceID).environmentObject(model)
    }
    .interactiveDismissDisabled(saving)
  }

  @ViewBuilder private var editorFields: some View {
    DatePicker(tr("Время"), selection: time, displayedComponents: .hourAndMinute)
      .datePickerStyle(.wheel)
      .labelsHidden()
      .environment(\.locale, L10n.locale)
      .frame(maxWidth: .infinity)
      .frame(height: 168)
      .clipped()
    fieldLabel(tr("Название"))
    TextField("", text: $alarm.title, prompt: Text(tr("Название")).foregroundColor(Atelier.foot))
      .font(Atelier.ui(15))
      .foregroundStyle(Atelier.ink)
      .padding(.horizontal, 14)
      .frame(minHeight: 46)
      .background(AtelierWell())
      .accessibilityLabel(tr("Название"))
    fieldLabel(tr("Повтор"))
    HStack(spacing: 5) {
      ForEach(days, id: \.self) { day in dayChip(day) }
    }
    Text(alarm.weekdays.isEmpty
      ? tr("Один раз, в ближайшее выбранное время") : tr("Повтор в выбранные дни"))
      .font(Atelier.ui(11.6)).foregroundStyle(Atelier.faint)
      .padding(.top, 8)
    soundRow
  }

  @ViewBuilder private var editorButtons: some View {
    SheetNote(text: tr("Длительность сигнала задаётся в настройках. Перед ночью проверьте звук с заблокированным iPhone."))
      .padding(.top, 12)
    if let saveError {
      Text(L10n.show(saveError)).font(Atelier.ui(12.5)).foregroundStyle(Atelier.ink.opacity(0.9))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
    }
    Button(tr("Сохранить будильник")) {
      if alarm.enabled && !model.systemAlarms.acceptedLimitations { showReadiness = true }
      else { saveAlarm() }
    }
    .buttonStyle(VelvetButtonStyle())
    .disabled(saving)
    .padding(.top, 16)
    if exists {
      Button(tr("Удалить будильник")) { confirmDelete = true }
        .buttonStyle(VelvetButtonStyle(secondary: true))
        .disabled(saving)
        .padding(.top, 14)
    }
    Button(tr("Отмена")) { dismiss() }
      .buttonStyle(VelvetButtonStyle(secondary: true))
      .disabled(saving)
      .padding(.top, 14)
  }

  @ViewBuilder private var deleteConfirmation: some View {
    SheetLead(text: tr("Будильник исчезнет из списка, его сигналы будут сняты."))
    Button(tr("Удалить")) {
      Task {
        await model.deleteAlarm(alarm.id)
        dismiss()
      }
    }
    .buttonStyle(VelvetButtonStyle())
    Button(tr("Отмена")) { confirmDelete = false }
      .buttonStyle(VelvetButtonStyle(secondary: true))
      .padding(.top, 14)
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text).font(Atelier.ui(13)).foregroundStyle(Atelier.note)
      .padding(.top, 14).padding(.bottom, 8)
  }

  private func dayChip(_ day: Int) -> some View {
    let chosen = alarm.weekdays.contains(day)
    return Button {
      if chosen { alarm.weekdays.remove(day) } else { alarm.weekdays.insert(day) }
    } label: {
      Text(L10n.weekday(day)).font(Atelier.ui(12.5, chosen ? "Medium" : "Regular"))
        .lineLimit(1).minimumScaleFactor(0.7)
        .foregroundStyle(chosen ? Atelier.ink : Atelier.faint)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(AtelierChip(chosen: chosen))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(chosen ? [.isSelected] : [])
  }

  /// The sound of this alarm (the same list as in Settings).
  private var soundRow: some View {
    let name = model.state.voices.first(where: { $0.id == alarm.signal.voiceID })?.name ?? tr("Мелодия Lumenoir")
    return Button { choosingSound = true } label: {
      HStack(spacing: 12) {
        Text(tr("Звук")).font(Atelier.ui(15)).foregroundStyle(Atelier.ink)
        Spacer(minLength: 8)
        Text(name).font(Atelier.ui(14)).foregroundStyle(Atelier.dim).lineLimit(1)
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .regular))
          .foregroundStyle(Atelier.off)
      }
      .padding(.horizontal, 14)
      .frame(minHeight: 48)
      .background(AtelierWell())
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.top, 14)
  }
}
