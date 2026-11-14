import SwiftUI

/// A UI-only preference. Archive / alarm / audio storage formats are unchanged.
enum IndirectMethodHelpPreference {
  static let key = "com.sevchlenko.luma.indirectMethod.skipStartHelp.v1"
}

struct IndirectMethodCard: View {
  var referenceScale: CGFloat = 1
  var referenceVerticalScale: CGFloat? = nil
  @EnvironmentObject private var model: AppModel
  @Environment(\.dynamicTypeSize) private var dynamicType
  @AppStorage(IndirectMethodHelpPreference.key) private var skipStartHelp = false
  @State private var showingHelp = false
  @State private var choosingInterval = false
  @State private var showReadiness = false
  @State private var readyToStart = false
  @State private var helpContinuationPending = false
  @State private var doNotShowAgain = false
  @State private var startInFlight = false

  private var sx: CGFloat { max(0.1, referenceScale) }
  private var sy: CGFloat { max(0.1, referenceVerticalScale ?? referenceScale) }
  private var intervalUnavailable: Bool { model.indirectRunning || model.busy || startInFlight }
  private var actionUnavailable: Bool {
    model.busy || model.systemAlarms.preparing || startInFlight
      || helpContinuationPending || showingHelp || showReadiness
  }

  var body: some View {
    VStack(spacing: 8) {
      if dynamicType.isAccessibilitySize {
        accessibleControls
      } else {
        referenceControls
      }
      if model.indirectRunning { runningQueueStatus }
    }
    .sheet(isPresented: $choosingInterval) {
      IndirectIntervalSheet().environmentObject(model)
    }
    .sheet(isPresented: $showingHelp, onDismiss: {
      // A swipe or cancellation never sets this intent. Consume it exactly once.
      guard helpContinuationPending else { return }
      helpContinuationPending = false
      prepareStart()
    }) {
      IndirectStartHelpSheet(doNotShowAgain: $doNotShowAgain) {
        guard !helpContinuationPending else { return }
        // Commit the draft only on Continue. Cancel does not silently opt the user out.
        skipStartHelp = doNotShowAgain
        helpContinuationPending = true
        showingHelp = false
      } cancelAction: {
        helpContinuationPending = false
        showingHelp = false
      }
      .environmentObject(model)
    }
    .sheet(isPresented: $showReadiness, onDismiss: {
      guard readyToStart else { return }
      readyToStart = false
      requestStart()
    }) {
      SignalReadinessView(continueTitle: "Разрешить и начать") {
        readyToStart = true
      }.environmentObject(model)
    }
  }

