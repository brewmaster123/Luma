import SwiftUI

/// Settings. Every control calls the same functions of the app model as in 0.9.7;
/// what is new is the look, the choice of language and the 3–20 second range of the signal.
/// The page opens with "Сигнал будильника" right under the clouds, exactly as in the approved design;
/// the language has a section of its own lower down (the user's decision, 16 Nov 2026).
/// "Помощь и устройства" has a third row, "Контакты разработчиков", which opens a chat with the
/// developers in Telegram (the user's request, 17 Nov 2026).
struct SettingsView: View {
  var isActive = true
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var language = LanguageStore.shared
  @Environment(\.atelierViewport) private var viewport
  @Environment(\.openURL) private var openURL

  private enum Panel: String, Identifiable {
    case language, sound, readiness, rainOff, cancelAll, wipe
    var id: String { rawValue }
  }

  @State private var panel: Panel?
  /// The readiness sheet was opened in order to run a test signal afterwards.
  @State private var readinessWantsProbe = false
  @State private var readyToProbe = false
  @State private var probeDelay: TimeInterval = 3
  /// The test now in the queue was started from the lock-screen row (60 s), not from the 3-second button.
  @State private var lockProbe = true
  /// Applied after the language sheet has closed, so the page is rebuilt with no sheet in the way.
  @State private var pendingLanguage: AppLanguage?

  private var signalsBusy: Bool { model.busy || model.systemAlarms.preparing }

  /// The test signal that is waiting or sounding now, if any.
  private var activeProbe: SystemAlarmRecord? {
    let now = Date()
    return model.systemAlarms.ledger.records.first(where: {
      $0.kind == .probe && now < $0.stopAt.addingTimeInterval(2)
    })
  }

  private var soundBinding: Binding<UUID?> {
    Binding(get: { model.state.signal.voiceID }, set: { id in
      var signal = model.state.signal
      signal.voiceID = id
      model.updateSignal(signal)
    })
  }

  private var soundName: String {
    model.state.voices.first(where: { $0.id == model.state.signal.voiceID })?.name
      ?? tr("Мелодия Lumenoir")
  }

  var body: some View {
    let u: CGFloat = viewport.u
    let width: CGFloat = viewport.size.width
    let listTop: CGFloat = 195 * u
    let listHeight: CGFloat = max(200, viewport.bankClipLine - listTop)
    return ZStack(alignment: .topLeading) {
      SettingsBackScene(isActive: isActive)
      list(height: listHeight)
        .frame(width: width, height: listHeight)
        .offset(y: listTop)
      SettingsForeScene(isActive: isActive)
      // The clouds at the foot of the page are the Night screen's own bank, in the same place:
      // the cards sink into them as the alarm list does on Night.
      CloudBank(isActive: isActive)
    }
    .frame(width: width, height: viewport.size.height, alignment: .topLeading)
    .foregroundStyle(Atelier.ink)
    .environment(\.atelierLamp, AtelierLamp.warm(at: SettingsLamp.point(viewport)))
    .sheet(item: $panel, onDismiss: panelClosed) { item in
      panelView(item).environmentObject(model)
    }
  }

  // MARK: The list

