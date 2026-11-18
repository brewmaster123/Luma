import Charts
import SwiftUI

/// The Journal: the user's dreams, a day to a card, newest first.
/// Records kept from earlier versions (night sessions with their feedback) and the sleep history
/// from Health are listed under the dreams when there are any.
struct JournalView: View {
  var isActive = true
  @EnvironmentObject private var model: AppModel
  @Environment(\.atelierViewport) private var viewport
  @State private var session: NightSession?
  @State private var dream: DreamEntry?

  private struct Day: Identifiable {
    let id: Date
    var dreams: [DreamEntry]
  }

  private var days: [Day] {
    let calendar = Calendar.current
    var result: [Day] = []
    for entry in model.archive.diary.sorted(by: { $0.date > $1.date }) {
      let day = calendar.startOfDay(for: entry.date)
      if let last = result.indices.last, result[last].id == day {
        result[last].dreams.append(entry)
      } else {
        result.append(Day(id: day, dreams: [entry]))
      }
    }
    return result
  }

  var body: some View {
    let u: CGFloat = viewport.u
    let a: CGFloat = JournalLayout.scale(viewport)
    let width: CGFloat = viewport.size.width
    let listTop: CGFloat = 284 * a
    let listHeight: CGFloat = max(160, viewport.tabBarTop - 12 * viewport.v - listTop)
    return ZStack(alignment: .topLeading) {
      JournalScene(isActive: isActive)
      header.offset(x: 25 * u, y: 89 * a)
      bar
        .frame(width: width - 45 * u, height: 44)
        .offset(x: 25 * u, y: 234 * a)
      list(height: listHeight)
        .frame(width: width - 50 * u, height: listHeight)
        .offset(x: 25 * u, y: listTop)
    }
    .frame(width: width, height: viewport.size.height, alignment: .topLeading)
    .foregroundStyle(Atelier.ink)
    .environment(\.atelierLamp, AtelierLamp.pearl(at: JournalLayout.stone(viewport)))
    .atelierSheet(item: $dream) { DreamEditor(dream: $0).environmentObject(model) }
    .atelierSheet(item: $session) { item in
      SessionFeedbackView(session: item,
        feedback: model.state.feedback.first(where: { $0.sessionID == item.id }))
        .environmentObject(model)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(tr("Дневник")).font(Atelier.display(39 * viewport.u)).tracking(0.39)
        .foregroundStyle(Atelier.ink)
        .accessibilityAddTraits(.isHeader)
      Text(tr("Сохраните то, что\nхочется запомнить."))
        .font(Atelier.uiFixed(12.8 * viewport.u)).lineSpacing(1.5)
        .foregroundStyle(Atelier.dim)
        .padding(.leading, 1)
    }
    .allowsHitTesting(false)
  }

  private var bar: some View {
    HStack(spacing: 8) {
      Text(tr("Мои сновидения")).font(Atelier.display(26.6 * viewport.u)).tracking(0.27)
        .foregroundStyle(Atelier.ink)
        .lineLimit(1).minimumScaleFactor(0.8)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
      PebbleButton(sign: .plus, size: 34 * viewport.u, label: tr("Записать сон")) {
        dream = DreamEntry()
      }
      .accessibilityIdentifier("journal.add")
    }
  }

