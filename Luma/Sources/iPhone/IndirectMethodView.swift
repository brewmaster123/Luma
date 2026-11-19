import SwiftUI

/// A UI-only preference. Archive / alarm / audio storage formats are unchanged.
enum IndirectMethodHelpPreference {
  static let key = "com.sevchlenko.luma.indirectMethod.skipStartHelp.v1"
}

/// The middle of the Night screen: the interval with its two round buttons and the session button.
/// It lays itself out on the whole screen, at the places the design gives each part.
struct IndirectMethodCard: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.atelierViewport) private var viewport
  @AppStorage(IndirectMethodHelpPreference.key) private var skipStartHelp = false
  @State private var showingHelp = false
  @State private var showingInfo = false
  @State private var choosingInterval = false
  @State private var showReadiness = false
  @State private var readyToStart = false
  @State private var helpContinuationPending = false
  @State private var doNotShowAgain = false
  @State private var startInFlight = false

  private var intervalUnavailable: Bool { model.indirectRunning || model.busy || startInFlight }
  private var actionUnavailable: Bool {
    model.busy || model.systemAlarms.preparing || startInFlight
      || helpContinuationPending || showingHelp || showReadiness
  }

  var body: some View {
    let u = viewport.u
    let v = viewport.v
    let middle = viewport.size.width / 2
    ZStack {
      rule.position(x: middle, y: 297 * v)
      rule.position(x: middle, y: 303.8 * v)
      Button { showingInfo = true } label: {
        Text(tr("Непрямой метод"))
          .font(Atelier.display(18.8 * u)).tracking(0.2)
          .foregroundStyle(Atelier.ink)
          .lineLimit(1).minimumScaleFactor(0.75)
          .frame(minWidth: 180 * u, minHeight: 34)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint(tr("Открывает справку"))
      .accessibilityIdentifier("indirect.help")
      .position(x: middle, y: 324.35 * v)
      stepControl(-1).position(x: 109.9 * u, y: 386.9 * v)
      stepControl(1).position(x: 291.3 * u, y: 386.9 * v)
      numberButton.position(x: middle, y: 385.2 * v)
      Text(tr("мин"))
        .font(Atelier.uiFixed(11 * u)).tracking(0.51)
        .foregroundStyle(Atelier.ink)
        .position(x: middle, y: 422.2 * v)
        .accessibilityHidden(true)
      sessionButton
        .frame(width: 246.5 * u, height: max(44, 48 * u))
        .position(x: middle, y: 493.3 * v)
      if model.indirectRunning {
        runningQueueStatus.position(x: middle, y: 536 * v)
      }
    }
    .frame(width: viewport.size.width, height: viewport.size.height)
    .atelierSheet(isPresented: $choosingInterval) {
      IndirectIntervalSheet().environmentObject(model)
    }
    .atelierSheet(isPresented: $showingInfo) {
      IndirectHelpSheet(doNotShowAgain: .constant(false), startMode: false,
        continueAction: {}, cancelAction: {})
        .environmentObject(model)
    }
    .atelierSheet(isPresented: $showingHelp, onDismiss: {
      // A swipe or cancellation never sets this intent. Consume it exactly once.
      guard helpContinuationPending else { return }
      helpContinuationPending = false
      prepareStart()
    }) {
      IndirectHelpSheet(doNotShowAgain: $doNotShowAgain, startMode: true, continueAction: {
        guard !helpContinuationPending else { return }
        // Commit the draft only on Continue. Cancel does not silently opt the user out.
        skipStartHelp = doNotShowAgain
        helpContinuationPending = true
        showingHelp = false
      }, cancelAction: {
        helpContinuationPending = false
        showingHelp = false
      })
      .environmentObject(model)
    }
    .atelierSheet(isPresented: $showReadiness, onDismiss: {
      guard readyToStart else { return }
      readyToStart = false
      requestStart()
    }) {
      SignalReadinessView(continueTitle: tr("Разрешить и начать")) {
        readyToStart = true
      }.environmentObject(model)
    }
  }

  private var rule: some View {
    Rectangle()
      .fill(LinearGradient(colors: [.clear, Atelier.ink.opacity(0.26), .clear],
        startPoint: .leading, endPoint: .trailing))
      .frame(width: 157 * viewport.u, height: 0.5)
      .accessibilityHidden(true)
  }

  private var numberButton: some View {
    let u = viewport.u
    return Button { choosingInterval = true } label: {
      Text("\(model.indirectIntervalMinutes)")
        .font(Atelier.numbers(55.7 * u)).tracking(0.39)
        .foregroundStyle(Atelier.ink)
        .lineLimit(1).minimumScaleFactor(0.7)
        .frame(width: 112.5 * u, height: max(44, 55.8 * u))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(intervalUnavailable)
    .accessibilityLabel(tr("Интервал") + ", " + L10n.everyMinutes(model.indirectIntervalMinutes))
    .accessibilityHint(tr("Открывает выбор интервала от 10 до 60 минут"))
    .accessibilityIdentifier("indirect.interval")
  }

  private func stepControl(_ delta: Int) -> some View {
    let atLimit = delta < 0 ? model.indirectIntervalMinutes <= 10 : model.indirectIntervalMinutes >= 60
    return PebbleButton(sign: delta < 0 ? .minus : .plus, size: 34 * viewport.u,
      label: delta < 0 ? tr("Уменьшить интервал на минуту") : tr("Увеличить интервал на минуту")) {
      guard !intervalUnavailable else { return }
      let next = min(60, max(10, model.indirectIntervalMinutes + delta))
      Task { await model.setIndirectInterval(next) }
    }
    .disabled(intervalUnavailable || atLimit)
    .accessibilityIdentifier(delta < 0 ? "indirect.decrease" : "indirect.increase")
  }

  private var sessionButton: some View {
    let u = viewport.u
    return Button(action: sessionTapped) {
      HStack(spacing: 11 * u) {
        if !model.indirectRunning {
          Image(systemName: "play.fill").font(.system(size: 10.5 * u))
        }
        Text(model.indirectRunning ? tr("Завершить сеанс") : tr("Начать сеанс"))
      }
    }
    .buttonStyle(VelvetButtonStyle(height: max(44, 48 * u), fontSize: 18.5 * u))
    .disabled(actionUnavailable)
    .accessibilityIdentifier("indirect.start")
  }

  private var runningQueueStatus: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      if let next = model.systemAlarms.indirectRecords.first(where: { $0.fireAt > context.date }) {
        HStack(spacing: 5) {
          Text(tr("Следующий сигнал через"))
          Text(next.fireAt, style: .timer).monospacedDigit()
        }
        .font(Atelier.uiFixed(12 * viewport.u)).foregroundStyle(Atelier.dim)
      } else {
        Text(tr("В очереди нет новых сигналов. Откройте справку."))
          .font(Atelier.uiFixed(12 * viewport.u)).foregroundStyle(Atelier.ink.opacity(0.9))
      }
    }
  }

  private func sessionTapped() {
    guard !actionUnavailable else { return }
    if model.indirectRunning {
      startInFlight = true
      Task { @MainActor in
        defer { startInFlight = false }
        await model.stopIndirectMethod()
        // The person ended the session: an alarm that is ringing now must not start a new one.
        if !model.indirectRunning { SmartAlarmFollowUp.shared.userEndedSession() }
        // 1.0: the night background goes off by itself once nothing needs it (NightBackgroundPolicy).
        NightBackgroundPolicy.shared.lookSoon()
      }
    } else if skipStartHelp {
      prepareStart()
    } else {
      doNotShowAgain = false
      helpContinuationPending = false
      showingHelp = true
    }
  }

  private func prepareStart() {
    guard !model.indirectRunning, !model.busy, !model.systemAlarms.preparing, !startInFlight else { return }
    if model.systemAlarms.acceptedLimitations { requestStart() }
    else { readyToStart = false; showReadiness = true }
  }

  private func requestStart() {
    guard !model.indirectRunning, !model.busy, !model.systemAlarms.preparing, !startInFlight else { return }
    startInFlight = true
    Task { @MainActor in
      defer { startInFlight = false }
      await NightBackgroundPolicy.shared.settled()
      await model.requestIndirectMethodStart()
    }
  }
}