  private func list(height: CGFloat) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        section(tr("Сигнал будильника")) { signalCard }
        section(tr("Ночной фон")) { rainCard }
        section(tr("Проверка")) { checkCard }
        section(tr("Помощь и устройства")) { helpCard }
        section(tr("Язык")) { languageCard }
        section(tr("Данные")) { dataCard }
        remCard
        Text(versionLine).font(Atelier.ui(11)).foregroundStyle(Atelier.foot)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .padding(.top, 6)
          .accessibilityIdentifier("settings.version")
      }
      // 19 + the title's own 4 = 23 pt below the list's top (195): the heading "Сигнал будильника" starts
      // at 218 pt and its card at 254 pt, as in the design (Atelier-Night-Prototype-06), where the clouds
      // in front of the list end just above that heading.
      .padding(EdgeInsets(top: 19, leading: 21, bottom: 46, trailing: 21))
    }
    .scrollIndicators(.hidden)
    // The upper edge of the list dissolves: over the sky the cards melt into the night,
    // under the house they melt under the veil of mist.
    .mask {
      LinearGradient(stops: [
        .init(color: .clear, location: 0), .init(color: .clear, location: 1 / height),
        .init(color: .black, location: 21 / height), .init(color: .black, location: 1)
      ], startPoint: .top, endPoint: .bottom)
    }
  }

  /// "Lumenoir 0.9.8 (Beta) · пространство осознанных снов". The number is the app's own version,
  /// so the line follows every new build by itself.
  private var versionLine: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    return "\(L10n.appName) \(version) (Beta) · " + tr("пространство осознанных снов")
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      AtelierSectionTitle(text: title)
        .padding(EdgeInsets(top: 4, leading: 5, bottom: 9, trailing: 4))
      content()
    }
  }

  /// The section heading already says "Язык", so the row shows the language itself, named in itself.
  private var languageCard: some View {
    AtelierCard {
      Button { panel = .language } label: {
        SettingsRow(symbol: "globe", title: language.language.nativeName) {
          SettingsChevron()
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(tr("Язык") + ": " + language.language.nativeName)
      .accessibilityIdentifier("settings.language")
    }
    .padding(.bottom, 12)
  }

  private var signalCard: some View {
    AtelierCard {
      VStack(alignment: .leading, spacing: 0) {
        Button { panel = .sound } label: {
          SettingsRow(title: tr("Звук")) {
            SettingsValue(text: soundName)
            SettingsChevron()
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.sound")
        AtelierDivider()
        SettingsRow(title: tr("Длительность")) { durationStepper }
        SettingsHint(text: tr("Через столько секунд сигнал смолкает сам.") + " "
          + String(format: tr("От %@ до %@ секунд."),
            "\(AlarmSignalDuration.range.lowerBound)", "\(AlarmSignalDuration.range.upperBound)"))
          .padding(.top, -4)
        quickProbeButton
          .padding(.top, 4).padding(.bottom, 14)
      }
    }
    .padding(.bottom, 12)
  }

  /// Whole seconds, within the range the signal engine allows.
  private var durationStepper: some View {
    let range = AlarmSignalDuration.range
    let value: Int = model.alarmStopSeconds
    return HStack(spacing: 4) {
      PebbleButton(sign: .minus, size: 30, target: 38, label: tr("Короче")) {
        model.setAlarmStopSeconds(value - 1)
      }
      .disabled(signalsBusy || value <= range.lowerBound)
      Text("\(value) " + tr("с")).font(Atelier.ui(15)).monospacedDigit()
        .foregroundStyle(Atelier.ink)
        .frame(minWidth: 42)
        .accessibilityLabel(L10n.seconds(value))
      PebbleButton(sign: .plus, size: 30, target: 38, label: tr("Дольше")) {
        model.setAlarmStopSeconds(value + 1)
      }
      .disabled(signalsBusy || value >= range.upperBound)
    }
    .padding(.trailing, -6)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("alarm-stop-duration")
  }

  /// "Проба через 3 секунды". While its signal is waiting or sounding, the button counts for itself.
  @ViewBuilder private var quickProbeButton: some View {
    if let record = lockProbe ? nil : activeProbe {
      TimelineView(.periodic(from: .now, by: 0.25)) { context in
        probeButton(title: quickProbeTitle(record, now: context.date)).disabled(true)
      }
    } else {
      probeButton(title: tr("Проба через 3 секунды"))
        .disabled(signalsBusy || model.audio.recording || model.audio.playing || activeProbe != nil)
    }
  }

  private func probeButton(title: String) -> some View {
    Button { probeTapped(delay: 3) } label: {
      HStack(spacing: 10) {
        Image(systemName: "play.fill").font(.system(size: 10))
        Text(title).monospacedDigit()
      }
    }
    .buttonStyle(VelvetButtonStyle())
    .accessibilityIdentifier("settings.probe")
  }

  private func quickProbeTitle(_ record: SystemAlarmRecord, now: Date) -> String {
    if now < record.fireAt {
      let left = max(1, Int(record.fireAt.timeIntervalSince(now).rounded(.up)))
      return String(format: tr("Сигнал через %@…"), "\(left)")
    }
    let left = max(0, Int(record.stopAt.timeIntervalSince(now).rounded(.up)))
    return String(format: tr("Звучит · осталось %@ с"), "\(left)")
  }

  private var rainCard: some View {
    let enabled: Bool = model.nightAudio.enabled
    let status: String = model.nightAudio.status
    return AtelierCard {
      VStack(alignment: .leading, spacing: 0) {
        // The engine's own status line is shown when it says more than "off".
        SettingsRow(symbol: "cloud.rain", title: tr("Тихий дождь"),
          detail: status == "Ночной фон выключен" ? nil : L10n.show(status)) {
          Toggle(tr("Тихий дождь"), isOn: Binding(get: { enabled }, set: { rainToggled($0) }))
            .labelsHidden()
            .toggleStyle(AtelierToggleStyle())
            .disabled(model.busy)
            .accessibilityIdentifier("settings.rain")
        }
        AtelierDivider()
        VStack(alignment: .leading, spacing: 2) {
          Text(tr("Громкость дождя")).font(Atelier.ui(15)).foregroundStyle(Atelier.ink)
          AtelierSlider(value: Binding(get: { Double(model.nightAudio.volume) },
            set: { model.nightAudio.volume = Float($0) }), range: 0.08...0.6,
            label: tr("Громкость дождя"))
        }
        .padding(.top, 10).padding(.bottom, 6)
        SettingsHint(text: enabled
          ? tr("Играет между сигналами, чтобы они смолкали сами.")
          : tr("Фон выключен: сигналы сняты, без него они не смолкнут сами."))
      }
    }
    .padding(.bottom, 12)
  }

  private var checkCard: some View {
    let report: String = L10n.show(model.systemAlarms.lastStopReport)
    return AtelierCard {
      VStack(alignment: .leading, spacing: 0) {
        lockProbeRow
        if !report.isEmpty {
          SettingsHint(text: report).padding(.top, -4)
        }
        if let log = model.systemAlarms.logURL, FileManager.default.fileExists(atPath: log.path) {
          AtelierDivider()
          ShareLink(item: log) {
            SettingsRow(symbol: "square.and.arrow.up", title: tr("Журнал проверки")) {
              SettingsChevron()
            }
          }
          .buttonStyle(.plain)
        }
        AtelierDivider()
        Button { panel = .cancelAll } label: {
          SettingsRow(symbol: "circle.slash", title: tr("Отменить все сигналы"), quiet: true)
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .accessibilityIdentifier("settings.cancelAll")
      }
    }
    .padding(.bottom, 12)
  }

  /// "Проба с блокировкой": the signal comes in 60 seconds; a second tap stops the test.
  private var lockProbeRow: some View {
    let record: SystemAlarmRecord? = lockProbe ? activeProbe : nil
    return Button {
      if record != nil { stopProbe() } else { probeTapped(delay: 60) }
    } label: {
      SettingsRow(symbol: "lock.iphone", title: tr("Проба с блокировкой"),
        detail: record != nil
          ? tr("Заблокируйте iPhone. Нажмите ещё раз, чтобы остановить пробу.")
          : tr("Сигнал через 60 секунд. Заблокируйте iPhone и послушайте, смолкнет ли он сам.")) {
        if let record {
          TimelineView(.periodic(from: .now, by: 0.5)) { context in
            SettingsValue(text: L10n.clock(
              max(0, record.fireAt.timeIntervalSince(context.date).rounded(.up))))
          }
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(signalsBusy || (record == nil && activeProbe != nil))
    .accessibilityIdentifier("settings.lockProbe")
  }

  private var helpCard: some View {
    AtelierCard {
      VStack(alignment: .leading, spacing: 0) {
        Button {
          readinessWantsProbe = false
          panel = .readiness
        } label: {
          SettingsRow(symbol: "questionmark.circle", title: tr("Как настроить сигналы"),
            detail: L10n.show(model.alarmPermissionSummary)) {
            SettingsChevron()
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.howto")
        AtelierDivider()
        Button {
          Task { @MainActor in
            await model.connectHealth()
            guard model.message == nil else { return }
            ToastCenter.shared.show(model.sleep.isEmpty
              ? tr("Данных о сне пока не видно")
              : tr("История сна — в дневнике, под записями"))
          }
        } label: {
          SettingsRow(symbol: "heart", title: tr("История сна из «Здоровья»")) {
            SettingsChevron()
          }
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        AtelierDivider()
        // Third in this section: a private message to the developers in Telegram.
        Button { contactDevelopers() } label: {
          SettingsRow(symbol: "paperplane", title: tr("Контакты разработчиков")) {
            SettingsValue(text: "Telegram")
            SettingsOutbound()
          }
        }
        .buttonStyle(.plain)
        .accessibilityHint(tr("Открывает чат с @arty_brew в Telegram"))
        .accessibilityIdentifier("settings.contact")
        AtelierDivider()
        Button { model.watchLink.send() } label: {
          SettingsRow(symbol: "applewatch", title: "Apple Watch",
            detail: tr("Откройте Lumenoir на часах и разрешите сигналы. Часы хранят своё расписание и сработают, даже если iPhone заблокирован.")) {
            SettingsValue(text: tr("Обновить"))
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.watch")
        SettingsHint(text: L10n.show(model.watchLink.summary)).padding(.top, -4)
      }
    }
    .padding(.bottom, 12)
  }

  private var dataCard: some View {
    AtelierCard {
      Button { panel = .wipe } label: {
        SettingsRow(symbol: "trash", title: tr("Удалить сны и историю"), quiet: true)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("settings.wipe")
    }
    .padding(.bottom, 12)
  }

  private var remCard: some View {
    AtelierCard {
      SettingsRow(symbol: "sparkles", title: tr("REM всю ночь"),
        detail: tr("В live-режиме определяет REM-фазу сна по пульсу и дыханию со смарт-часов.")) {
        Text(tr("Скоро")).font(Atelier.ui(10.8)).tracking(0.3)
          .foregroundStyle(Atelier.dim)
          .padding(.horizontal, 9).padding(.vertical, 3)
          .background(Capsule().fill(Atelier.ink.opacity(0.078)))
      }
    }
    .padding(.bottom, 12)
  }

  // MARK: What the controls do (the same calls as in 0.9.7)

  private func rainToggled(_ on: Bool) {
    if !on {
      panel = .rainOff
    } else if model.systemAlarms.acceptedLimitations {
      Task { await model.enableNightAudio() }
    } else {
      readinessWantsProbe = false
      panel = .readiness
    }
  }

  private func probeTapped(delay: TimeInterval) {
    probeDelay = delay
    if model.systemAlarms.acceptedLimitations {
      startProbe()
    } else {
      readinessWantsProbe = true
      panel = .readiness
    }
  }

  private func startProbe() {
    lockProbe = probeDelay > 10
    let delay = probeDelay
    Task { await model.testSystemAlarm(after: delay) }
  }

  /// "Контакты разработчиков": a private chat with @arty_brew in Telegram. The Telegram app opens the chat
  /// at once; without the app the same chat opens on t.me in the browser, which offers to write there.
  /// Nothing is sent by Luma itself.
  private func contactDevelopers() {
    guard let app = URL(string: "tg://resolve?domain=arty_brew"),
          let web = URL(string: "https://t.me/arty_brew") else { return }
    let openLink: OpenURLAction = openURL
    openLink(app) { opened in
      if !opened { openLink(web) }
    }
  }

  private func stopProbe() {
    guard !signalsBusy else { return }
    Task { @MainActor in
      do {
        try await model.systemAlarms.cancelProbes()
        ToastCenter.shared.show(tr("Проба остановлена"))
      } catch { model.message = error.localizedDescription }
    }
  }

  private func panelClosed() {
    if let chosen = pendingLanguage {
      pendingLanguage = nil
      LanguageStore.shared.choose(chosen)
      return
    }
    if readyToProbe {
      readyToProbe = false
      startProbe()
    }
  }

  @ViewBuilder private func panelView(_ item: Panel) -> some View {
    switch item {
    case .language:
      LanguageSheet(current: language.language) { pendingLanguage = $0 }
    case .sound:
      SoundPickerSheet(selection: soundBinding)
    case .readiness:
      SignalReadinessView(
        continueTitle: readinessWantsProbe ? tr("Разрешить и проверить")
          : (model.systemAlarms.acceptedLimitations ? tr("Понятно") : tr("Разрешить сигналы")),
        requiresPermission: readinessWantsProbe || !model.systemAlarms.acceptedLimitations
      ) { readyToProbe = readinessWantsProbe }
    case .rainOff:
      ConfirmSheet(title: tr("Выключить ночной фон?"),
        text: tr("Вместе с ним снимется очередь сигналов: без фона они не смогут смолкать сами."),
        yes: tr("Выключить фон"), no: tr("Оставить")) {
        Task { await model.stopNightAudio() }
      }
    case .cancelAll:
      ConfirmSheet(title: tr("Отменить все сигналы?"),
        text: tr("Будильники выключатся, а сеанс непрямого метода завершится. Ночной фон продолжит играть, пока вы его не выключите."),
        yes: tr("Отменить сигналы"), no: tr("Оставить")) {
        Task { @MainActor in
          await model.stopAllSystemAlarms()
          if model.message == nil { ToastCenter.shared.show(tr("Все сигналы отменены")) }
        }
      }
    case .wipe:
      ConfirmSheet(title: tr("Удалить сны и историю?"),
        text: tr("Все записи дневника и голосовые заметки исчезнут с iPhone. Вернуть их будет нельзя."),
        yes: tr("Удалить всё")) {
        model.deleteHistory()
        if model.message == nil { ToastCenter.shared.show(tr("Дневник очищен")) }
      }
    }
  }
}

// MARK: - Parts of a row

/// One row of a settings card: an optional icon, a title with an optional small line under it,
/// and whatever stands at the right edge.
struct SettingsRow<Trailing: View>: View {
  var symbol: String?
  var title: String
  var detail: String?
  var quiet: Bool
  let trailing: Trailing

  init(symbol: String? = nil, title: String, detail: String? = nil, quiet: Bool = false,
    @ViewBuilder trailing: () -> Trailing) {
    self.symbol = symbol
    self.title = title
    self.detail = detail
    self.quiet = quiet
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: 12) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: 19, weight: .light))
          .foregroundStyle(Atelier.ink.opacity(0.851))
          .frame(width: 25, height: 25)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(Atelier.ui(15))
          .foregroundStyle(Atelier.ink.opacity(quiet ? 0.722 : 1))
          .multilineTextAlignment(.leading)
        if let detail, !detail.isEmpty {
          Text(detail).font(Atelier.ui(11.6)).lineSpacing(2)
            .foregroundStyle(Atelier.faint)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      trailing
    }
    .padding(.vertical, 7)
    .frame(minHeight: 52)
    .contentShape(Rectangle())
  }
}

extension SettingsRow where Trailing == EmptyView {
  init(symbol: String? = nil, title: String, detail: String? = nil, quiet: Bool = false) {
    self.init(symbol: symbol, title: title, detail: detail, quiet: quiet) { EmptyView() }
  }
}

struct SettingsValue: View {
  var text: String
  var body: some View {
    Text(text).font(Atelier.ui(14)).monospacedDigit()
      .foregroundStyle(Atelier.dim)
      .lineLimit(1)
  }
}

struct SettingsChevron: View {
  var body: some View {
    Image(systemName: "chevron.right").font(.system(size: 12, weight: .regular))
      .foregroundStyle(Atelier.off)
      .accessibilityHidden(true)
  }
}

/// The small arrow of a row that leads out of the app (to Telegram), in place of the chevron.
struct SettingsOutbound: View {
  var body: some View {
    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .regular))
      .foregroundStyle(Atelier.off)
      .accessibilityHidden(true)
  }
}

/// The small explanation under a row.
struct SettingsHint: View {
  var text: String
  var body: some View {
    Text(text).font(Atelier.ui(11.6)).lineSpacing(3)
      .foregroundStyle(Atelier.faint)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.bottom, 12)
  }
}

// MARK: - Sheets of this page

/// "Язык": English or Russian. Each language is named in itself.
struct LanguageSheet: View {
  let current: AppLanguage
  let choose: (AppLanguage) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    AtelierSheet(tr("Язык")) {
      VStack(spacing: 0) {
        row(.english)
        AtelierDivider()
        row(.russian)
      }
      SheetNote(text: tr("При первом запуске Lumenoir выбирает язык iPhone: русский, если система на русском, и английский во всех остальных случаях. Системные окна — будильник на заблокированном экране, запросы доступа — остаются на языке iPhone."))
        .padding(.top, 14)
    }
  }

  private func row(_ value: AppLanguage) -> some View {
    let chosen = current == value
    // The other language is also named in the language now on screen.
    let caption: String? = value == L10n.language
      ? nil : (value == .english ? "английский" : "Russian")
    return Button {
      if !chosen { choose(value) }
      dismiss()
    } label: {
      HStack(spacing: 13) {
        RoundMark(on: chosen)
        VStack(alignment: .leading, spacing: 1) {
          Text(value.nativeName).font(Atelier.ui(15)).foregroundStyle(Atelier.ink)
          if let caption {
            Text(caption).font(Atelier.ui(11.6)).foregroundStyle(Atelier.faint)
          }
        }
        Spacer(minLength: 0)
      }
      .frame(minHeight: 54)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(chosen ? [.isSelected] : [])
    .accessibilityIdentifier("language.\(value.rawValue)")
  }
}

/// A question with two answers, on the same soft sheet.
struct ConfirmSheet: View {
  let title: String
  let text: String
  let yes: String
  var no: String = tr("Отмена")
  let action: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    AtelierSheet(title) {
      SheetLead(text: text)
      Button(yes) {
        action()
        dismiss()
      }
      .buttonStyle(VelvetButtonStyle())
      Button(no) { dismiss() }
        .buttonStyle(VelvetButtonStyle(secondary: true))
        .padding(.top, 14)
    }
  }
}