  private func list(height: CGFloat) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        if model.archive.diary.isEmpty { emptyState }
        ForEach(days) { day in dayCard(day) }
        if !model.sleep.isEmpty { SleepHistoryCard(segments: model.sleep) }
        if !model.state.sessions.isEmpty { sessionsCard }
      }
      .padding(.top, 6)
      .padding(.bottom, 48)
    }
    .scrollIndicators(.hidden)
    // Cards dissolve at both edges of the list instead of being cut.
    .mask {
      LinearGradient(stops: [
        .init(color: .clear, location: 0), .init(color: .black, location: 12 / height),
        .init(color: .black, location: 1 - 58 / height), .init(color: .clear, location: 1)
      ], startPoint: .top, endPoint: .bottom)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 0) {
      Text(tr("Здесь пока пусто.\nОбразы, места, ощущения — можно начать с одной строки."))
        .font(Atelier.ui(13.6)).lineSpacing(5)
        .foregroundStyle(Atelier.dim)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button(tr("Записать первый сон")) { dream = DreamEntry() }
        .buttonStyle(VelvetButtonStyle())
        .padding(.top, 20)
    }
    .padding(.top, 26).padding(.horizontal, 6)
    .frame(maxWidth: .infinity)
  }

  private func dayCard(_ day: Day) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(L10n.dayTitle(day.id)).font(Atelier.display(20.5))
          .foregroundStyle(Atelier.ink)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
        if day.dreams.count > 1 {
          Text(L10n.entries(day.dreams.count)).font(Atelier.ui(10.8))
            .foregroundStyle(Atelier.dim)
            .padding(.trailing, 6)
        }
      }
      .padding(.bottom, 2)
      ForEach(Array(day.dreams.enumerated()), id: \.element.id) { item in
        if item.offset > 0 { JournalHairline() }
        dreamRow(item.element)
      }
    }
    .padding(EdgeInsets(top: 9, leading: 16, bottom: 5, trailing: 16))
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(JournalCardBackground())
  }

  private func dreamRow(_ entry: DreamEntry) -> some View {
    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let notes = entry.voiceNotes?.count ?? 0
    let title = text.isEmpty
      ? (notes > 1 ? tr("Голосовые заметки") : tr("Голосовая заметка")) : text
    return Button { dream = entry } label: {
      HStack(spacing: 10) {
        if text.isEmpty {
          Image(systemName: "waveform").font(.system(size: 14, weight: .light))
            .foregroundStyle(Atelier.dim)
        }
        Text(title).font(Atelier.ui(13.6)).lineSpacing(3)
          .foregroundStyle(Atelier.ink.opacity(0.922))
          .lineLimit(2).multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        if notes > 0 && (!text.isEmpty || notes > 1) {
          HStack(spacing: 5) {
            if !text.isEmpty {
              Image(systemName: "waveform").font(.system(size: 12, weight: .light))
            }
            Text("\(notes)").font(Atelier.ui(10.8))
          }
          .foregroundStyle(Atelier.dim)
        }
      }
      .padding(.vertical, 7)
      .frame(minHeight: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title + (notes > 0 ? ", " + tr("голосовых заметок:") + " \(notes)" : ""))
    .accessibilityIdentifier("journal.dream.\(entry.id.uuidString)")
  }

  /// Night sessions recorded by earlier versions. New ones are not created; these stay readable.
  private var sessionsCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(tr("Ночные сеансы")).font(Atelier.display(20.5)).foregroundStyle(Atelier.ink)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(model.state.sessions.enumerated()), id: \.element.id) { item in
        if item.offset > 0 { JournalHairline() }
        sessionRow(item.element)
      }
    }
    .padding(EdgeInsets(top: 9, leading: 16, bottom: 5, trailing: 16))
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(JournalCardBackground())
  }

  private func sessionRow(_ item: NightSession) -> some View {
    let status: String = item.status != .ended
      ? tr("Сеанс ещё не завершён")
      : (model.state.feedback.contains(where: { $0.sessionID == item.id })
        ? tr("Отклик сохранён") : tr("Оставить отклик · необязательно"))
    return Button { session = item } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.shortDate(item.startedAt)).font(Atelier.ui(13.6))
            .foregroundStyle(Atelier.ink.opacity(0.922))
          Text(L10n.episodes(item.episodes.count) + " · " + L10n.show(item.source.title))
            .font(Atelier.ui(10.8)).foregroundStyle(Atelier.dim)
          Text(status).font(Atelier.ui(10.8)).foregroundStyle(Atelier.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .regular))
          .foregroundStyle(Atelier.off)
      }
      .padding(.vertical, 7)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// A day's card: a little lighter than the night, its upper edge touched by the stone's light.
