import SwiftUI

struct JournalVoiceComposer: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var audio: PhoneAudio
  @Binding var clips: [JournalVoice]
  var created: (JournalVoice) -> Void
  @Binding var starting: Bool
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Голосовая заметка", systemImage: "waveform").font(LumaStyle.font(14, "Medium"))
        Spacer()
        Text("Только на iPhone").font(LumaStyle.font(10)).foregroundStyle(LumaStyle.secondary)
      }
      ForEach(clips) { clip in
        HStack(spacing: 6) {
          Button {
            do {
              if audio.playing && audio.playbackID == clip.id { audio.stopPlayback() }
              else { try audio.playJournal(clip) }
            } catch { self.error = error.localizedDescription }
          } label: {
            Image(systemName: audio.playing && audio.playbackID == clip.id ? "stop.fill" : "play.fill")
              .font(.system(size: 13)).frame(width: 44, height: 44)
              .background(LumaStyle.lavender.opacity(0.08), in: Circle())
          }.accessibilityLabel("Прослушать голосовую запись").disabled(audio.recording || starting)
          VStack(alignment: .leading, spacing: 5) {
            Text(clip.createdAt.formatted(date: .omitted, time: .shortened)).font(LumaStyle.font(13, "Medium"))
            Text(Self.duration(audio.playbackID == clip.id ? audio.playbackSeconds : clip.duration))
              .font(LumaStyle.font(11)).monospacedDigit().foregroundStyle(LumaStyle.secondary)
          }
          Spacer(minLength: 4)
          HStack(spacing: 3) {
            ForEach(Array([8.0, 15, 10, 21, 13, 18, 8].enumerated()), id: \.offset) { bar in
              Capsule().fill(LumaStyle.lavender.opacity(0.45)).frame(width: 2, height: bar.element)
            }
          }.accessibilityHidden(true)
          Button {
            if audio.playbackID == clip.id { audio.stopPlayback() }
            clips.removeAll { $0.id == clip.id }
          } label: { Image(systemName: "trash").font(.system(size: 13)).frame(width: 44, height: 44) }
            .accessibilityLabel("Удалить голосовую запись").disabled(audio.recording || starting)
        }.padding(10).background(LumaStyle.inset, in: RoundedRectangle(cornerRadius: 18))
      }
      Button {
        if audio.recordingJournal { audio.finishRecording() }
        else {
          starting = true; error = nil
          Task {
            defer { starting = false }
            do {
              guard !model.hasPlan else { throw AppError.message("Завершите ночной сеанс перед записью заметки.") }
              try await audio.startJournalRecording { clip in clips.append(clip); created(clip) }
            } catch { self.error = error.localizedDescription }
          }
        }
      } label: {
        HStack(spacing: 9) {
          Image(systemName: audio.recordingJournal ? "stop.circle.fill" : "mic")
          Text(audio.recordingJournal ? "Завершить запись" : "Записать голосом")
          Spacer()
          if audio.recordingJournal { Text(Self.duration(audio.recordSeconds)).monospacedDigit() }
          else if starting { ProgressView().tint(LumaStyle.lavender) }
        }.font(LumaStyle.font(13, "Medium")).frame(minHeight: 44).contentShape(Rectangle())
      }.buttonStyle(.plain).foregroundStyle(audio.recordingJournal ? LumaStyle.amber : LumaStyle.lavender)
        .disabled(starting || (audio.recording && !audio.recordingJournal))
      if audio.recordingJournal {
        Text("До 30 минут. Сохраните заметку после записи.").font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary)
      }
      if let error { Text(error).font(LumaStyle.font(12)).foregroundStyle(LumaStyle.amber) }
    }
  }
  static func duration(_ seconds: Double) -> String {
    let value = max(0, Int(seconds)); return String(format: "%02d:%02d", value / 60, value % 60)
  }
}
