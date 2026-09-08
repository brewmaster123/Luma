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
  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        HStack {
          Text("luma").font(LumaStyle.font(26, "SemiBold"))
          Spacer()
          Label("ВАШЕ ПРОСТРАНСТВО СНА", systemImage: "sparkle").font(LumaStyle.font(9, "Medium"))
            .foregroundStyle(LumaStyle.secondary)
        }
        VStack(spacing: 0) {
          MoonOrb().frame(height: 210)
          Text(model.stateTitle).font(LumaStyle.font(27, "Medium", relativeTo: .title))
            .multilineTextAlignment(.center)
          Text("Мягкий сигнал. Больше осознанности.").font(LumaStyle.font(13)).foregroundStyle(
            LumaStyle.secondary
          ).padding(.top, 10)
        }
        LumaCard {
          VStack(alignment: .leading, spacing: 16) {
            HStack {
              Label("REM · всю ночь", systemImage: "waveform.path").font(
                LumaStyle.font(17, "SemiBold"))
              Spacer()
              Image(systemName: model.hasPlan ? "sparkle" : "moon.stars").foregroundStyle(
                LumaStyle.lavender)
            }
            Text((model.activeSession?.source ?? model.state.source).title).foregroundStyle(
              LumaStyle.secondary)
            if let s = model.activeSession {
              Text(
                "\(s.episodes.count) предполагаемых эпизодов · с \(s.startedAt.formatted(date:.omitted,time:.shortened))"
              ).font(LumaStyle.font(12))
              Text(model.evidence.explanation).font(LumaStyle.font(12)).foregroundStyle(
                LumaStyle.secondary)
              if s.status == .paused {
                Button("Продолжить сеанс") { Task { await model.resumeSession() } }.buttonStyle(
                  PrimaryButtonStyle())
              }
              Button("Завершить сеанс") { Task { await model.endSession() } }.frame(
                maxWidth: .infinity, minHeight: 44
              ).foregroundStyle(LumaStyle.lavender)
            } else {
              Text(
                "Сигнал в каждом новом предполагаемом REM-эпизоде. Сеанс длится, пока вы его не завершите."
              ).font(LumaStyle.font(13)).foregroundStyle(LumaStyle.secondary)
              Button {
                Task { await model.beginSession() }
              } label: {
                Label("Начать ночь", systemImage: "play.fill")
              }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
            }
            Text("Экспериментальный режим · точность не измерена").font(LumaStyle.font(10))
              .foregroundStyle(LumaStyle.secondary)
          }
        }
        LazyVStack(spacing: 12) {
          HStack {
            Text("Будильники").font(LumaStyle.font(21, "Medium"))
            Spacer()
            Button {
              var a = LumaAlarm()
              a.signal = model.state.signal
              alarm = a
            } label: {
              Image(systemName: "plus").frame(width: 44, height: 44).background(
                LumaStyle.surface, in: Circle())
            }.accessibilityLabel("Добавить будильник")
          }
          if model.state.alarms.isEmpty {
            Text(
              "Добавьте время для короткой подсказки.\nСохраняйте столько будильников, сколько нужно."
            ).font(LumaStyle.font(13)).foregroundStyle(LumaStyle.secondary).frame(
              maxWidth: .infinity, alignment: .leading
            ).padding(.vertical, 10)
          }
          ForEach(model.state.alarms) { a in
            LumaCard {
              HStack(spacing: 12) {
                Button {
                  alarm = a
                } label: {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(String(format: "%02d:%02d", a.hour, a.minute)).font(
                      LumaStyle.font(31, "Medium")
                    ).monospacedDigit()
                    Text(a.title).font(LumaStyle.font(13))
                    Text(
                      a.signal.output.title + " · "
                        + (a.weekdays.isEmpty ? "Один раз" : "Повтор по дням")
                    ).font(LumaStyle.font(10)).foregroundStyle(LumaStyle.secondary)
                    if a.enabled && a.weekdays.isEmpty && a.onceAt < Date() {
                      Text("Завершён").font(LumaStyle.font(10)).foregroundStyle(LumaStyle.secondary)
                    } else if a.enabled && a.signal.output.phoneEnabled
                      && !model.queuedAlarmIDs.contains(a.id)
                    {
                      Text("Пока вне очереди iPhone").font(LumaStyle.font(10)).foregroundStyle(
                        LumaStyle.amber)
                    }
                  }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Toggle(
                  "Включить будильник",
                  isOn: Binding(
                    get: { a.enabled }, set: { _ in Task { await model.toggleAlarm(a.id) } })
                ).labelsHidden().tint(LumaStyle.lavender)
              }
            }
          }
          Text(
            "Список не ограничен. Устройства держат ближайшие сигналы в системной очереди; открывайте Luma ежедневно для её обновления."
          ).font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary).frame(
            maxWidth: .infinity, alignment: .leading)
        }
        if model.state.source.usesWatch || model.state.signal.output.watchEnabled {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "applewatch")
            VStack(alignment: .leading, spacing: 4) {
              Text(model.watchReachable ? "Часы на связи" : "Apple Watch").font(
                LumaStyle.font(12, "Medium"))
              Text(model.watchStatus).font(LumaStyle.font(11))
            }
            Spacer()
          }.foregroundStyle(LumaStyle.secondary)
        }
      }.padding(22).padding(.bottom, 20)
    }.lumaScreen().toolbar(.hidden, for: .navigationBar).sheet(item: $alarm) {
      AlarmEditor(alarm: $0).environmentObject(model)
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
        "REM определяется экспериментально. Luma может пропускать фазы и ошибаться; данные остаются на ваших устройствах."
      ).font(LumaStyle.font(13)).foregroundStyle(LumaStyle.secondary).multilineTextAlignment(
        .center)
      Button("Начать знакомство") { model.completeIntroduction() }.buttonStyle(PrimaryButtonStyle())
    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).lumaScreen()
  }
}