struct JournalCardBackground: View {
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    return shape
      .fill(LinearGradient(stops: [
        .init(color: Color(hex: 0x0F1729).opacity(0.941), location: 0),
        .init(color: Color(hex: 0x0A1222).opacity(0.933), location: 0.55),
        .init(color: Color(hex: 0x080F1E).opacity(0.933), location: 1)
      ], startPoint: .top, endPoint: .bottom))
      .overlay(shape.strokeBorder(Color(hex: 0xDFE7FF).opacity(0.078), lineWidth: 1))
      .overlay(alignment: .top) {
        Rectangle().fill(Color(hex: 0xDFE7FF).opacity(0.07)).frame(height: 1)
          .padding(.horizontal, 18).padding(.top, 1)
      }
  }
}

struct JournalHairline: View {
  var body: some View {
    Rectangle().fill(Color(hex: 0xDFE7FF).opacity(0.07)).frame(height: 1)
  }
}

/// A text area sunk into the sheet, with a pale hint while it is empty.
struct AtelierTextArea: View {
  @Binding var text: String
  var placeholder: String
  var label: String
  var height: CGFloat = 140

  var body: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $text)
        .font(Atelier.ui(15)).lineSpacing(4)
        .foregroundStyle(Atelier.ink)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .frame(height: height)
        .accessibilityLabel(label)
      if text.isEmpty {
        Text(placeholder).font(Atelier.ui(15)).foregroundStyle(Color(hex: 0x6F6D86))
          .padding(.leading, 14).padding(.top, 13)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .background(AtelierWell())
  }
}

/// "Каким был ваш сон?": text, voice notes, or both.
struct DreamEditor: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.atelierDismiss) private var dismiss
  @State var dream: DreamEntry
  @State private var deleting = false
  @State private var createdClips: [JournalVoice] = []
  @State private var startingVoice = false

  private var voiceBinding: Binding<[JournalVoice]> {
    Binding(get: { dream.voiceNotes ?? [] }, set: { dream.voiceNotes = $0 })
  }
  private var exists: Bool { model.archive.diary.contains(where: { $0.id == dream.id }) }
  private var locked: Bool { model.audio.recording || startingVoice }

  var body: some View {
    AtelierSheet(deleting ? tr("Удалить сон?") : tr("Каким был ваш сон?"), canClose: !locked) {
      if deleting {
        confirmation
      } else {
        editor
      }
    }
    .interactiveDismissDisabled(locked)
    .onDisappear {
      model.removeUnreferencedJournalAudio(createdClips)
      if dream.voiceNotes?.contains(where: { $0.id == model.audio.playbackID }) == true {
        model.audio.stopPlayback()
      }
    }
  }

  @ViewBuilder private var editor: some View {
    Text((exists ? L10n.dayTitle(dream.date) + ", " + L10n.time(dream.date) + ". " : "")
      + tr("Запишите текстом, голосом или вместе."))
      .font(Atelier.ui(13)).foregroundStyle(Color(hex: 0xA8A4B8))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 12)
    AtelierTextArea(text: $dream.text, placeholder: tr("Образы, места, ощущения…"),
      label: tr("Текст сновидения"))
    JournalVoiceComposer(audio: model.audio, clips: voiceBinding,
      created: { createdClips.append($0) }, starting: $startingVoice)
    Button(tr("Сохранить сон")) {
      if model.saveDream(dream) {
        ToastCenter.shared.show(tr("Сон сохранён"))
        dismiss()
      }
    }
    .buttonStyle(VelvetButtonStyle())
    .disabled(!dream.hasContent || locked)
    .padding(.top, 16)
    .accessibilityIdentifier("journal.save")
    if exists {
      Button(tr("Удалить сон")) { deleting = true }
        .buttonStyle(VelvetButtonStyle(secondary: true))
        .disabled(locked)
        .padding(.top, 14)
    }
  }

  @ViewBuilder private var confirmation: some View {
    SheetLead(text: tr("Текст и голосовые заметки этой записи исчезнут с iPhone."))
    Button(tr("Удалить")) {
      if model.deleteDream(id: dream.id) {
        ToastCenter.shared.show(tr("Сон удалён"))
        dismiss()
      }
    }
    .buttonStyle(VelvetButtonStyle())
    Button(tr("Отмена")) { deleting = false }
      .buttonStyle(VelvetButtonStyle(secondary: true))
      .padding(.top, 14)
  }
}

