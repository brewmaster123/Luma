import SwiftUI
import UIKit

/// "Звук сигнала": the Lumenoir melodies, the person's voice cues and sounds from Files.
/// Used for the common signal in Settings and for a single alarm in its editor.
/// 0.9.9: the sounds are grouped, every one can be heard before it is chosen. The Lumenoir melodies come
/// first, the default «Мелодия Lumenoir» at the top; the plain sound that was the default until then is
/// «Ровный тон», the last of the group (it is the engine's voiceID nil).
struct SoundPickerSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.atelierDismiss) private var dismiss
  @Binding var selection: UUID?
  @State private var showingLibrary = false

  var body: some View {
    let voices = model.state.voices
    let recorded = SoundShelf.recorded(voices)
    let files = SoundShelf.fromFiles(voices)
    AtelierSheet(tr("Звук сигнала")) {
      SoundGroupCaption(text: tr("Мелодии Lumenoir"), first: true)
      VStack(spacing: 0) {
        ForEach(SoundShelf.builtIns(voices)) { clip in
          choice(clip.id, name: SoundShelf.name(clip), detail: BuiltInMelodies.character(clip.id))
          AtelierDivider()
        }
        choice(nil, name: tr("Ровный тон"), detail: tr("простой ровный сигнал"))
      }
      if !recorded.isEmpty {
        SoundGroupCaption(text: tr("Ваш голос"))
        VStack(spacing: 0) {
          ForEach(Array(recorded.enumerated()), id: \.element.id) { index, clip in
            if index > 0 { AtelierDivider() }
            choice(clip.id, name: clip.name, detail: SoundText.length(clip))
          }
        }
      }
      if !files.isEmpty {
        SoundGroupCaption(text: tr("Из файлов"))
        VStack(spacing: 0) {
          ForEach(Array(files.enumerated()), id: \.element.id) { index, clip in
            if index > 0 { AtelierDivider() }
            choice(clip.id, name: clip.name, detail: SoundText.length(clip))
          }
        }
      }
      Button(tr("Добавить свой звук")) { showingLibrary = true }
        .buttonStyle(VelvetButtonStyle(secondary: true))
        .padding(.top, 18)
    }
    .task { await BuiltInMelodies.installIfNeeded(model) }
    .onChange(of: model.state.voices) { _, voices in
      // A sound deleted from the library must not stay chosen in an open editor: like the alarms themselves,
      // the choice moves to «Мелодия Lumenoir».
      if let id = selection, !voices.contains(where: { $0.id == id }) { selection = BuiltInMelodies.fallback(model) }
    }
    .onDisappear { SoundPreview.stop(model) }
    .atelierSheet(isPresented: $showingLibrary) {
      SoundLibrarySheet(audio: model.audio).environmentObject(model)
    }
  }

  private func choice(_ id: UUID?, name: String, detail: String) -> some View {
    let chosen = selection == id
    let playing = SoundPreview.isPlaying(id, model)
    return HStack(spacing: 6) {
      Button {
        SoundPreview.stop(model)
        selection = id
        dismiss()
      } label: {
        HStack(spacing: 13) {
          RoundMark(on: chosen)
          VStack(alignment: .leading, spacing: 1) {
            Text(name).font(Atelier.ui(15)).foregroundStyle(Atelier.ink).lineLimit(2)
            Text(detail).font(Atelier.ui(11.6)).foregroundStyle(Atelier.faint)
          }
          Spacer(minLength: 0)
        }
        .frame(minHeight: 54)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(chosen ? [.isSelected] : [])
      Button { SoundPreview.toggle(id, model) } label: {
        Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 10))
      }
      .buttonStyle(PebbleButtonStyle(size: 32, target: 44))
      .disabled(model.hasPlan || model.audio.recording)
      .accessibilityLabel((playing ? tr("Остановить") : tr("Прослушать")) + " " + name)
    }
  }
}

/// A small caption over a group of sounds: «Мелодии Lumenoir», «Ваш голос», «Из файлов».
struct SoundGroupCaption: View {
  var text: String
  var first = false
  var body: some View {
    Text(text).font(Atelier.ui(13)).foregroundStyle(Atelier.note)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, first ? 0 : 18).padding(.bottom, 4)
      .accessibilityAddTraits(.isHeader)
  }
}