  private var referenceControls: some View {
    GeometryReader { geometry in
      ZStack {
        // Two quiet rules, deliberately with no star or other central ornament.
        ReferenceIndirectRule().frame(width: 400 * sx, height: max(0.5, sx))
          .position(x: geometry.size.width / 2, y: 0)
        ReferenceIndirectRule().frame(width: 400 * sx, height: max(0.5, sx))
          .position(x: geometry.size.width / 2, y: 12 * sy)
        Text("Непрямой метод")
          .font(ReferenceNightStyle.serif(31 * sx))
          .foregroundStyle(Color(hex: 0xF9EBC8))
          .lineLimit(1).minimumScaleFactor(0.75)
          .position(x: geometry.size.width / 2, y: 48 * sy)
        stepControl(-1)
          .position(x: geometry.size.width * 280 / 1024, y: 158 * sy)
        stepControl(1)
          .position(x: geometry.size.width * 742 / 1024, y: 158 * sy)
        Button { choosingInterval = true } label: {
          Text("\(model.indirectIntervalMinutes)")
            .font(ReferenceNightStyle.serif(114 * sx))
            .tracking(8 * sx)
            .monospacedDigit()
            .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFBE7CD), Color(hex: 0xFBE3C6), Color(hex: 0xFAE4C8)], startPoint: .top, endPoint: .bottom))
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: 250 * sx, height: max(44, 130 * sx))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(intervalUnavailable)
        .accessibilityLabel("Интервал \(model.indirectIntervalMinutes) минут")
        .accessibilityHint("Открывает выбор интервала от 10 до 60 минут")
        .accessibilityIdentifier("indirect.interval")
        .position(x: geometry.size.width / 2, y: 155 * sy)
        Text("мин")
          .font(ReferenceNightStyle.serif(28 * sx))
          .foregroundStyle(ReferenceNightStyle.text)
          .position(x: geometry.size.width / 2, y: 220 * sy)
        sessionButton
          .frame(width: 628 * sx, height: max(44, 100 * sx))
          .position(x: geometry.size.width / 2, y: 345 * sy)
      }
    }
    .frame(height: max(44, 400 * sy))
  }

  private var accessibleControls: some View {
    VStack(spacing: 18) {
      VStack(spacing: 5) {
        ReferenceIndirectRule().frame(height: 0.5)
        ReferenceIndirectRule().frame(height: 0.5)
      }.frame(maxWidth: 220)
      Text("Непрямой метод")
        .font(ReferenceNightStyle.serif(24))
        .foregroundStyle(ReferenceNightStyle.text)
        .multilineTextAlignment(.center)
      HStack(spacing: 20) {
        stepControl(-1)
        Button { choosingInterval = true } label: {
          VStack(spacing: 0) {
            Text("\(model.indirectIntervalMinutes)").font(ReferenceNightStyle.serif(58))
              .monospacedDigit()
            Text("мин").font(ReferenceNightStyle.serif(22))
          }.foregroundStyle(ReferenceNightStyle.text).frame(minWidth: 90, minHeight: 90)
        }.buttonStyle(.plain).disabled(intervalUnavailable)
          .accessibilityLabel("Интервал \(model.indirectIntervalMinutes) минут")
          .accessibilityIdentifier("indirect.interval")
        stepControl(1)
      }
      sessionButton.frame(minHeight: 58)
    }.padding(.horizontal, 24)
  }

  private func stepControl(_ delta: Int) -> some View {
    let atLimit = delta < 0 ? model.indirectIntervalMinutes <= 10 : model.indirectIntervalMinutes >= 60
    return Button {
      guard !intervalUnavailable else { return }
      let next = min(60, max(10, model.indirectIntervalMinutes + delta))
      Task { await model.setIndirectInterval(next) }
    } label: {
      ZStack {
        Circle().fill(
          LinearGradient(colors: [Color(hex: 0x20233B), Color(hex: 0x071120)],
            startPoint: .top, endPoint: .bottom))
          .overlay(Circle().stroke(
            LinearGradient(colors: [ReferenceNightStyle.text.opacity(0.65),
              ReferenceNightStyle.amber.opacity(0.16)], startPoint: .top, endPoint: .bottom),
            lineWidth: max(0.5, sx)))
          .frame(width: max(28, 76 * sx), height: max(28, 76 * sx))
        Text(delta < 0 ? "−" : "+")
          .font(ReferenceNightStyle.serif(max(23, 43 * sx)))
          .foregroundStyle(ReferenceNightStyle.text)
      }.frame(width: max(44, 76 * sx), height: max(44, 76 * sx))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(intervalUnavailable || atLimit)
    .opacity(atLimit ? 0.35 : 1)
    .accessibilityLabel(delta < 0 ? "Уменьшить интервал на минуту" : "Увеличить интервал на минуту")
    .accessibilityIdentifier(delta < 0 ? "indirect.decrease" : "indirect.increase")
  }

  private var sessionButton: some View {
    Button(action: sessionTapped) {
      HStack(spacing: max(10, 26 * sx)) {
        Image(systemName: model.indirectRunning ? "stop.fill" : "play.fill")
          .font(.system(size: max(13, 30 * sx), weight: .regular))
          .foregroundStyle(ReferenceNightStyle.amber)
        Text(model.indirectRunning ? "Завершить сеанс" : "Начать сеанс")
          .font(ReferenceNightStyle.serif(max(15, 36 * sx)))
          .foregroundStyle(Color(hex: 0xF8EBCA))
          .lineLimit(1).minimumScaleFactor(0.65)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(ReferenceIndirectSessionButtonStyle())
    .disabled(actionUnavailable)
    .accessibilityIdentifier("indirect.start")
  }

  private var runningQueueStatus: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      if let next = model.systemAlarms.indirectRecords.first(where: { $0.fireAt > context.date }) {
        HStack(spacing: 5) {
          Text("Следующий сигнал через")
          Text(next.fireAt, style: .timer).monospacedDigit()
        }.font(LumaStyle.font(12)).foregroundStyle(ReferenceNightStyle.secondary)
      } else {
        Text("В очереди нет новых сигналов. Откройте справку.")
          .font(LumaStyle.font(12)).foregroundStyle(ReferenceNightStyle.amber)
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
      await model.requestIndirectMethodStart()
    }
  }
}

private struct ReferenceIndirectRule: View {
  var body: some View {
    Rectangle().fill(LinearGradient(
      colors: [.clear, ReferenceNightStyle.text.opacity(0.22), .clear],
      startPoint: .leading, endPoint: .trailing))
      .accessibilityHidden(true)
  }
}

private struct ReferenceIndirectSessionButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduced
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(ReferenceNightStyle.text)
      .frame(minHeight: 44)
      .background(LinearGradient(stops: [
        .init(color: Color(hex: 0x37364F), location: 0),
        .init(color: Color(hex: 0x131D34), location: 0.42),
        .init(color: Color(hex: 0x0C152A), location: 0.82),
        .init(color: Color(hex: 0x212130), location: 1)
      ], startPoint: .top, endPoint: .bottom), in: Capsule())
      .overlay(Capsule().stroke(
        LinearGradient(colors: [Color(hex: 0xBCB4D3).opacity(0.72), Color(hex: 0x545067).opacity(0.20)],
          startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
      .opacity(enabled ? 1 : 0.45)
      .scaleEffect(configuration.isPressed && !reduced ? 0.992 : 1)
      .animation(reduced ? nil : .easeOut(duration: 0.18), value: configuration.isPressed)
  }
}

private struct IndirectStartHelpSheet: View {
  @EnvironmentObject private var model: AppModel
  @Binding var doNotShowAgain: Bool
  let continueAction: () -> Void
  let cancelAction: () -> Void
  @State private var continuing = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Непрямой метод").font(ReferenceNightStyle.serif(27))
        IndirectReferenceHelpText().environmentObject(model)
        Toggle("Больше не показывать", isOn: $doNotShowAgain)
          .toggleStyle(ReferenceHelpCheckboxStyle())
          .accessibilityIdentifier("indirect.help.skip")
        Button("Продолжить") {
          guard !continuing, !model.busy, !model.systemAlarms.preparing else { return }
          continuing = true
          continueAction()
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .buttonStyle(ReferenceIndirectSessionButtonStyle())
        .disabled(continuing || model.busy || model.systemAlarms.preparing)
        .accessibilityIdentifier("indirect.help.continue")
        Button("Отмена", role: .cancel, action: cancelAction)
          .frame(maxWidth: .infinity, minHeight: 44)
          .buttonStyle(.plain).foregroundStyle(ReferenceNightStyle.secondary)
          .accessibilityIdentifier("indirect.help.cancel")
      }
      .font(LumaStyle.font(14)).lineSpacing(5).padding(26)
    }
    .background(Color(hex: 0x061020)).foregroundStyle(ReferenceNightStyle.text)
    .presentationDetents([.large]).presentationDragIndicator(.visible)
    .presentationCornerRadius(28).presentationBackground(Color(hex: 0x061020))
  }
}

private struct ReferenceHelpCheckboxStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
          .font(.system(size: 22)).foregroundStyle(ReferenceNightStyle.text)
        configuration.label.foregroundStyle(ReferenceNightStyle.text)
        Spacer(minLength: 0)
      }.frame(minHeight: 44).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(configuration.isOn ? "Выбрано" : "Не выбрано")
  }
}

private struct IndirectIntervalSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var minutes = 30
  var body: some View {
    ScrollView {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Интервал").font(LumaStyle.font(23, "Medium"))
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Закрыть")
      }
      Text("Повторять сигнал каждые")
        .font(LumaStyle.font(13)).foregroundStyle(LumaStyle.secondary)
      Picker("Минут между сигналами", selection: $minutes) {
        ForEach(10...60, id: \.self) { Text("\($0) мин").tag($0) }
      }.pickerStyle(.wheel).frame(height: 185).accessibilityIdentifier("indirect.minutes")
      Button("Сохранить интервал") {
        Task { if await model.setIndirectInterval(minutes) { dismiss() } }
      }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("indirect.save")
    }
    .padding(24)
    }.background(LumaStyle.surface).foregroundStyle(LumaStyle.text)
    .presentationDetents([.large]).presentationDragIndicator(.visible)
    .presentationCornerRadius(28).presentationBackground(LumaStyle.surface)
    .onAppear { minutes = model.indirectIntervalMinutes }
  }
}


