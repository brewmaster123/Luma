import Foundation

/// 0.9.9: three Lumenoir melodies next to the standard one.
///
/// Every signal is a four-second cue that AlarmKit repeats until the signal's own stop (3–20 s),
/// so each melody is a complete four-second phrase: it is over by about two seconds, has no new note
/// near the first and second second (where a 5- or 6-second stop cuts), and has faded away well before
/// the four seconds end. Files: Resources/lumenoir-melody-*.wav, 22,050 Hz mono, exactly 4.000 s.
///
/// They are installed as ordinary library sounds with fixed ids (Library/Sounds/luma-import-<id>.caf
/// plus an entry in the sound list), so the unchanged signal engine prepares and plays them exactly
/// like an imported melody, and older versions still read the sound list. They are not shown in the
/// library and cannot be deleted; installing one never changes the chosen sound.
struct BuiltInMelody: Identifiable {
  /// Fixed forever: alarms remember a sound by this id.
  let id: UUID
  /// The file in the app bundle, without ".wav".
  let resource: String
  /// The Russian name; shown through tr().
  let name: String
  /// A few words on its character under the name; shown through tr().
  let character: String
}

enum BuiltInMelodies {
  /// «Мелодия Lumenoir»: the app's own signature and, since 0.9.9, its default sound (the user, 18 Nov 2026,
  /// evening: «шедевр», true to the app's mood, beautiful alike at 3 and at 20 seconds). The plain three-tone
  /// sound that was the default until then stays in the list as «Ровный тон» (the engine's voiceID nil).
  static let lumenoirID = UUID(uuidString: "4C554D45-4E4F-4952-A001-000000000000")!

  static let all: [BuiltInMelody] = [
    BuiltInMelody(id: lumenoirID,
      resource: "lumenoir-melody-signature",
      name: "Мелодия Lumenoir", character: "стандартная"),
    BuiltInMelody(id: UUID(uuidString: "4C554D45-4E4F-4952-A001-000000000001")!,
      resource: "lumenoir-melody-moonlit-lullaby",
      name: "Лунная колыбельная", character: "музыкальная шкатулка, тихо и нежно"),
    BuiltInMelody(id: UUID(uuidString: "4C554D45-4E4F-4952-A001-000000000002")!,
      resource: "lumenoir-melody-fireflies",
      name: "Светлячки", character: "звонкие капли, легко и светло"),
    BuiltInMelody(id: UUID(uuidString: "4C554D45-4E4F-4952-A001-000000000003")!,
      resource: "lumenoir-melody-first-light",
      name: "Первый луч", character: "тёплые колокола, ясно и спокойно")
  ]

  static func melody(_ id: UUID?) -> BuiltInMelody? {
    guard let id else { return nil }
    return all.first { $0.id == id }
  }

  static func isBuiltIn(_ id: UUID) -> Bool { melody(id) != nil }

  static func character(_ id: UUID) -> String {
    melody(id).map { tr($0.character) } ?? ""
  }

  @MainActor private static var installing = false

  /// Puts the melodies into the sound library. Idempotent: a missing file is restored, a missing
  /// entry is added, anything already in place is left alone. Runs at launch and whenever the sound
  /// picker opens; it waits while the app model is busy, so it never races a save of an alarm.
  /// Only file work: the audio session and the quiet rain are not touched.
  @MainActor static func installIfNeeded(_ model: AppModel) async {
    guard !installing else { return }
    installing = true
    defer { installing = false }
    guard let directory = try? model.audio.soundsDirectory() else { return }
    for melody in all {
      guard !model.busy else { return }
      let filename = "luma-import-\(melody.id.uuidString).caf"
      let target = directory.appendingPathComponent(filename)
      let listed = model.state.voices.contains { $0.id == melody.id }
      let present = FileManager.default.fileExists(atPath: target.path)
      if listed && present { continue }
      guard let source = Bundle.main.url(forResource: melody.resource, withExtension: "wav") else { continue }
      do {
        var duration = 4.0
        if !present {
          // The same conversion as a sound added from Files; for these files it is a plain copy.
          let clip = try await Task.detached(priority: .utility) {
            try CueAudioImporter.convert(source: source, directory: directory)
          }.value
          let temporary = directory.appendingPathComponent(clip.filename)
          defer { try? FileManager.default.removeItem(at: temporary) }
          if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
          }
          try FileManager.default.moveItem(at: temporary, to: target)
          duration = clip.duration
        }
        if !listed {
          var entry = VoiceClip(id: melody.id, name: melody.name, filename: filename, duration: duration)
          entry.imported = true
          entry.sourceDuration = duration
          model.addBuiltInSound(entry)
        }
      } catch {
        continue   // tried again at the next launch or when the picker opens
      }
    }
    adoptAsDefault(model, directory: directory)
  }

  /// Remembers that «Мелодия Lumenoir» has once been made the default sound.
  static let defaultAdoptedKey = "com.sevchlenko.luma.lumenoirMelodyDefault.v1"

  /// Once, as soon as the melody is in place: if the common sound is still the plain tone (voiceID nil, the old
  /// default), it becomes «Мелодия Lumenoir»; new alarms, the indirect method and the tests then use it.
  /// After that the person's own choice is never changed again, and existing alarms keep the sound each has.
  @MainActor private static func adoptAsDefault(_ model: AppModel, directory: URL) {
    let defaults = UserDefaults.standard
    let file = directory.appendingPathComponent("luma-import-\(lumenoirID.uuidString).caf")
    guard !defaults.bool(forKey: defaultAdoptedKey), !model.busy,
      model.state.voices.contains(where: { $0.id == lumenoirID }),
      FileManager.default.fileExists(atPath: file.path) else { return }
    if model.state.signal.voiceID == nil {
      var signal = model.state.signal
      signal.voiceID = lumenoirID
      model.updateSignal(signal)
      guard model.state.signal.voiceID == lumenoirID else { return }   // not saved: tried again later
    }
    defaults.set(true, forKey: defaultAdoptedKey)
  }

  /// Where sounds go when theirs is deleted: the Lumenoir melody, or the plain tone if the melody is missing.
  @MainActor static func fallback(_ model: AppModel) -> UUID? {
    model.state.voices.contains(where: { $0.id == lumenoirID }) ? lumenoirID : nil
  }
}