/// Which group a sound belongs to, and the name people see.
enum SoundShelf {
  /// The installed Lumenoir melodies, in their own order.
  static func builtIns(_ voices: [VoiceClip]) -> [VoiceClip] {
    BuiltInMelodies.all.compactMap { melody in voices.first { $0.id == melody.id } }
  }
  /// Cues recorded with the microphone.
  static func recorded(_ voices: [VoiceClip]) -> [VoiceClip] {
    voices.filter { !BuiltInMelodies.isBuiltIn($0.id) && !isFromFiles($0) }
  }
  /// Sounds brought in from the Files app.
  static func fromFiles(_ voices: [VoiceClip]) -> [VoiceClip] {
    voices.filter { !BuiltInMelodies.isBuiltIn($0.id) && isFromFiles($0) }
  }
  static func isFromFiles(_ clip: VoiceClip) -> Bool {
    clip.imported == true || clip.filename.hasPrefix("luma-import-")
  }
  static func name(_ clip: VoiceClip) -> String {
    if let melody = BuiltInMelodies.melody(clip.id) { return tr(melody.name) }
    return clip.name
  }
  /// The name of the sound with this id, as Settings and the alarm editor show it.
  /// No id is the plain tone that was the default before 0.9.9.
  static func name(_ id: UUID?, voices: [VoiceClip]) -> String {
    guard let id else { return tr("Ровный тон") }
    if let melody = BuiltInMelodies.melody(id) { return tr(melody.name) }
    return voices.first(where: { $0.id == id })?.name ?? tr("Ровный тон")
  }
}

enum SoundText {
  /// "12 сек · ваш голос" / "12 s · your voice"
  static func detail(_ clip: VoiceClip) -> String {
    let origin = clip.imported == true ? tr("из файлов") : tr("ваш голос")
    return length(clip) + " · " + origin
  }

  /// "12 сек" / "12 s": inside a group, whose caption already says where the sound came from.
  static func length(_ clip: VoiceClip) -> String {
    "\(Int(clip.duration.rounded())) " + tr("сек")
  }
}

/// Listening to a sound before it is chosen. The same rules as the library's own preview:
/// nothing plays during a recording or an indirect-method session.
enum SoundPreview {
  @MainActor static func isPlaying(_ id: UUID?, _ model: AppModel) -> Bool {
    model.audio.playing && model.audio.playbackID == id
  }

  @MainActor static func toggle(_ id: UUID?, _ model: AppModel) {
    if isPlaying(id, model) { model.audio.stopPlayback(); return }
    guard !model.audio.recording, !model.hasPlan else { return }
    if let id {
      guard let clip = model.state.voices.first(where: { $0.id == id }) else { return }
      model.previewClip(clip)
    } else {
      // The plain tone («Ровный тон»): the same four-second file the signals use.
      var signal = SignalSettings()
      signal.melodySeconds = 4
      do { try model.audio.play(signal, clips: model.state.voices) }
      catch { model.message = error.localizedDescription }
    }
  }

  @MainActor static func stop(_ model: AppModel) {
    if model.audio.playing { model.audio.stopPlayback() }
  }
}

