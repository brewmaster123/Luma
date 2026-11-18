import SwiftUI

enum LumaTab: Int, Hashable {
  case night = 0, journal = 1, settings = 2
}

/// The three screens share one full-screen canvas (the design is drawn edge to edge) and a tab bar
/// of three thin icons. There is no system TabView and no navigation bar: nothing is pushed anywhere.
/// The app opens on Night at once; there is no welcome screen.
struct PhoneRootView: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var language = LanguageStore.shared
  @ObservedObject private var toasts = ToastCenter.shared
  /// Kept outside the part of the tree that is rebuilt when the language changes,
  /// so choosing a language in Settings leaves the user in Settings.
  @State private var selected: LumaTab = .night

  var body: some View {
    GeometryReader { geometry in
      let viewport = AtelierViewport(size: geometry.size,
        topInset: geometry.safeAreaInsets.top, bottomInset: geometry.safeAreaInsets.bottom)
      ZStack(alignment: .topLeading) {
        Atelier.sky
        NightView(isActive: selected == .night)
          .opacity(selected == .night ? 1 : 0)
          .allowsHitTesting(selected == .night)
          .accessibilityHidden(selected != .night)
        JournalView(isActive: selected == .journal)
          .opacity(selected == .journal ? 1 : 0)
          .allowsHitTesting(selected == .journal)
          .accessibilityHidden(selected != .journal)
        SettingsView(isActive: selected == .settings)
          .opacity(selected == .settings ? 1 : 0)
          .allowsHitTesting(selected == .settings)
          .accessibilityHidden(selected != .settings)
        LumaTabBar(selection: $selected)
        ToastView(center: toasts)
          .frame(width: viewport.size.width)
          .offset(y: viewport.size.height - 104 * viewport.v - 40)
      }
      .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
      .environment(\.atelierViewport, viewport)
      // Every text is read again in the new language.
      .id(language.language)
    }
    .ignoresSafeArea()
    .foregroundStyle(Atelier.ink)
    .tint(Atelier.ink)
    .lumaMessages()
    .task {
      // No introduction screen: the stored "seen" flag is set the way its button used to set it.
      if model.showOnboarding { model.completeIntroduction() }
      // 0.9.9: the optional «Непрямой метод после будильника» watches the signal queue from here on.
      SmartAlarmFollowUp.shared.attach(model)
      // 0.9.9: the Lumenoir melodies join the sound library (once; a missing file is restored).
      // A short pause lets the launch put the signal queue in order first.
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      await BuiltInMelodies.installIfNeeded(model)
    }
    .onChange(of: model.message) { _, text in
      // A test signal has been queued. Settings counts the seconds itself; a long test also gets a short note.
      guard let text, let delay = L10n.probeNoticeDelay(text) else { return }
      model.message = nil
      if delay >= 10 {
        toasts.show(String(format: tr("Сигнал через %@. Заблокируйте iPhone."), L10n.seconds(delay)))
      }
    }
    .atelierSheet(isPresented: $model.showSignalMigration) {
      SignalReadinessView(continueTitle: tr("Включить сохранённые сигналы"))
        .environmentObject(model)
    }
  }
}

/// Three icons and a short line under the current one.
private struct LumaTabBar: View {
  @Binding var selection: LumaTab
  @Environment(\.atelierViewport) private var viewport
  @Environment(\.accessibilityReduceMotion) private var reduced

  var body: some View {
    let u = viewport.u
    let slot: CGFloat = 112 * u
    let left: CGFloat = (viewport.size.width - 3 * slot) / 2
    return ZStack(alignment: .topLeading) {
      HStack(spacing: 0) {
        tab(.night, title: tr("Ночь"), slot: slot)
        tab(.journal, title: tr("Дневник"), slot: slot)
        tab(.settings, title: tr("Настройки"), slot: slot)
      }
      .offset(x: left)
      Capsule().fill(Atelier.ink.opacity(0.78))
        .frame(width: 30 * u, height: 1)
        .offset(x: left + slot * (CGFloat(selection.rawValue) + 0.5) - 15 * u, y: 36)
        .animation(reduced ? nil : .easeInOut(duration: 0.28), value: selection)
        .allowsHitTesting(false)
    }
    .frame(width: viewport.size.width, height: 61, alignment: .topLeading)
    .offset(y: viewport.tabBarTop)
  }

