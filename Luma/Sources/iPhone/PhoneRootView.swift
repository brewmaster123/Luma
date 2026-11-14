import SwiftUI

struct PhoneRootView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selected: ReferenceTab = .night
  private var isReferenceFixture: Bool {
    ProcessInfo.processInfo.arguments.contains("-reference-screenshot")
  }

  var body: some View {
    GeometryReader { geometry in
      let viewport = ReferenceNightViewport(
        size: CGSize(width: geometry.size.width,
          height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom),
        topInset: geometry.safeAreaInsets.top, bottomInset: geometry.safeAreaInsets.bottom)
      ZStack {
        if selected == .night {
          ReferenceNightScene().ignoresSafeArea().accessibilityHidden(true)
        } else {
          LumaStyle.background.ignoresSafeArea()
        }
        TabView(selection: $selected) {
          NavigationStack { NightView() }.tag(ReferenceTab.night)
          NavigationStack {
            if isReferenceFixture { Color.clear } else { JournalView() }
          }.tag(ReferenceTab.journal)
          NavigationStack {
            if isReferenceFixture { Color.clear } else { SettingsView() }
          }.tag(ReferenceTab.settings)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          ReferenceTabBar(selection: $selected, scale: viewport.scaleX)
        }
      }
      .environment(\.referenceNightViewport, viewport)
    }
    .tint(ReferenceNightStyle.amber)
    .allowsHitTesting(!isReferenceFixture)
    .task {
      if model.showOnboarding { model.completeIntroduction() }
    }
    .alert(
      "Luma",
      isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
    ) {
      Button("Понятно") { model.message = nil }
    } message: {
      Text(model.message ?? "")
    }
    // No introduction sheet: the app opens Night immediately.
    // Readiness/migration consent remains separate from the obsolete welcome page.
    .sheet(isPresented: $model.showSignalMigration) {
      SignalReadinessView(continueTitle: "Включить сохранённые сигналы")
        .environmentObject(model)
    }
  }
}

private enum ReferenceTab: Hashable {
  case night, journal, settings
  var symbol: String {
    switch self { case .night: return "moon"; case .journal: return "book"; case .settings: return "gearshape" }
  }
  var title: String {
    switch self { case .night: return "Ночь"; case .journal: return "Дневник"; case .settings: return "Настройки" }
  }
}

private struct ReferenceTabBar: View {
  @Binding var selection: ReferenceTab
  @Environment(\.accessibilityReduceMotion) private var reduced
  @Namespace private var indicator
  var scale: CGFloat
  private let tabs: [ReferenceTab] = [.night, .journal, .settings]

  var body: some View {
    HStack(spacing: 0) {
      ForEach(tabs, id: \.self) { tab in
        Button {
          if reduced { selection = tab }
          else { withAnimation(.easeInOut(duration: 0.28)) { selection = tab } }
        } label: {
          VStack(spacing: 8) {
            Image(systemName: tab.symbol)
              .font(.system(size: max(24, 50 * scale), weight: .regular))
              .frame(height: 32)
              .foregroundStyle(selection == tab ? ReferenceNightStyle.text : ReferenceNightStyle.inactive)
              .shadow(color: selection == tab ? ReferenceNightStyle.amber.opacity(0.20) : .clear,
                radius: 5)
            ZStack {
              Color.clear
              if selection == tab {
                Capsule().fill(ReferenceNightStyle.text)
                  .shadow(color: ReferenceNightStyle.amber.opacity(0.70), radius: 5, y: 1)
                  .matchedGeometryEffect(id: "selected-tab", in: indicator)
              }
            }
            .frame(width: max(28, 76 * scale), height: 2)
          }
          .padding(.top, 16)
          .frame(maxWidth: .infinity, minHeight: 60, alignment: .top)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
        .accessibilityIdentifier("reference.tab.\(tab.title)")
      }
    }
    .padding(.horizontal, 9)
    .background {
      LinearGradient(colors: [.clear, ReferenceNightStyle.sky.opacity(0.18)],
        startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    }
  }
}

struct NightView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.referenceNightViewport) private var viewport
  @State private var alarm: LumaAlarm?
  @State private var signalAction: SignalAction?
  @State private var preparedAction: SignalAction?
  @State private var showingAlarmHelp = false