/// "Библиотека звуков": the person's own sounds — listen, rename, delete, record, add from Files.
/// Reached from the sound picker. 0.9.9: two groups with their own buttons, a working import,
/// deleting with a confirmation, renaming, and every refusal explained right here.
struct SoundLibrarySheet: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var audio: PhoneAudio
  @State private var choosingFile = false
  @State private var recording = false
  @State private var problem: String?
  @State private var confirming: VoiceClip?
  @State private var deleting = false
  @State private var renaming: UUID?
  @State private var draftName = ""
  @FocusState private var nameFocused: Bool
  /// A file is being converted. The library stays open until it is done, so its result is seen here.
  @State private var importing = false

  private var locked: Bool { model.busy || audio.recording || deleting || importing }

  var body: some View {
    AtelierSheet(confirming == nil ? tr("Библиотека звуков") : tr("Удалить звук?"),
      canClose: !deleting && !importing) {
      if let clip = confirming {
        confirmation(clip)
      } else {
        library
      }
    }
    .atelierSheet(isPresented: $recording) {
      VoiceRecorderView(audio: model.audio).environmentObject(model)
    }
    .onDisappear {
      if renaming != nil { commitRename() }
      if audio.playing { audio.stopPlayback() }
    }
  }

  // MARK: The library

  @ViewBuilder private var library: some View {
    let voices = model.state.voices
    let recorded = SoundShelf.recorded(voices)
    let files = SoundShelf.fromFiles(voices)
    SheetLead(text: tr("Своя мелодия или подсказка вашим голосом."))

    SoundGroupCaption(text: tr("Ваш голос"), first: true)
    if recorded.isEmpty {
      SheetNote(text: tr("Записей пока нет."))
    } else {
      VStack(spacing: 8) { ForEach(recorded) { clipRow($0) } }
    }
    Button { add(recordingVoice: true) } label: {
      HStack(spacing: 8) {
        Image(systemName: "mic").font(.system(size: 15, weight: .light))
        Text(tr("Записать"))
      }
    }
    .buttonStyle(VelvetButtonStyle(secondary: true, fontSize: 17))
    .disabled(locked)
    .padding(.top, 10)

    SoundGroupCaption(text: tr("Из файлов"))
    if files.isEmpty {
      SheetNote(text: tr("Файлов пока нет."))
    } else {
      VStack(spacing: 8) { ForEach(files) { clipRow($0) } }
    }
    Button { add(recordingVoice: false) } label: {
      HStack(spacing: 8) {
        Image(systemName: "folder").font(.system(size: 15, weight: .light))
        Text(tr("Добавить из файлов"))
      }
    }
    .buttonStyle(VelvetButtonStyle(secondary: true, fontSize: 17))
    .disabled(locked)
    .padding(.top, 10)
    // The Files picker is a system sheet of its own, hung on its own button,
    // away from the recorder's sheet.
    .sheet(isPresented: $choosingFile) {
      AudioFilePicker { url in
        choosingFile = false
        importPicked(url)
      }
      .ignoresSafeArea()
    }

    problemText
    if model.busy && !deleting {
      ProgressView().tint(Atelier.ink).frame(maxWidth: .infinity).padding(.top, 10)
    }
    SheetNote(text: tr("Для сигнала берутся первые 28 секунд. Звуки хранятся только на iPhone."))
      .padding(.top, 14)
  }

  @ViewBuilder private var problemText: some View {
    if let problem {
      Text(L10n.show(problem)).font(Atelier.ui(12.5)).lineSpacing(3)
        .foregroundStyle(Atelier.ink.opacity(0.9))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }
  }

  private func clipRow(_ clip: VoiceClip) -> some View {
    let playing = audio.playing && audio.playbackID == clip.id
    return HStack(spacing: 6) {
      Button {
        if playing { audio.stopPlayback() } else { model.previewClip(clip) }
      } label: {
        Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 11))
      }
      .buttonStyle(PebbleButtonStyle(size: 36, target: 42))
      .disabled(model.hasPlan || audio.recording)
      .accessibilityLabel((playing ? tr("Остановить") : tr("Прослушать")) + " " + clip.name)
      if renaming == clip.id {
        TextField("", text: $draftName, prompt: Text(tr("Название")).foregroundColor(Atelier.foot))
          .font(Atelier.ui(13.5)).foregroundStyle(Atelier.ink)
          .focused($nameFocused)
          .submitLabel(.done)
          .onSubmit { commitRename() }
          .padding(.horizontal, 10)
          .frame(minHeight: 36)
          .background(AtelierWell(radius: 12))
          .accessibilityLabel(tr("Название"))
        Button(tr("Готово")) { commitRename() }
          .font(Atelier.ui(13.5, "Medium")).foregroundStyle(Atelier.ink)
          .frame(minWidth: 52, minHeight: 42)
          .contentShape(Rectangle())
          .buttonStyle(.plain)
      } else {
        Button { startRename(clip) } label: {
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(clip.name).font(Atelier.ui(13.5)).foregroundStyle(Atelier.ink).lineLimit(1)
              Image(systemName: "pencil").font(.system(size: 10, weight: .light))
                .foregroundStyle(Atelier.faint)
                .accessibilityHidden(true)
            }
            Text(SoundText.length(clip)).font(Atelier.ui(11.5)).foregroundStyle(Atelier.faint)
              .monospacedDigit()
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel(clip.name + ", " + SoundText.length(clip))
        .accessibilityHint(tr("Переименовать"))
        VoiceBars(playing: playing)
        Button {
          commitRename()
          problem = nil
          confirming = clip
        } label: {
          Image(systemName: "trash").font(.system(size: 15, weight: .light))
            .foregroundStyle(Atelier.faint)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.4 : 1)
        .accessibilityLabel(tr("Удалить") + " " + clip.name)
      }
    }
    .padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 2))
    .background(AtelierWell(radius: 18))
  }

  // MARK: Adding

  /// Checked before anything opens, so a tap explains itself instead of doing nothing.
  private func refusal(recordingVoice: Bool) -> String? {
    if model.hasPlan {
      return tr("Пока идёт сеанс непрямого метода, звуки не добавить. Завершите сеанс на экране «Ночь».")
    }
    if recordingVoice && model.nightAudio.enabled {
      return tr("Пока играет тихий дождь, голос не записать. Выключите дождь в «Настройках», запишите подсказку и включите его снова — будильники вернутся в очередь.")
    }
    if model.busy || audio.recording { return tr("Подождите: предыдущее действие ещё не закончено.") }
    return nil
  }

  private func add(recordingVoice: Bool) {
    commitRename()
    if let refused = refusal(recordingVoice: recordingVoice) {
      problem = refused
      return
    }
    problem = nil
    if audio.playing { audio.stopPlayback() }
    if recordingVoice { recording = true } else { choosingFile = true }
  }

  private func importPicked(_ url: URL?) {
    guard let url else { return }
    problem = nil
    importing = true
    let before = Set(model.state.voices.map(\.id))
    Task { @MainActor in
      defer { importing = false }
      await model.importMelody(url)
      // The picker hands over a copy in the app's own temporary folder, never the original.
      try? FileManager.default.removeItem(at: url)
      // Success is read from the sound list itself: a message may also come from the signal queue
      // at the same moment, and that one stays for the app's own message card.
      if let added = model.state.voices.first(where: { !before.contains($0.id) }) {
        UIAccessibility.post(notification: .announcement, argument: tr("Звук добавлен"))
        // The name comes from the file; offer to change it straight away.
        startRename(added)
      } else if let text = model.message {
        problem = text
        model.message = nil
      }
    }
  }

  // MARK: Renaming

  private func startRename(_ clip: VoiceClip) {
    if renaming != nil { commitRename() }
    draftName = clip.name
    renaming = clip.id
    DispatchQueue.main.async { nameFocused = true }
  }

  private func commitRename() {
    guard let id = renaming else { return }
    renaming = nil
    nameFocused = false
    // An empty name keeps the old one.
    if !model.renameVoice(id, to: draftName), let text = model.message {
      problem = text
      model.message = nil
    }
  }

  // MARK: Deleting

  @ViewBuilder private func confirmation(_ clip: VoiceClip) -> some View {
    let alarms = model.state.alarms.filter { $0.signal.voiceID == clip.id }
    SheetLead(text: String(format: tr("«%@» исчезнет с iPhone. Вернуть его будет нельзя."), clip.name))
    if !alarms.isEmpty {
      SheetNote(text: String(format: tr("Будильники с этим звуком перейдут на мелодию Lumenoir: %@."),
        Self.times(alarms)))
        .padding(.bottom, 8)
    }
    if model.state.signal.voiceID == clip.id {
      SheetNote(text: tr("Основным звуком снова станет мелодия Lumenoir."))
        .padding(.bottom, 8)
    }
    problemText
    Button(tr("Удалить")) { Task { await delete(clip) } }
      .buttonStyle(VelvetButtonStyle())
      .disabled(deleting)
      .padding(.top, 10)
    Button(tr("Отмена")) {
      problem = nil
      confirming = nil
    }
    .buttonStyle(VelvetButtonStyle(secondary: true))
    .disabled(deleting)
    .padding(.top, 14)
  }

  /// "07:00, 08:30": the times of these alarms, earliest first.
  private static func times(_ alarms: [LumaAlarm]) -> String {
    alarms
      .sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
      .map { String(format: "%02d:%02d", $0.hour, $0.minute) }
      .joined(separator: ", ")
  }

  /// Alarms that use the sound move to the Lumenoir melody through the editor's own save,
  /// then the sound is deleted. The Settings sound falls back to the melody by itself.
  @MainActor private func delete(_ clip: VoiceClip) async {
    guard !deleting else { return }
    problem = nil
    if model.hasPlan {
      problem = tr("Пока идёт сеанс непрямого метода, звуки не удалить. Завершите сеанс на экране «Ночь».")
      return
    }
    deleting = true
    defer { deleting = false }
    if audio.playing { audio.stopPlayback() }
    // Saving an enabled alarm prepares its signals, and that switches the quiet rain on if it was off.
    // Deleting a sound is no reason for the rain: if it was off, it goes off again at the end, through
    // the same call as the Settings switch. Without the rain those alarms were not in the queue anyway.
    let rainWasOn = model.nightAudio.enabled
    let wasCommon = model.state.signal.voiceID == clip.id
    // Alarms with this sound move to «Мелодия Lumenoir» (the plain tone only if the melody is missing).
    let fallback = BuiltInMelodies.fallback(model)
    let users = model.state.alarms.filter { $0.signal.voiceID == clip.id }
    // Enabled alarms first: only they can be refused, because their signals are prepared again.
    let order = users.filter(\.enabled) + users.filter { !$0.enabled }
    var moved: [LumaAlarm] = []
    for original in order {
      guard var alarm = model.state.alarms.first(where: { $0.id == original.id }) else { continue }
      alarm.signal.voiceID = fallback
      guard await model.saveAlarm(alarm) else {
        var text = L10n.show(model.message ?? "Не удалось сохранить будильник.")
        model.message = nil
        if original.enabled {
          // An enabled alarm is saved with its signals prepared, which needs the quiet rain and permission
          // for alarms. Say which alarm stopped the deletion and the simple way round it.
          text = String(format: tr("Будильник %@ не удалось перевести на мелодию Lumenoir."), Self.times([original]))
            + "\n" + text + "\n"
            + tr("Выключите этот будильник — после этого звук можно будет удалить.")
        }
        if !moved.isEmpty {
          // Say which alarms already use the melody, so nothing changes without a word.
          text += "\n" + String(format: tr("Будильники %@ уже переведены на мелодию Lumenoir."), Self.times(moved))
        }
        problem = text
        await settleRain(wasOn: rainWasOn)
        return
      }
      moved.append(alarm)
    }
    model.deleteVoice(clip.id)
    // The engine falls back to the plain tone for the common sound; the default is now the Lumenoir melody.
    if wasCommon, model.state.signal.voiceID == nil, let fallback,
      !model.state.voices.contains(where: { $0.id == clip.id }) {
      var signal = model.state.signal
      signal.voiceID = fallback
      model.updateSignal(signal)
    }
    await settleRain(wasOn: rainWasOn)
    // Success is read from the sound list itself; a message of the signal queue that arrives meanwhile
    // stays for the app's own message card.
    if model.state.voices.contains(where: { $0.id == clip.id }) {
      problem = L10n.show(model.message ?? "Не удалось удалить звук.")
      model.message = nil
      return
    }
    confirming = nil
  }

  /// Puts the quiet rain back the way it was before the deletion, if saving an alarm switched it on.
  /// Afterwards the alarms on Night show «пока вне очереди» once more instead of looking armed.
  @MainActor private func settleRain(wasOn: Bool) async {
    guard !wasOn, model.nightAudio.enabled, !model.hasPlan else { return }
    await model.stopNightAudio()
    await model.refreshQueueAfterRainOff()
  }
}