  private func tab(_ value: LumaTab, title: String, slot: CGFloat) -> some View {
    let active = selection == value
    return Button {
      selection = value
    } label: {
      icon(value)
        .foregroundStyle(active ? Atelier.ink : Atelier.off)
        .frame(width: 26 * viewport.u, height: 26 * viewport.u)
        .frame(width: slot, height: 61, alignment: .top)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(active ? [.isSelected] : [])
    .accessibilityIdentifier("tab.\(value.rawValue)")
  }

  @ViewBuilder private func icon(_ value: LumaTab) -> some View {
    let line = StrokeStyle(lineWidth: 1.0 * viewport.u, lineCap: .round, lineJoin: .round)
    let side: CGFloat = 18.6 * viewport.u
    switch value {
    case .night:
      MoonIcon().stroke(style: line).frame(width: side, height: side)
        .scaleEffect(x: 0.917, y: 0.958)
    case .journal:
      BookIcon().stroke(style: line).frame(width: side, height: side)
        .scaleEffect(x: 0.979, y: 0.8125)
    case .settings:
      GearIcon().stroke(style: line).frame(width: side, height: side)
    }
  }
}

// MARK: - Night

struct NightView: View {
  var isActive = true
  @EnvironmentObject private var model: AppModel
  @Environment(\.atelierViewport) private var viewport
  @State private var alarm: LumaAlarm?
  @State private var signalAction: SignalAction?
  @State private var preparedAction: SignalAction?
  @State private var showingAlarmHelp = false

  private enum SignalAction: Identifiable {
    case enable(UUID)
    var id: UUID { switch self { case .enable(let id): return id } }
  }

  private func prepare(_ action: SignalAction) {
    if model.systemAlarms.acceptedLimitations { Task { await perform(action) } }
    else { signalAction = action }
  }

  private func perform(_ action: SignalAction) async {
    switch action { case .enable(let id): await model.toggleAlarm(id) }
  }

  /// The moon is the lamp of this screen: buttons are lit from its side.
  private var moonPoint: CGPoint {
    CGPoint(x: viewport.artOrigin.x + 510 * viewport.artScale,
      y: viewport.artOrigin.y + 300 * viewport.artScale)
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      NightScene(isActive: isActive)
      IndirectMethodCard()
      alarmDivider
      alarmHeading
      alarmList
      CloudBank(isActive: isActive)
    }
    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
    .foregroundStyle(Atelier.ink)
    .environment(\.atelierLamp, AtelierLamp.warm(at: moonPoint))
    .atelierSheet(item: $signalAction, onDismiss: {
      guard let action = preparedAction else { return }
      preparedAction = nil
      Task { await perform(action) }
    }) { action in
      SignalReadinessView(continueTitle: tr("Включить будильник")) { preparedAction = action }
        .environmentObject(model)
    }
    .atelierSheet(item: $alarm) { AlarmEditor(alarm: $0).environmentObject(model) }
    .atelierSheet(isPresented: $showingAlarmHelp) { SmartAlarmHelp().environmentObject(model) }
  }

  private var alarmDivider: some View {
    Rectangle()
      .fill(LinearGradient(colors: [.clear, Atelier.ink.opacity(0.36), .clear],
        startPoint: .leading, endPoint: .trailing))
      .frame(width: 328.2 * viewport.u, height: 0.5)
      .offset(x: 36.9 * viewport.u, y: 561 * viewport.v)
      .accessibilityHidden(true)
  }