/// What will happen tonight, in the fewest words, with the interval and the signal length that are set now.
/// `startMode`: shown before a session starts (with "do not show again"); otherwise it is plain help.
private struct IndirectHelpSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.atelierDismiss) private var dismiss
  @Binding var doNotShowAgain: Bool
  var startMode: Bool
  let continueAction: () -> Void
  let cancelAction: () -> Void
  @State private var continuing = false

  var body: some View {
    AtelierSheet(tr("Непрямой метод")) {
      SheetLead(text: String(format: tr("Пока вы спите, %@ будет звучать короткий сигнал. Он разбудит вас на мгновение — это и есть момент для практики."),
        L10n.everyMinutes(model.indirectIntervalMinutes)))
      VStack(alignment: .leading, spacing: 10) {
        SheetPoint(text: String(format: tr("Сигнал длится %@ и смолкает сам. Длительность меняется в настройках."),
          L10n.seconds(model.alarmStopSeconds)))
        SheetPoint(text: tr("Это расписание по времени: фазы сна приложение не определяет."))
        SheetPoint(text: tr("Перед первой ночью проверьте сигнал с заблокированным iPhone."))
      }
      .padding(.bottom, 16)
      SheetNote(text: tr("Во время сеанса беззвучно работает ночной фон — он нужен, чтобы сигналы вовремя смолкали. Сигналы ставятся заранее: до 60 на ближайшие 12 часов."))
      if let until = model.systemAlarms.queueUntil {
        SheetNote(text: String(format: tr("Сейчас сигналы в очереди до %@."), L10n.dateTime(until)))
          .padding(.top, 8)
      }
      if startMode {
        Toggle(isOn: $doNotShowAgain) { Text(tr("Больше не показывать")) }
          .toggleStyle(RoundMarkToggleStyle())
          .padding(.top, 12)
          .accessibilityIdentifier("indirect.help.skip")
        Button(tr("Продолжить")) {
          guard !continuing, !model.busy, !model.systemAlarms.preparing else { return }
          continuing = true
          continueAction()
        }
        .buttonStyle(VelvetButtonStyle())
        .disabled(continuing || model.busy || model.systemAlarms.preparing)
        .padding(.top, 8)
        .accessibilityIdentifier("indirect.help.continue")
        Button(tr("Отмена"), action: cancelAction)
          .buttonStyle(VelvetButtonStyle(secondary: true))
          .padding(.top, 14)
          .accessibilityIdentifier("indirect.help.cancel")
      } else {
        Button(tr("Понятно")) { dismiss() }
          .buttonStyle(VelvetButtonStyle())
          .padding(.top, 18)
      }
    }
  }
}