/// Verbatim paragraphs from the pre-existing IndirectHelpView, including its live queue line.
private struct IndirectReferenceHelpText: View {
  @EnvironmentObject private var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Функция предназначена для практики непрямого метода после коротких пробуждений.")
      Text("Интервал задаёт время между началами сигналов. Выберите любое значение от 10 до 60 минут, затем нажмите «Начать».")
      Text("Например, при интервале 15 минут сигналы начинаются через 15, 30, 45 минут и так далее. Выбранный интервал сохраняется, пока вы его не измените.")
      Text("Режим предназначен для повторяющихся коротких сигналов до завершения сеанса. Это расписание по времени; оно не определяет фазу сна.")
      Text("Каждый интервал — отдельный будильник AlarmKit. Во время ночного режима играет тихий фон, а Luma останавливает текущий сигнал через выбранное в настройках время: от 3 до 10 секунд, по умолчанию 4. Сначала проверьте это с блокировкой. Сам фон не вызывает вибрацию часов.")
      Text("Luma заранее ставит до 60 сигналов в пределах ближайших 12 часов и пополняет очередь при открытии приложения. При интервале 30 минут это до 24 сигналов. Другие будильники используют ту же очередь. Ориентируйтесь на время последнего поставленного сигнала ниже и открывайте Luma для продления.")
      if let until = model.systemAlarms.queueUntil {
        Text("Сейчас сигналы в очереди до \(until.formatted(date: .abbreviated, time: .shortened)).")
      }
    }
  }
}

struct SmartAlarmReferenceHelp: View {
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .top) {
          Text("Умный будильник").font(ReferenceNightStyle.serif(27))
          Spacer()
          Button { dismiss() } label: {
            Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("Закрыть справку")
        }
        // The basis has no separate smart-alarm help view. Reuse its existing explanation verbatim.
        Text("Будильник через AlarmKit. Длительность сигнала выбирается в настройках: от 3 до 10 секунд. Перед ночью проверьте звук и его завершение с заблокированным iPhone.")
      }.font(LumaStyle.font(14)).lineSpacing(5).padding(26)
    }.background(Color(hex: 0x061020)).foregroundStyle(ReferenceNightStyle.text)
      .presentationDetents([.large]).presentationDragIndicator(.visible)
      .presentationCornerRadius(28).presentationBackground(Color(hex: 0x061020))
  }
}
