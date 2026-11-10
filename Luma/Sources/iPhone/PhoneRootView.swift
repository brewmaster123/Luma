import SwiftUI

struct PhoneRootView: View {
  @EnvironmentObject private var model: AppModel
  var body: some View {
    TabView {
      NavigationStack { NightView() }.tabItem { Label("Ночь", systemImage: "moon") }
      NavigationStack { JournalView() }.tabItem { Label("Дневник", systemImage: "book.closed") }
      NavigationStack { SettingsView() }.tabItem {
        Label("Настройки", systemImage: "slider.horizontal.3")
      }
    }.tint(LumaStyle.lavender)
      .alert(
        "Luma",
        isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
      ) {
        Button("Понятно") { model.message = nil }
      } message: {
        Text(model.message ?? "")
      }
      .sheet(isPresented: $model.showOnboarding) {
        IntroductionView().environmentObject(model).interactiveDismissDisabled()
      }
  }
}
struct NightView: View {
  @EnvironmentObject private var model: AppModel
  @State private var alarm: LumaAlarm?
  @State private var signalAction: SignalAction?
  @State private var preparedAction: SignalAction?
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
      ScrollView {
        let isEmpty = model.state.alarms.isEmpty
        let layout = isEmpty
          ? AnyLayout(NightEmptyLayout(availableHeight: max(0, geometry.size.height - 28)))
          : AnyLayout(VStackLayout(spacing: 22))

        layout {
          brandHeader
          MoonOrb()
            .frame(height: isEmpty ? nil : 210)
            .clipped()
          nightHeading
          IndirectMethodCard()
          alarmsSection
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
      }
      .scrollIndicators(.hidden)
      .scrollBounceBehavior(.always, axes: .vertical)
    }
    .lumaScreen()
    .toolbar(.hidden, for: .navigationBar)
    .sheet(item: $signalAction, onDismiss: {
      guard let action = preparedAction else { return }
      preparedAction = nil
      Task { await perform(action) }
    }) { action in
      SignalReadinessView(continueTitle: action.title) { preparedAction = action }
        .environmentObject(model)
    }
    .sheet(item: $alarm) { AlarmEditor(alarm: $0).environmentObject(model) }
  }

  private var brandHeader: some View {
    HStack {
      Text("luma").font(LumaStyle.font(26, "SemiBold"))
      Spacer()
      Label("ВАШЕ ПРОСТРАНСТВО СНА", systemImage: "sparkle")
        .font(LumaStyle.font(9, "Medium"))
        .foregroundStyle(LumaStyle.secondary)
    }
  }

  private var nightHeading: some View {
    VStack(spacing: 10) {
      Text(model.stateTitle)
        .font(LumaStyle.font(27, "Medium", relativeTo: .title))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Text("Осознанные Сновидения и Выход из Тела")
        .font(LumaStyle.font(13))
        .foregroundStyle(LumaStyle.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var alarmsSection: some View {
    LazyVStack(spacing: 12) {
      HStack {
        Text("Умный Будильник").font(LumaStyle.font(21, "Medium"))
        Spacer()
        Button {
          var item = LumaAlarm()
          item.signal = model.state.signal
          item.phoneDelivery = model.newAlarmDelivery
          alarm = item
        } label: {
          Image(systemName: "plus")
            .frame(width: 44, height: 44)
            .background(LumaStyle.surface, in: Circle())
        }
        .accessibilityLabel("Добавить будильник")
      }
      if model.state.alarms.isEmpty {
        Text("Пока нет будильников")
          .font(LumaStyle.font(13))
          .foregroundStyle(LumaStyle.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      ForEach(model.sortedAlarms) { item in
        LumaCard {
          HStack(spacing: 12) {
            Button { alarm = item } label: {
              VStack(alignment: .leading, spacing: 5) {
                Text(String(format: "%02d:%02d", item.hour, item.minute))
                  .font(LumaStyle.font(31, "Medium"))
                  .monospacedDigit()
                Text(item.title).font(LumaStyle.font(13))
                Text(
                  item.weekdays.isEmpty ? "Один раз" : "Повтор по дням"
                ).font(LumaStyle.font(10)).foregroundStyle(LumaStyle.secondary)
                if item.enabled && item.weekdays.isEmpty && item.onceAt < Date() {
                  Text("Завершён")
                    .font(LumaStyle.font(10)).foregroundStyle(LumaStyle.secondary)
                } else if item.enabled
                  && !model.queuedAlarmIDs.contains(item.id)
                {
                  Text("Пока вне очереди iPhone")
                    .font(LumaStyle.font(10)).foregroundStyle(LumaStyle.amber)
                }
              }
              .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
              .padding(.vertical, 4)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              "Изменить будильник \(String(format: "%02d:%02d", item.hour, item.minute)), \(item.title)"
            )
            .accessibilityHint("Открывает настройку времени и сигнала")
            Toggle(
              "Включить будильник",
              isOn: Binding(
                get: { item.enabled }, set: { _ in
                  if item.enabled { Task { await model.toggleAlarm(item.id) } }
                  else { prepare(.enable(item.id)) }
                })
            ).labelsHidden().tint(LumaStyle.lavender)
          }
        }
      }
    }
  }

}

/// The moon is the flexible second child. Measure actual text before assigning it space.
/// Normal empty content occupies exactly the available viewport, so only elastic bounce remains.
/// Exceptionally large accessibility text can expand the page instead of becoming clipped.
private struct NightEmptyLayout: Layout {
  var availableHeight: CGFloat

  private func metrics(width: CGFloat, subviews: Subviews) -> (heights: [CGFloat], gap: CGFloat) {
    var heights = subviews.enumerated().map { index, view in
      index == 1 ? CGFloat.zero
        : view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }
    let fixedHeight = heights.reduce(0, +)
    let gapCount = max(0, subviews.count - 1)
    let gap = min(22, max(8, (availableHeight - fixedHeight - 100) / CGFloat(max(1, gapCount))))
    if heights.count > 1 {
      heights[1] = min(240, max(0, availableHeight - fixedHeight - CGFloat(gapCount) * gap))
    }
    return (heights, gap)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 320
    let result = metrics(width: width, subviews: subviews)
    let naturalHeight = result.heights.reduce(0, +) + CGFloat(max(0, subviews.count - 1)) * result.gap
    return CGSize(width: width, height: max(availableHeight, naturalHeight))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = metrics(width: bounds.width, subviews: subviews)
    var y = bounds.minY
    for index in subviews.indices {
      subviews[index].place(
        at: CGPoint(x: bounds.midX, y: y), anchor: .top,
        proposal: ProposedViewSize(width: bounds.width, height: result.heights[index]))
      y += result.heights[index] + result.gap
    }
  }
}

struct IntroductionView: View {
  @EnvironmentObject private var model: AppModel
  var body: some View {
    VStack(spacing: 24) {
      MoonOrb().frame(height: 220)
      Text("Доброй ночи.\nЭто Luma.").font(LumaStyle.font(32, "Medium", relativeTo: .largeTitle))
        .multilineTextAlignment(.center)
      Text(
        "Короткие сигналы, ваш голос и личный дневник — чтобы внимательнее исследовать сновидения."
      ).multilineTextAlignment(.center)
      Text(
        "Настраивайте сигналы и сохраняйте сновидения. Личные записи остаются на iPhone."
      ).font(LumaStyle.font(13)).foregroundStyle(LumaStyle.secondary).multilineTextAlignment(
        .center)
      Button("Начать знакомство") { model.completeIntroduction() }.buttonStyle(PrimaryButtonStyle())
    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).lumaScreen()
  }
}