/// A line with a round mark on its left: "Больше не показывать".
struct RoundMarkToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(alignment: .center, spacing: 12) {
        RoundMark(on: configuration.isOn)
        configuration.label.font(Atelier.ui(14.5)).foregroundStyle(Atelier.body)
        Spacer(minLength: 0)
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(configuration.isOn ? tr("Выбрано") : tr("Не выбрано"))
  }
}

private struct IndirectIntervalSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.atelierDismiss) private var dismiss
  @State private var minutes = 30
  @State private var saving = false

  private var sliderValue: Binding<Double> {
    Binding(get: { Double(minutes) }, set: { minutes = min(60, max(10, Int($0.rounded()))) })
  }

  var body: some View {
    AtelierSheet(tr("Интервал")) {
      Text(tr("Пауза между сигналами")).font(Atelier.ui(13)).foregroundStyle(Atelier.note)
        .frame(maxWidth: .infinity, alignment: .center)
      HStack(spacing: 18) {
        PebbleButton(sign: .minus, size: 44, label: tr("Уменьшить минуты")) {
          minutes = max(10, minutes - 1)
        }
        .disabled(minutes <= 10)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("\(minutes)").font(Atelier.numbers(54)).foregroundStyle(Atelier.ink)
          Text(tr("мин")).font(Atelier.ui(13)).foregroundStyle(Atelier.dim)
        }
        .frame(minWidth: 120)
        .accessibilityElement(children: .combine)
        PebbleButton(sign: .plus, size: 44, label: tr("Увеличить минуты")) {
          minutes = min(60, minutes + 1)
        }
        .disabled(minutes >= 60)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
      AtelierSlider(value: sliderValue, range: 10...60, label: tr("Минут между сигналами"))
        .accessibilityIdentifier("indirect.minutes")
      HStack {
        Text("10"); Spacer(); Text("60")
      }
      .font(Atelier.ui(11.5)).foregroundStyle(Atelier.note)
      .accessibilityHidden(true)
      Button(tr("Сохранить")) {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
          defer { saving = false }
          if await model.setIndirectInterval(minutes) { dismiss() }
        }
      }
      .buttonStyle(VelvetButtonStyle())
      .disabled(saving)
      .padding(.top, 18)
      .accessibilityIdentifier("indirect.save")
    }
    .onAppear { minutes = model.indirectIntervalMinutes }
  }
}

/// Help for the Smart alarm heading.
struct SmartAlarmHelp: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.atelierDismiss) private var dismiss

  var body: some View {
    AtelierSheet(tr("Умный будильник")) {
      SheetLead(text: tr("Будит в назначенное время коротким сигналом, который смолкает сам."))
      VStack(alignment: .leading, spacing: 10) {
        SheetPoint(text: String(format: tr("Сигнал длится %@. Длительность меняется в настройках."),
          L10n.seconds(model.alarmStopSeconds)))
        SheetPoint(text: tr("Будильников может быть несколько, у каждого свои дни недели."))
        SheetPoint(text: tr("По желанию после будильника сам начнётся сеанс непрямого метода: переключатель — в окне будильника."))
        SheetPoint(text: tr("Перед ночью проверьте звук с заблокированным iPhone."))
      }
      Button(tr("Понятно")) { dismiss() }
        .buttonStyle(VelvetButtonStyle())
        .padding(.top, 20)
    }
  }
}
