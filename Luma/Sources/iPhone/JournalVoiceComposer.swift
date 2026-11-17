import SwiftUI

/// The voice notes of one journal entry: listen, delete, record a new one.
/// What is done with the recordings is unchanged from 0.9.7; only the look is new.
struct JournalVoiceComposer: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var audio: PhoneAudio
  @Binding var clips: [JournalVoice]
  var created: (JournalVoice) -> Void
  @Binding var starting: Bool
  /// Shown while a recording is running.
  var recordingHint: String = tr("До 30 минут. После записи сохраните сон.")
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text(tr("Голосовые заметки")).font(Atelier.ui(13)).foregroundStyle(Color(hex: 0xA8A4B8))
        Spacer(minLength: 10)
        Text(tr("остаются на iPhone")).font(Atelier.ui(11)).foregroundStyle(Atelier.foot)
      }
      .padding(.top, 16).padding(.bottom, 9)
      ForEach(clips) { clip in
        clipRow(clip).padding(.bottom, 8)
      }
      recordRow
      if audio.recordingJournal {
        Text(recordingHint).font(Atelier.ui(12)).foregroundStyle(Atelier.faint)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .padding(.top, 8)
      }
      if let error {
        Text(L10n.show(error)).font(Atelier.ui(12.5)).foregroundStyle(Atelier.ink.opacity(0.851))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity)
          .padding(.top, 8)
      }
    }
  }

  private func clipRow(_ clip: JournalVoice) -> some View {
    let playing = audio.playing && audio.playbackID == clip.id
    let seconds = audio.playbackID == clip.id ? audio.playbackSeconds : clip.duration
    return HStack(spacing: 6) {
      Button {
        do {
          if playing { audio.stopPlayback() } else { try audio.playJournal(clip) }
        } catch { self.error = error.localizedDescription }
      } label: {
        Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 11))
      }
      .buttonStyle(PebbleButtonStyle(size: 36, target: 42))
      .accessibilityLabel(playing ? tr("Остановить") : tr("Прослушать голосовую заметку"))
      .disabled(audio.recording || starting)
      VStack(alignment: .leading, spacing: 2) {
        Text(String(format: tr("Заметка в %@"), L10n.time(clip.createdAt)))
          .font(Atelier.ui(13.5)).foregroundStyle(Atelier.ink).lineLimit(1)
        Text(L10n.clock(seconds)).font(Atelier.ui(11.5)).monospacedDigit()
          .foregroundStyle(Atelier.faint)
      }
      Spacer(minLength: 4)
      VoiceBars(playing: playing)
      Button {
        if audio.playbackID == clip.id { audio.stopPlayback() }
        clips.removeAll { $0.id == clip.id }
      } label: {
        Image(systemName: "trash").font(.system(size: 15, weight: .light))
          .foregroundStyle(Atelier.faint)
          .frame(width: 40, height: 40)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(tr("Удалить голосовую заметку"))
      .disabled(audio.recording || starting)
    }
    .padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 2))
    .background(AtelierWell(radius: 18))
  }

  /// Recording is one more row of the voice notes, not another large button.
  private var recordRow: some View {
    Button {
      if audio.recordingJournal { audio.finishRecording() }
      else {
        starting = true; error = nil
        Task {
          defer { starting = false }
          do {
            guard !model.hasPlan else {
              throw AppError.message(
                tr("Сначала завершите ночной сеанс: пока он идёт, запись недоступна."))
            }
            try await audio.startJournalRecording { clip in clips.append(clip); created(clip) }
          } catch { self.error = error.localizedDescription }
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: audio.recordingJournal ? "stop.fill" : "mic")
          .font(.system(size: audio.recordingJournal ? 11 : 15, weight: .light))
          .foregroundStyle(Atelier.ink.opacity(0.94))
          .frame(width: 36, height: 36)
          .background(PebbleFace())
          .frame(width: 42, height: 42)
        Text(audio.recordingJournal ? tr("Завершить запись") : tr("Записать голосом"))
          .font(Atelier.ui(14.5)).foregroundStyle(Atelier.ink)
        Spacer(minLength: 6)
        if audio.recordingJournal {
          Text(L10n.clock(audio.recordSeconds)).font(Atelier.ui(13.5)).monospacedDigit()
            .foregroundStyle(Atelier.ink)
        } else if starting {
          ProgressView().tint(Atelier.ink)
        }
      }
      .padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 16))
      .background(AtelierWell(radius: 18))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(starting || (audio.recording && !audio.recordingJournal))
  }
}
