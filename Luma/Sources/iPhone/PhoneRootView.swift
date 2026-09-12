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
  @State private var showingREMHelp = false

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
          remCard
          alarmsSection
          if model.state.source.usesWatch || model.state.signal.output.watchEnabled {
            watchConnection
          }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
      }
      .scrollIndicators(.hidden)
      .scrollBounceBehavior(.always, axes: .vertical)
    }
    .lumaScreen()
    .toolbar(.hidden, for: .navigationBar)
    .sheet(item: $alarm) { AlarmEditor(alarm: $0).environmentObject(model) }
    .sheet(isPresented: $showingREMHelp) {
      REMHelpView()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(LumaStyle.surface)
    }
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
      Text("Мягкий сигнал. Больше осознанности.")
        .font(LumaStyle.font(13))
        .foregroundStyle(LumaStyle.secondary)
        .multilineTextAlignment(.center)
    }
  }

  private var remCard: some View {
    LumaCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 0) {
          Text("REM · всю ночь").font(LumaStyle.font(17, "SemiBold"))
          Button { showingREMHelp = true } label: {
            Image(systemName: "questionmark")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(LumaStyle.lavender)
              .frame(width: 23, height: 23)
              .background(
                LinearGradient(
                  colors: [LumaStyle.lavender.opacity(0.11), LumaStyle.lavender.opacity(0.03)],
                  startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
              .overlay(Circle().stroke(LumaStyle.lavender.opacity(0.34), lineWidth: 0.8))
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Как работает REM всю ночь")
          .accessibilityHint("Открывает справку о подсказках во сне")
          Spacer(minLength: 4)
          Image(systemName: "waveform.path")
            .foregroundStyle(LumaStyle.lavender)
            .accessibilityHidden(true)
        }
        Text((model.activeSession?.source ?? model.state.source).title)
          .font(LumaStyle.font(13))
          .foregroundStyle(LumaStyle.secondary)
        if let session = model.activeSession {
          Text(
            "\(session.episodes.count) предполагаемых эпизодов · с \(session.startedAt.formatted(date: .omitted, time: .shortened))"
          ).font(LumaStyle.font(12))
          Text(model.evidence.explanation)
            .font(LumaStyle.font(12))
            .foregroundStyle(LumaStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if session.status == .paused {
            Button("Продолжить сеанс") { Task { await model.resumeSession() } }
              .buttonStyle(PrimaryButtonStyle())
          }
          Button("Завершить сеанс") { Task { await model.endSession() } }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(LumaStyle.lavender)
        } else {
          Button { Task { await model.beginSession() } } label: {
            Label("Начать ночь", systemImage: "play.fill")
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(model.busy)
        }
      }
    }
  }

  private var alarmsSection: some View {
    LazyVStack(spacing: 12) {
      HStack {
        Text("Будильники").font(LumaStyle.font(21, "Medium"))
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
                  item.signal.output.title + " · "
                    + (item.weekdays.isEmpty ? "Один раз" : "Повтор по дням")
                ).font(LumaStyle.font(10)).foregroundStyle(LumaStyle.secondary)
                if item.enabled && item.weekdays.isEmpty && item.onceAt < Date() {
                  Text("Завершён")
                    .font(LumaStyle.font(10)).foregroundStyle(LumaStyle.secondary)
                } else if item.enabled && item.signal.output.phoneEnabled
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
                get: { item.enabled }, set: { _ in Task { await model.toggleAlarm(item.id) } })
            ).labelsHidden().tint(LumaStyle.lavender)
          }
        }
      }
    }
  }

  private var watchConnection: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "applewatch")
      VStack(alignment: .leading, spacing: 4) {
        Text(model.watchReachable ? "Часы на связи" : "Apple Watch")
          .font(LumaStyle.font(12, "Medium"))
        Text(model.watchStatus).font(LumaStyle.font(11))
      }
      Spacer()
    }.foregroundStyle(LumaStyle.secondary)
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

private struct REMHelpView: View {
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text("REM · всю ночь").font(LumaStyle.font(21, "Medium"))
          Spacer()
          Button { dismiss() } label: {
            Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
              .frame(width: 44, height: 44).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("Закрыть справку")
        }
        Text("REM-фаза (фаза быстрого сна) — это главное «окно» для осознанных сновидений (ОС).")
        Text("Именно в этот период наш мозг проявляет высокую активность, сопоставимую с бодрствованием, в то время как тело максимально расслаблено и всё ещё находится в спящем состоянии.")
        Text("Современные смарт-часы с помощью посторонних приложений могут определять REM-фазу человека в относительно реальном времени с примерно 70–75 % попадания.")
        Text("Приложение Luma и его функции настоятельно рекомендуется использовать со смарт-часами для большей точности обнаружения REM-фазы человека в реальном времени. Но также приложение можно использовать и просто со смартфоном без часов, но процент определения фазы значительно снижается.")
        Text("REM-фаза сна происходит примерно каждые 90–120 минут во время, когда человек спит.")
        Text("Соответственно, включая эту функцию «REM всю ночь», сигнал вибрации со смарт-часов или сигнал с вашего смартфона будут издаваться каждый раз, когда вы будете входить в REM-фазу в режиме реального времени.")
        Text("И что важно, сигналы и вибрация будут выключаться сами, без вашего ручного вмешательства.")
        Text("Это позволит вам пробудиться прямо на пике вашей REM-фазы, при этом не двигая своё тело для отключения будильника, что позволит вам кардинально увеличить эффективность использования техник для вхождения в осознанные сновидения.")
        Text("При определённых постоянных тренировках и при помощи Luma со смарт-часами можно достичь результата, что вы за ночь практически гарантированно будете попадать в осознанное сновидение.")
      }.font(LumaStyle.font(14)).lineSpacing(4).foregroundStyle(LumaStyle.text)
        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 24).padding(.vertical, 20)
    }.scrollBounceBehavior(.basedOnSize).scrollIndicators(.hidden)
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
        "REM определяется экспериментально. Luma может пропускать фазы и ошибаться; данные остаются на ваших устройствах."
      ).font(LumaStyle.font(13)).foregroundStyle(LumaStyle.secondary).multilineTextAlignment(
        .center)
      Button("Начать знакомство") { model.completeIntroduction() }.buttonStyle(PrimaryButtonStyle())
    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).lumaScreen()
  }
}