  private enum SignalAction: Identifiable {
    case enable(UUID)
    var id: UUID { switch self { case .enable(let id): return id } }
    var title: String { "Включить будильник" }
  }

  private func prepare(_ action: SignalAction) {
    if model.systemAlarms.acceptedLimitations { Task { await perform(action) } }
    else { signalAction = action }
  }

  private func perform(_ action: SignalAction) async {
    switch action { case .enable(let id): await model.toggleAlarm(id) }
  }

  var body: some View {
    GeometryReader { geometry in
      let sx = viewport.scaleX
      let sy = viewport.scaleY
      ScrollView {
        VStack(spacing: 0) {
          Color.clear.frame(height: max(0, 522 * sy - viewport.topInset))
            .accessibilityHidden(true)
          IndirectMethodCard(referenceScale: sx, referenceVerticalScale: sy)
          Color.clear.frame(height: 64 * sy).accessibilityHidden(true)
          alarmsSection(scaleX: sx, scaleY: sy)
            .padding(.horizontal, 104 * sx)
          Color.clear.frame(height: max(24, 90 * sy)).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
      }
      .scrollIndicators(.hidden)
      .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    }
    .foregroundStyle(ReferenceNightStyle.text)
    .background(Color.clear)
    .toolbar(.hidden, for: .navigationBar)
    .toolbarBackground(.hidden, for: .navigationBar)
    .sheet(item: $signalAction, onDismiss: {
      guard let action = preparedAction else { return }
      preparedAction = nil
      Task { await perform(action) }
    }) { action in
      SignalReadinessView(continueTitle: action.title) { preparedAction = action }
        .environmentObject(model)
    }
    .sheet(item: $alarm) { AlarmEditor(alarm: $0).environmentObject(model) }
    .sheet(isPresented: $showingAlarmHelp) { SmartAlarmReferenceHelp() }
  }

  private func alarmsSection(scaleX sx: CGFloat, scaleY sy: CGFloat) -> some View {
    LazyVStack(spacing: 0) {
      Rectangle()
        .fill(LinearGradient(
          colors: [.clear, ReferenceNightStyle.text.opacity(0.62), .clear],
          startPoint: .leading, endPoint: .trailing))
        .frame(height: 0.5)
      HStack(spacing: 12) {
        Button { showingAlarmHelp = true } label: {
          HStack(spacing: 36 * sx) {
            Image(systemName: "alarm")
              .font(.system(size: max(22, 50 * sx), weight: .regular))
              .foregroundStyle(ReferenceNightStyle.amber)
              .frame(width: 78 * sx)
            VStack(alignment: .leading, spacing: 7 * sy) {
              Text("Умный будильник").font(ReferenceNightStyle.serif(max(16, 34 * sx)))
                .foregroundStyle(Color(hex: 0xF2F0F3))
              Text("Автоматические пробуждения")
                .font(ReferenceNightStyle.sans(max(11, 24 * sx)))
                .foregroundStyle(ReferenceNightStyle.secondary)
            }
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Умный будильник. Автоматические пробуждения")
        .accessibilityHint("Открывает справку")
        .accessibilityIdentifier("alarm.help")
        Button {
          var item = LumaAlarm()
          item.signal = model.state.signal
          item.phoneDelivery = model.newAlarmDelivery
          alarm = item
        } label: {
          Image(systemName: "plus")
            .font(.system(size: max(22, 31 * sx), weight: .light))
            .foregroundStyle(ReferenceNightStyle.text)
        }
        .buttonStyle(ReferenceRoundButtonStyle(diameter: 58 * sx))
        .accessibilityLabel("Добавить будильник")
        .accessibilityIdentifier("alarm.add")
      }
      .padding(.top, 44 * sy)
      .padding(.bottom, 30 * sy)
      if model.state.alarms.isEmpty {
        Text("Пока нет будильников")
          .font(ReferenceNightStyle.sans(max(12, 24 * sx)))
          .foregroundStyle(ReferenceNightStyle.secondary)
          .frame(maxWidth: .infinity, minHeight: 112 * sy, alignment: .leading)
      }
      ForEach(model.sortedAlarms) { item in
        alarmRow(item, scaleX: sx, scaleY: sy).padding(.bottom, 16 * sy)
      }
    }
  }

  private func alarmRow(_ item: LumaAlarm, scaleX sx: CGFloat, scaleY sy: CGFloat) -> some View {
    HStack(spacing: 12 * sx) {
      Button { alarm = item } label: {
        HStack(spacing: 32 * sx) {
          Image(systemName: "clock")
            .font(.system(size: max(22, 44 * sx), weight: .regular))
            .foregroundStyle(ReferenceNightStyle.inactive)
            .frame(width: 48 * sx)
          VStack(alignment: .leading, spacing: 5 * sy) {
            Text(String(format: "%02d:%02d", item.hour, item.minute))
              .font(ReferenceNightStyle.serif(max(22, 50 * sx)))
              .foregroundStyle(Color(hex: 0xF2F0F3)).monospacedDigit()
            Text(alarmSubtitle(item))
              .font(ReferenceNightStyle.sans(max(11, 24 * sx)))
              .foregroundStyle(ReferenceNightStyle.secondary)
            if item.enabled && item.weekdays.isEmpty && item.onceAt < Date() {
              Text("Завершён").font(ReferenceNightStyle.sans(11))
                .foregroundStyle(ReferenceNightStyle.secondary)
            } else if item.enabled && !model.queuedAlarmIDs.contains(item.id) {
              Text("Пока вне очереди iPhone").font(ReferenceNightStyle.sans(11))
                .foregroundStyle(ReferenceNightStyle.amber)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: max(44, 100 * sy), alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Изменить будильник \(String(format: "%02d:%02d", item.hour, item.minute)), \(item.title)")
      .accessibilityHint("Открывает настройку времени и сигнала")
      .accessibilityIdentifier("alarm.edit.\(item.id.uuidString)")
      Toggle("Включить будильник",
        isOn: Binding(get: { item.enabled }, set: { _ in
          if item.enabled { Task { await model.toggleAlarm(item.id) } }
          else { prepare(.enable(item.id)) }
        }))
        .labelsHidden()
        .toggleStyle(ReferenceAlarmToggleStyle(scaleX: sx, scaleY: sy))
        .accessibilityIdentifier("alarm.toggle.\(item.id.uuidString)")
    }
    .padding(.horizontal, 44 * sx)
    .padding(.vertical, 6 * sy)
    .frame(maxWidth: .infinity, minHeight: 112 * sy)
    .background {
      RoundedRectangle(cornerRadius: 42 * sx, style: .continuous)
        .fill(LinearGradient(colors: [ReferenceNightStyle.cardTop, ReferenceNightStyle.cardBottom],
          startPoint: .top, endPoint: .bottom))
        .overlay(RoundedRectangle(cornerRadius: 42 * sx, style: .continuous)
          .stroke(ReferenceNightStyle.inactive.opacity(0.15), lineWidth: 0.6))
    }
  }

  private func alarmSubtitle(_ item: LumaAlarm) -> String {
    let repetition: String
    if item.weekdays.isEmpty { repetition = "один раз" }
    else if item.weekdays == Set([2, 3, 4, 5, 6]) { repetition = "по будням" }
    else { repetition = "по выбранным дням" }
    return item.title.isEmpty ? repetition : "\(item.title) · \(repetition)"
  }
}