/// Feedback on a night session recorded by an earlier version.
struct SessionFeedbackView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.atelierDismiss) private var dismiss
  let session: NightSession
  @State private var feedback: SessionFeedback
  @State private var deleting = false
  @State private var createdClips: [JournalVoice] = []
  @State private var startingVoice = false

  private var voiceBinding: Binding<[JournalVoice]> {
    Binding(get: { feedback.voiceNotes ?? [] }, set: { feedback.voiceNotes = $0 })
  }
  private var locked: Bool { model.audio.recording || startingVoice }

  init(session: NightSession, feedback: SessionFeedback?) {
    self.session = session
    _feedback = State(initialValue: feedback ?? SessionFeedback(sessionID: session.id))
  }

  var body: some View {
    AtelierSheet(deleting ? tr("Удалить отклик?") : tr("Отклик о ночи"), canClose: !locked) {
      if deleting {
        confirmation
      } else {
        summary
        if session.status == .ended {
          form
        } else {
          SheetNote(text: tr("Отклик можно оставить после завершения сеанса."))
            .padding(.top, 14)
        }
      }
    }
    .interactiveDismissDisabled(locked)
    .onDisappear {
      model.removeUnreferencedJournalAudio(createdClips)
      if feedback.voiceNotes?.contains(where: { $0.id == model.audio.playbackID }) == true {
        model.audio.stopPlayback()
      }
    }
  }

  @ViewBuilder private var summary: some View {
    Text(L10n.dateTime(session.startedAt)).font(Atelier.display(22)).foregroundStyle(Atelier.ink)
    SheetNote(text: tr("Это ваш опыт, а не оценка за ночь."))
      .padding(.top, 4).padding(.bottom, 12)
    VStack(spacing: 8) {
      ForEach(session.episodes) { episode in episodeCard(episode) }
    }
  }

  private func episodeCard(_ episode: REMEpisode) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(L10n.time(episode.date)).font(Atelier.display(19)).foregroundStyle(Atelier.ink)
      Text(tr("Предполагаемый REM · экспериментальная оценка"))
        .font(Atelier.ui(11)).foregroundStyle(Atelier.faint)
      if let rate = episode.features.heartRate {
        Text(String(format: tr("Пульс: %@ уд/мин"), "\(Int(rate.rounded()))"))
          .font(Atelier.ui(13))
      }
      if let rate = episode.features.respiration {
        Text(String(format: tr("Дыхание с часов: %@/мин"), String(format: "%.1f", rate)))
          .font(Atelier.ui(13))
      }
      if let proxy = episode.features.acousticBreathing {
        Text(String(format: tr("Периодичность звука: %@/мин"), String(format: "%.1f", proxy)))
          .font(Atelier.ui(12))
      }
      if let phone = episode.phoneResult {
        Text("iPhone: " + L10n.show(phone)).font(Atelier.ui(11)).foregroundStyle(Atelier.faint)
      }
      if let watch = episode.watchResult {
        Text("Watch: " + L10n.show(watch)).font(Atelier.ui(11)).foregroundStyle(Atelier.faint)
      }
    }
    .foregroundStyle(Atelier.body)
    .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AtelierWell())
  }

  @ViewBuilder private var form: some View {
    VStack(alignment: .leading, spacing: 16) {
      answer(tr("Заметили подсказку?"), $feedback.noticed)
      answer(tr("Удалось осознать, что вы спите?"), $feedback.lucid)
      answer(tr("Подсказка разбудила вас?"), $feedback.awakened)
      if session.episodes.count > 1 {
        VStack(alignment: .leading, spacing: 4) {
          Text(tr("К какому сигналу относится отклик?")).font(Atelier.ui(14))
            .foregroundStyle(Atelier.ink)
          Picker(tr("К какому сигналу относится отклик?"), selection: $feedback.episodeID) {
            Text(tr("Не уверен(а) / в целом за ночь")).tag(Optional<UUID>.none)
            ForEach(session.episodes) { episode in
              Text(L10n.time(episode.date)).tag(Optional(episode.id))
            }
          }
          .pickerStyle(.menu)
          .tint(Atelier.ink)
        }
      }
      SheetNote(text: tr("Если время не помните, оставьте общий отклик. При нескольких сигналах он не используется для личной настройки."))
    }
    .padding(.top, 16)
    Text(tr("Что запомнилось?")).font(Atelier.ui(13)).foregroundStyle(Atelier.note)
      .padding(.top, 16).padding(.bottom, 8)
    AtelierTextArea(text: $feedback.note, placeholder: tr("Образы, места, ощущения…"),
      label: tr("Что запомнилось?"), height: 120)
    JournalVoiceComposer(audio: model.audio, clips: voiceBinding,
      created: { createdClips.append($0) }, starting: $startingVoice,
      recordingHint: tr("До 30 минут. После записи сохраните отклик."))
    Button(tr("Сохранить отклик")) {
      if model.saveFeedback(feedback) { dismiss() }
    }
    .buttonStyle(VelvetButtonStyle())
    .disabled(locked)
    .padding(.top, 16)
    if model.state.feedback.contains(where: { $0.sessionID == session.id }) {
      Button(tr("Удалить отклик")) { deleting = true }
        .buttonStyle(VelvetButtonStyle(secondary: true))
        .disabled(locked)
        .padding(.top, 14)
    }
  }

  @ViewBuilder private var confirmation: some View {
    SheetLead(text: tr("Ответы, заметка и голосовые записи этого отклика исчезнут с iPhone."))
    Button(tr("Удалить")) {
      if model.deleteFeedback(session.id) { dismiss() }
    }
    .buttonStyle(VelvetButtonStyle())
    Button(tr("Отмена")) { deleting = false }
      .buttonStyle(VelvetButtonStyle(secondary: true))
      .padding(.top, 14)
  }

  private func answer(_ title: String, _ value: Binding<FeedbackAnswer>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(Atelier.ui(14)).foregroundStyle(Atelier.ink)
      HStack(spacing: 6) {
        ForEach(FeedbackAnswer.allCases) { option in
          answerChip(option, value)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }

  private func answerChip(_ option: FeedbackAnswer, _ value: Binding<FeedbackAnswer>) -> some View {
    let chosen = value.wrappedValue == option
    return Button { value.wrappedValue = option } label: {
      Text(L10n.show(option.title)).font(Atelier.ui(13, chosen ? "Medium" : "Regular"))
        .foregroundStyle(chosen ? Atelier.ink : Atelier.faint)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(AtelierChip(chosen: chosen))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(chosen ? [.isSelected] : [])
  }
}

/// Sleep stages read from Health (after "История сна из «Здоровья»" in Settings).
struct SleepHistoryCard: View {
  let segments: [SleepSegment]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(tr("Сон по данным Apple Watch")).font(Atelier.display(20.5))
        .foregroundStyle(Atelier.ink)
        .accessibilityAddTraits(.isHeader)
      Chart(segments) { segment in
        RectangleMark(
          xStart: .value(tr("Начало"), segment.start), xEnd: .value(tr("Конец"), segment.end),
          y: .value(tr("Стадия"), L10n.show(segment.stage.title)), height: .ratio(0.75)
        )
        .foregroundStyle(segment.stage == .rem ? Atelier.ink : Atelier.off.opacity(0.55))
      }
      .frame(height: 150)
      .environment(\.locale, L10n.locale)
      Text(tr("Утренняя история Apple — тоже алгоритмическая оценка. Совпадение с ней не подтверждает точность Lumenoir."))
        .font(Atelier.ui(11)).lineSpacing(3)
        .foregroundStyle(Atelier.faint)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(EdgeInsets(top: 11, leading: 16, bottom: 12, trailing: 16))
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(JournalCardBackground())
  }
}
