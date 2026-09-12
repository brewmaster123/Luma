import SwiftUI
import UniformTypeIdentifiers

struct SoundLibraryView: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var audio: PhoneAudio
  var record: () -> Void
  @State private var importing = false
  var body: some View {
    LumaCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("Ваши звуки").font(LumaStyle.font(18, "Medium")); Spacer()
          Image(systemName: "waveform").foregroundStyle(LumaStyle.lavender)
        }
        Text("Ваша мелодия или подсказка своим голосом.").font(LumaStyle.font(13)).foregroundStyle(LumaStyle.secondary)
        ForEach(model.state.voices) { clip in
          HStack(spacing: 8) {
            Button {
              if audio.playing && audio.playbackID == clip.id { audio.stopPlayback() }
              else { model.previewClip(clip) }
            } label: {
              Image(systemName: audio.playing && audio.playbackID == clip.id ? "stop.fill" : "play.fill")
                .frame(width: 44, height: 44).background(LumaStyle.lavender.opacity(0.08), in: Circle())
            }.accessibilityLabel("Прослушать \(clip.name)")
            VStack(alignment: .leading, spacing: 5) {
              Text(clip.name).font(LumaStyle.font(13)).lineLimit(2)
              Text("\(Int(clip.duration.rounded())) сек · \(clip.imported == true ? "Из файлов" : "Ваш голос")")
                .font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary)
            }
            Spacer(minLength: 0)
            Button { model.deleteVoice(clip.id) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
              .accessibilityLabel("Удалить \(clip.name)")
          }.disabled(model.busy || model.hasPlan || audio.recording)
        }
        HStack(spacing: 22) {
          Button(action: record) { Label("Записать", systemImage: "mic") }
          Button { importing = true } label: { Label("Из файлов", systemImage: "folder") }
          if model.busy { ProgressView() }
        }.font(LumaStyle.font(13, "Medium")).frame(minHeight: 44).disabled(model.busy || model.hasPlan || audio.recording)
        Text("Для сигнала сохраняются первые 28 секунд. Аудио остаётся на iPhone.")
          .font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary)
      }
    }.fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
      switch result {
      case .success(let url): Task { await model.importMelody(url) }
      case .failure(let error): model.message = error.localizedDescription
      }
    }
  }
}
