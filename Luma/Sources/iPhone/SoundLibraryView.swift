import SwiftUI
import UniformTypeIdentifiers

/// "Звук сигнала": the Luma melody or one of the user's own sounds.
/// Used for the common signal in Settings and for a single alarm in its editor.
struct SoundPickerSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Binding var selection: UUID?
  @State private var showingLibrary = false

  var body: some View {
    AtelierSheet(tr("Звук сигнала")) {
      VStack(spacing: 0) {
        choice(nil, name: tr("Мелодия Lumenoir"), detail: tr("стандартная"))
        ForEach(model.state.voices) { clip in
          AtelierDivider()
          choice(clip.id, name: clip.name, detail: SoundText.detail(clip))
        }
      }
      Button(tr("Добавить свой звук")) { showingLibrary = true }
        .buttonStyle(VelvetButtonStyle(secondary: true))
        .padding(.top, 14)
    }
    .sheet(isPresented: $showingLibrary) {
      SoundLibrarySheet(audio: model.audio).environmentObject(model)
    }
  }

  private func choice(_ id: UUID?, name: String, detail: String) -> some View {
    let chosen = selection == id
    return Button {
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
  }
}

enum SoundText {
  /// "12 сек · ваш голос" / "12 s · your voice"
  static func detail(_ clip: VoiceClip) -> String {
    let seconds = Int(clip.duration.rounded())
    let origin = clip.imported == true ? tr("из файлов") : tr("ваш голос")
    return "\(seconds) " + tr("сек") + " · " + origin
  }
}

/// "Библиотека звуков": the user's own sounds — listen, delete, record, import.
/// Reached from the sound picker; the functions are those of 0.9.7.
struct SoundLibrarySheet: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var audio: PhoneAudio
  @State private var importing = false
  @State private var recording = false

  private var locked: Bool { model.busy || model.hasPlan || audio.recording }

  var body: some View {
    AtelierSheet(tr("Библиотека звуков")) {
      SheetLead(text: tr("Своя мелодия или подсказка вашим голосом."))
      if model.state.voices.isEmpty {
        SheetNote(text: tr("Своих звуков пока нет."))
      }
      VStack(spacing: 8) {
        ForEach(model.state.voices) { clip in clipRow(clip) }
      }
      .disabled(locked)
      HStack(spacing: 10) {
        Button { recording = true } label: {
          HStack(spacing: 8) {
            Image(systemName: "mic").font(.system(size: 15, weight: .light))
            Text(tr("Записать"))
          }
        }
        .buttonStyle(VelvetButtonStyle(secondary: true, fontSize: 17))
        Button { importing = true } label: {
          HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 15, weight: .light))
            Text(tr("Из файлов"))
          }
        }
        .buttonStyle(VelvetButtonStyle(secondary: true, fontSize: 17))
      }
      .disabled(locked)
      .padding(.top, 10)
      if model.busy {
        ProgressView().tint(Atelier.ink).frame(maxWidth: .infinity).padding(.top, 10)
      }
      SheetNote(text: tr("Для сигнала берутся первые 28 секунд. Звуки хранятся только на iPhone."))
        .padding(.top, 14)
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
      switch result {
      case .success(let url): Task { await model.importMelody(url) }
      case .failure(let error): model.message = error.localizedDescription
      }
    }
    .sheet(isPresented: $recording) {
      VoiceRecorderView(audio: model.audio).environmentObject(model)
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
      .accessibilityLabel((playing ? tr("Остановить") : tr("Прослушать")) + " " + clip.name)
      VStack(alignment: .leading, spacing: 2) {
        Text(clip.name).font(Atelier.ui(13.5)).foregroundStyle(Atelier.ink).lineLimit(1)
        Text(SoundText.detail(clip)).font(Atelier.ui(11.5)).foregroundStyle(Atelier.faint)
          .monospacedDigit()
      }
      Spacer(minLength: 4)
      VoiceBars(playing: playing)
      Button { model.deleteVoice(clip.id) } label: {
        Image(systemName: "trash").font(.system(size: 15, weight: .light))
          .foregroundStyle(Atelier.faint)
          .frame(width: 40, height: 40)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(tr("Удалить") + " " + clip.name)
    }
    .padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 2))
    .background(AtelierWell(radius: 18))
  }
}

/// "Подсказка голосом": records up to 28 seconds for use as a signal.
struct VoiceRecorderView: View {
  @ObservedObject var audio: PhoneAudio
  @Environment(\.dismiss) private var dismiss
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