/// "Подсказка голосом": records up to 28 seconds for use as a signal.
struct VoiceRecorderView: View {
  @ObservedObject var audio: PhoneAudio
  @Environment(\.atelierDismiss) private var dismiss
  @State private var name = tr("Моя подсказка")
  @State private var error: String?
  @State private var starting = false

  var body: some View {
    AtelierSheet(tr("Подсказка голосом"), canClose: !(audio.recording || starting)) {
      Text(tr("Название")).font(Atelier.ui(13)).foregroundStyle(Atelier.note)
        .padding(.bottom, 8)
      TextField("", text: $name, prompt: Text(tr("Название")).foregroundColor(Atelier.foot))
        .font(Atelier.ui(15)).foregroundStyle(Atelier.ink)
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(AtelierWell())
        .disabled(audio.recording || starting)
        .accessibilityLabel(tr("Название"))
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(L10n.clock(audio.recordSeconds)).font(Atelier.numbers(44)).foregroundStyle(Atelier.ink)
        Text("/ 00:28").font(Atelier.numbers(22)).foregroundStyle(Atelier.dim)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 14).padding(.bottom, 8)
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(Color(hex: 0x070A16))
          Capsule().fill(Atelier.ink.opacity(0.6))
            .frame(width: geometry.size.width * CGFloat(min(1, max(0, audio.recordSeconds / 28))))
        }
      }
      .frame(height: 6)
      .accessibilityHidden(true)
      SheetNote(text: tr("Запись завершится сама через 28 секунд."), centered: true)
        .padding(.top, 10)
      if let error {
        Text(L10n.show(error)).font(Atelier.ui(12.5)).foregroundStyle(Atelier.ink.opacity(0.9))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.top, 8)
      }
      Button(audio.recording ? tr("Завершить запись") : tr("Начать запись")) {
        if audio.recording {
          audio.finishRecording()
        } else {
          starting = true
          Task {
            do { try await audio.startRecording(name: name) } catch {
              self.error = error.localizedDescription
            }
            starting = false
          }
        }
      }
      .buttonStyle(VelvetButtonStyle())
      .disabled(starting)
      .padding(.top, 16)
    }
    .interactiveDismissDisabled(audio.recording || starting)
    .onChange(of: audio.recording) { was, isNow in
      if was && !isNow { dismiss() }
    }
  }
}
