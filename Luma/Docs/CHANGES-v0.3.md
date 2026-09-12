> Исторический документ предыдущей версии. Актуальная реализация и проверки: README.md, CHANGES-v0.4.2.md и VALIDATION.md.

# Обновление 0.3

Новые функции: системный AlarmKit для iOS 26; прямой короткий звук REM в фоне; импорт мелодии; локальный голос в дневнике и откликах; переключатель вибрации iPhone; сортировка ближайших срабатываний; справка REM; интервалы 3/8/12.

Предыдущая рабочая правка watchOS сохранена. Старые будильники сохраняют короткий тип до явного переключения. Старые сны остаются совместимыми.

Для GitHub требуется обновить и Luma, и workflow. Часть файлов ниже — документы и изображения макета.

Изменённые / добавленные файлы:

- `.github/workflows/ios-build.yml`
- `Luma/Config/Base.xcconfig`
- `Luma/Config/iOS-Info.plist`
- `Luma/Design/Interface-preview.html`
- `Luma/Design/Luma-design.png`
- `Luma/Design/Luma-night.png`
- `Luma/Design/Luma-rem-help.png`
- `Luma/Design/Luma-voice-diary.png`
- `Luma/Docs/DESIGN.md`
- `Luma/Docs/DEVICE-TESTS.md`
- `Luma/Docs/NIGHT-UI-UPDATE.md`
- `Luma/Docs/TECHNICAL-NOTES.md`
- `Luma/Docs/VALIDATION.md`
- `Luma/Docs/audio-preview-checks.json`
- `Luma/Docs/core-tests.log`
- `Luma/Docs/ios-build.yml`
- `Luma/Docs/static-checks.json`
- `Luma/Luma.xcodeproj/project.pbxproj`
- `Luma/README.md`
- `Luma/Resources/PrivacyInfo.xcprivacy`
- `Luma/Sources/LumaCore/LumaV2.swift`
- `Luma/Sources/LumaCore/Models.swift`
- `Luma/Sources/Platform/AppError.swift`
- `Luma/Sources/Platform/AppModel.swift`
- `Luma/Sources/Platform/LocalStore.swift`
- `Luma/Sources/Platform/PhoneAudio.swift`
- `Luma/Sources/iPhone/AlarmEditor.swift`
- `Luma/Sources/iPhone/CueAudioImporter.swift`
- `Luma/Sources/iPhone/JournalView.swift`
- `Luma/Sources/iPhone/JournalVoiceComposer.swift`
- `Luma/Sources/iPhone/PhoneAlarmService.swift`
- `Luma/Sources/iPhone/PhoneRootView.swift`
- `Luma/Sources/iPhone/SettingsView.swift`
- `Luma/Sources/iPhone/SoundLibraryView.swift`
- `Luma/Tests/LumaCoreTests/AudioAndAlarmTests.swift`
- `Luma/scripts/check-audio-on-mac.sh`
- `Luma/scripts/check-audio-on-mac.swift`
- `Luma/scripts/check-preview.cjs`
- `Luma/scripts/check-static.py`
- `Luma/scripts/project-graph.json`
- `Luma-Night-UPDATE.md`
- `Luma-START.md`
