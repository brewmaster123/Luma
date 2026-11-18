import SwiftUI

/// 0.9.9: the small sign that opens the explanation of «Непрямой метод после будильника»: a thin ring with an «i»,
/// in the pearl and lamp-warm tones of the screen. It stands apart from the words, before the switch, so it never
/// reads as punctuation after them; it glows faintly while the explanation is open.
private struct FollowInfoSign: View {
  var open: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle().fill(open ? Color(hex: 0xFFE2BA).opacity(0.16) : Color.clear)
        Circle().strokeBorder((open ? Atelier.ink : Atelier.dim).opacity(open ? 0.85 : 0.55), lineWidth: 0.9)
        Text("i").font(Atelier.display(14)).foregroundStyle(open ? Atelier.ink : Atelier.dim)
          .offset(y: -0.5)
      }
      .frame(width: 21, height: 21)
      .shadow(color: Color(hex: 0xFFC98A).opacity(open ? 0.35 : 0), radius: 5)
      .frame(width: 34, height: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tr("Как это работает"))
    .accessibilityValue(open ? tr("Пояснение открыто") : tr("Пояснение скрыто"))
  }
}

/// 0.9.9: the optional session of the indirect method after this alarm. Off by default.
/// The same sunk well as the sound row above it, with the app's own switch. The explanation is hidden
/// (the user, 18 Nov 2026, evening: right under the name it read as a description of the smart alarm itself):
/// a small «i» in a ring, apart from the words and just before the switch, or a tap on the name opens it inside
/// the same well, and closes it again. A view of its own inside the sheet's cushion, so that it can reach the
/// sheet's scroll: on a small iPhone the opened explanation is scrolled into view.
private struct FollowSwitchRow: View {
  @Binding var on: Bool
  var saving: Bool
  @State private var open = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.atelierScroll) private var sheetScroll

  private static let helpID = "alarm.followHelp"

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Button { toggleHelp() } label: {
          HStack(spacing: 11) {
            Image(systemName: "moon.zzz").font(.system(size: 15, weight: .light))
              .foregroundStyle(on ? Atelier.ink : Atelier.off)
              .frame(width: 20)
            Text(tr("Непрямой метод после будильника")).font(Atelier.ui(15)).foregroundStyle(Atelier.ink)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
        FollowInfoSign(open: open) { toggleHelp() }
        Toggle(tr("Непрямой метод после будильника"), isOn: $on)
          .labelsHidden()
          .toggleStyle(AtelierToggleStyle())
          .disabled(saving)
          .accessibilityHint(tr("Когда будильник отзвучит, сам начнётся сеанс непрямого метода."))
          // VoiceOver meets the switch, which names the feature, before the sign that explains it.
          .accessibilitySortPriority(1)
      }
      .padding(.leading, 14).padding(.trailing, 8)
      .frame(minHeight: 52)
      .accessibilityElement(children: .contain)
      if open {
        Rectangle().fill(Atelier.ink.opacity(0.07)).frame(height: 1)
          .padding(.horizontal, 14)
        Text(tr("Когда будильник отзвучит, сам начнётся сеанс непрямого метода — с текущим интервалом и звуком. Нужен включённый тихий дождь. Сеанс идёт, пока вы не нажмёте «Завершить сеанс», а сигналы звучат, пока играет дождь, — до 12 часов с его включения."))
          .font(Atelier.ui(12)).lineSpacing(3.5).foregroundStyle(Atelier.note)
          .fixedSize(horizontal: false, vertical: true)
          .padding(EdgeInsets(top: 10, leading: 14, bottom: 13, trailing: 14))
          .id(Self.helpID)
          .transition(.opacity)
      }
    }
    .background(AtelierWell())
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .padding(.top, 10)
  }

  /// Opens or closes the explanation. When it opens near the lower edge of the sheet, the sheet scrolls so
  /// that it is seen; the scroll waits one turn, until the text is laid out.
  private func toggleHelp() {
    let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.28)
    withAnimation(animation) { open.toggle() }
    guard open, let sheetScroll else { return }
    DispatchQueue.main.async {
      // No anchor: the sheet moves only if the explanation is not fully seen, and only as far as needed.
      withAnimation(animation) { sheetScroll.scrollTo(Self.helpID) }
    }
  }
}

struct AlarmEditor: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.atelierDismiss) private var dismiss
  @State var alarm: LumaAlarm
  @State private var confirmDelete = false
  @State private var saving = false
  @State private var saveError: String?
  @State private var showReadiness = false
  @State private var readyToSave = false
  @State private var choosingSound = false
  /// 0.9.9: «Непрямой метод после будильника». Off unless the person switched it on for this alarm.
  /// Read once, when the editor is made, so coming back from a nested sheet never undoes a change.
  @State private var followIndirect: Bool

  init(alarm: LumaAlarm) {
    _alarm = State(initialValue: alarm)
    _followIndirect = State(initialValue: SmartAlarmFollowUpPreference.isOn(alarm.id))
  }

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
      if await model.saveAlarm(alarm) {
        // Written only once the alarm itself is saved, so a refused save changes nothing.
        SmartAlarmFollowUpPreference.set(alarm.id, followIndirect)
        dismiss()
      } else {
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
    .atelierSheet(isPresented: $showReadiness, onDismiss: {
      if readyToSave { readyToSave = false; saveAlarm() }
    }) {
      SignalReadinessView(continueTitle: tr("Сохранить будильник")) { readyToSave = true }
        .environmentObject(model)
    }
    .atelierSheet(isPresented: $choosingSound) {
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
    FollowSwitchRow(on: $followIndirect, saving: saving)
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
        if !model.state.alarms.contains(where: { $0.id == alarm.id }) {
          SmartAlarmFollowUpPreference.set(alarm.id, false)
        }
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
    let name = SoundShelf.name(alarm.signal.voiceID, voices: model.state.voices)
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