  private var alarmHeading: some View {
    let u = viewport.u
    return HStack(spacing: 0) {
      Button { showingAlarmHelp = true } label: {
        HStack(spacing: 20.8 * u) {
          AlarmClockIcon()
            .stroke(style: StrokeStyle(lineWidth: 1.05 * u, lineCap: .round, lineJoin: .round))
            .frame(width: 20.9 * u, height: 20.9 * u)
          VStack(alignment: .leading, spacing: 3) {
            Text(tr("Умный будильник")).font(Atelier.display(18.8 * u)).tracking(0.2)
              .foregroundStyle(Atelier.ink)
            Text(tr("Автоматические пробуждения")).font(Atelier.uiFixed(11 * u))
              .foregroundStyle(Atelier.dim)
          }
          .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(tr("Умный будильник") + ". " + tr("Автоматические пробуждения"))
      .accessibilityHint(tr("Открывает справку"))
      .accessibilityIdentifier("alarm.help")
      PebbleButton(sign: .plus, size: 26 * u, label: tr("Добавить будильник")) {
        var item = LumaAlarm()
        item.title = tr("Подсказка во сне")
        item.signal = model.state.signal
        item.phoneDelivery = model.newAlarmDelivery
        alarm = item
      }
      .accessibilityIdentifier("alarm.add")
    }
    .frame(width: 325.6 * u, height: 44)
    .offset(x: 43.8 * u, y: 607.6 * viewport.v - 22)
  }

  private var alarmList: some View {
    let u = viewport.u
    let rowHeight = viewport.alarmRowHeight, gap = viewport.alarmRowGap
    let height: CGFloat = 6 + 2 * rowHeight + gap + 8
    return ScrollView {
      LazyVStack(spacing: gap) {
        if model.state.alarms.isEmpty {
          Text(tr("Пока нет будильников")).font(Atelier.uiFixed(13 * u))
            .foregroundStyle(Atelier.dim)
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            .padding(.leading, 4)
        }
        ForEach(model.sortedAlarms) { item in
          alarmRow(item, height: rowHeight)
        }
      }
      .padding(.top, 6)
      .padding(.bottom, 8)
    }
    .scrollIndicators(.hidden)
    .frame(width: 320.8 * u, height: height)
    // A row that leaves through the top dissolves instead of being cut;
    // the lower edge needs no fade: the cloud bank in front covers it.
    .mask {
      LinearGradient(stops: [
        .init(color: .clear, location: 0), .init(color: .black, location: 6 / height),
        .init(color: .black, location: 1)
      ], startPoint: .top, endPoint: .bottom)
    }
    .offset(x: 40.8 * u, y: viewport.alarmListTop - 6)
  }

  private func alarmRow(_ item: LumaAlarm, height: CGFloat) -> some View {
    let u = viewport.u
    let time = String(format: "%02d:%02d", item.hour, item.minute)
    return HStack(spacing: 0) {
      Button { alarm = item } label: {
        HStack(spacing: 16 * u) {
          Image(systemName: "clock")
            .font(.system(size: 16 * u, weight: .light))
            .foregroundStyle(Atelier.off)
            .frame(width: 17 * u)
          VStack(alignment: .leading, spacing: 1.5) {
            Text(time).font(Atelier.numbers(23.6 * u)).tracking(0.16)
              .foregroundStyle(Atelier.ink)
            alarmCaption(item)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 18.7 * u)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(tr("Изменить будильник") + " \(time), \(item.title)")
      .accessibilityHint(tr("Открывает настройку времени и сигнала"))
      .accessibilityIdentifier("alarm.edit.\(item.id.uuidString)")
      Toggle(tr("Включить будильник"),
        isOn: Binding(get: { item.enabled }, set: { _ in
          if item.enabled { Task { await model.toggleAlarm(item.id) } }
          else { prepare(.enable(item.id)) }
        }))
        .labelsHidden()
        .toggleStyle(AtelierToggleStyle(width: 36.9 * u, height: 18.1 * u))
        .padding(.trailing, 14.5 * u)
        .accessibilityIdentifier("alarm.toggle.\(item.id.uuidString)")
    }
    .frame(height: height)
    .background(AtelierCardBackground(radius: 18.09 * u))
  }

  /// "Утро · по будням", with a short note when the alarm has passed or is not in the iPhone's queue yet.
  private func alarmCaption(_ item: LumaAlarm) -> some View {
    let repetition = L10n.repeats(item.weekdays)
    let base = item.title.isEmpty ? repetition : "\(item.title) · \(repetition)"
    var status = ""
    var warning = false
    if item.enabled && item.weekdays.isEmpty && item.onceAt < Date() {
      status = tr("завершён")
    } else if item.enabled && !model.queuedAlarmIDs.contains(item.id) {
      status = tr("пока вне очереди"); warning = true
    }
    return HStack(spacing: 0) {
      Text(base).foregroundStyle(Atelier.dim)
      if !status.isEmpty {
        Text(" · " + status).foregroundStyle(warning ? Atelier.ink.opacity(0.9) : Atelier.dim)
          .layoutPriority(1)
      }
    }
    .font(Atelier.uiFixed(11 * viewport.u))
    .lineLimit(1)
  }
}
