# Контекст разработки Luma 0.9.5 (21)

Luma — короткие ночные подсказки и дневник для практики осознанных сновидений. REM-оценка не является медицинской диагностикой.

## Правила версий

Каждая новая версия — отдельная папка V.<major>.<minor>.<patch> в C:\Users\Admin\Desktop\Luma. Основа этой версии — V.0.9.4, build 20. Не менять, не удалять, не переносить и не нормализовать старые папки. Рабочие/временные файлы держать внутри новой версии. Обновлять README, CHANGELOG, DEVELOPMENT_STATUS и AGENTS. Проверять номера в конфигурации, workflow и IPA, не выбирать основу по mtime.

Сохранять com.sevchlenko.luma, Automatic Signing, entitlements и пользовательские данные. Ключи подписи в исходники не добавлять. В этой рабочей папке нет Git-репозитория; удалённый CI не запускался.

## Прямой запрос пользователя

В обоих режимах использовать AlarmKit с мелодией не длиннее четырёх секунд, проверить естественное окончание файла. Пользователь прямо запретил обращаться к документации Apple в этой работе; внешние источники не открывались. Это заменяет прежнее правило 0.9.4 о доставке уведомлениями. Локальные уведомления оставлены только для удаления старой очереди.

Не выдавать гипотезу WAV EOF за доказанное устранение системного повторения. Не придумывать loopCount/playOnce/soundDuration API. Нельзя представлять Task.sleep, Timer, alarmUpdates или background task как гарантию вызова Stop в suspended приложении. Не добавлять постоянную тишину, фиктивную тренировку и keep-alive.

## Архитектура

Один iPhone SwiftUI target, deployment iOS 17. Сигналы AlarmKit доступны только на iOS 26+. Swift Package LumaCore содержит модели, планировщик и XCTest.

- LumaV2.swift: модели, AlarmPlanner, исторические delivery raw values.
- iPhoneOnlyMigration.swift: перевод сохранённого состояния на AlarmKit без изменения дат, ID, голосов и дневника.
- SystemAlarmPlan.swift: ledger schema 3, очередь, interval session, миграция schema 1/2, отмены.
- FiniteCuePolicy.swift: историческое имя, сейчас префикс luma.alarmkit., WAV имена, новая версия согласия. capacity(otherPending:) — только исторический helper уведомлений, в AlarmKit delivery не применяется.
- WaveCueInspector.swift: RIFF/PCM проверка 88 200 frames, 22 050 mono16, запрет smpl/plst. Это проверка файла, не системного проигрывателя.
- AppModel.swift: умный будильник, непрямой метод, проба и обновление очереди.
- AlarmScheduling.swift: подставляемый протокол.
- AlarmKitScheduler.swift: реальные schedule/fixed/.named(WAV), разрешение, ID/state snapshots, Stop/Cancel. Нет fallback на уведомление.
- SystemAlarmService.swift: reservation до await, проверка admission, durable cancellation, защита generation/inFlight, orphan cleanup, миграция и исполнение резервного Stop.
- NotificationService.swift: только отмена legacy luma.* уведомлений. LumaNotificationDelegate удалён.
- LegacyAlarmCleanup.swift: очищать прежние schemas; текущая schema 3 должна переживать обычный запуск.
- AlarmKitSoundBuilder.swift: отдельный WAV кэш v4 с затуханием; оригиналы сохраняются.
- CueAudioImporter.swift: Float32 non-interleaved обработка отдельно от PCM16 файла.
- CueDiagnostics.swift: OSLog + ограниченный JSONL alarmkit-wave-events.jsonl. Наблюдение alerting не является callback фактического акустического старта/EOF.
- LocalStore, PhoneAudio, HealthService, дневник и REM-алгоритмы сохранены.
- REM всю ночь, собственный Watch target и WCSession отсутствовали в основе; не возвращать попутно.

Frameworks: Foundation, SwiftUI, Combine, AlarmKit, ActivityKit, AppIntents, AVFoundation/AVFAudio, AudioToolbox, UserNotifications (cleanup), CryptoKit, OSLog, HealthKit. Swift imports используют autolinking; AlarmKit gated по OS и canImport.

## Звук и миграция

База Resources/luma-alarm-4.wav — копия проверенной четырёхсекундной мелодии. Пользовательские записи: Library/Sounds/luma-ak4-<hash>.wav, PCM16 mono 22 050, ровно 88 200 отсчётов, fade, короткие записи дополняются тишиной. Оригиналы/дневник не обрезать. После reboot нужен первый unlock для защищённых файлов.

Ledger остаётся в Application Support/LumaAlarmKit/alarms.json. Schema 1 — прежний AlarmKit, 2 — уведомления, 3 — новый WAV AlarmKit. Мигрировать только после подтверждения отмены обоих старых транспортов. Сохранять начало/интервал сеанса и будущие keys, не проигрывать прошлое. Не чистить schema 3 как legacy при каждом запуске.

Четыре секунды относятся к одному событию. До 60 событий/12 часов вперёд; 30 минут между началами сохранены. Лимит 60 — Luma, не заявленный лимит OS. Stop текущего UUID не должен отменять следующий интервал. Никаких заявлений о бесконечном фоне после исчерпания очереди.

## Проверка и честный статус

Windows проверки не заменяют swiftc, XCTest, AVFoundation или физический iPhone. Обязательные Mac проверки — scripts/check-on-mac.sh; в CI все gates сохранены. Манифест preserved-sources.json берёт ожидаемые хеши из 0.9.4: lf-text нормализует только CRLF → LF, бинарные ресурсы raw. Намеренные изменения перечислять отдельно. Предыдущие папки проверяются raw SHA-256.

После каждого изменения выполнять только относящиеся к нему проверки. Для устройства использовать Docs/DEVICE_TESTS.md: locked/suspended, force quit, три получасовых события, следующий сигнал, Silent/Focus, Watch, restart, upgrade. Измерять внешним устройством, продолжать запись после EOF для поиска повторов.

alarmKitWaveEOFDeviceVerified и alarmKitAutomaticStopVerified остаются false до протокола физического теста. Не считать наличие ID или возврат Stop акустическим доказательством. Отзыв тестировщика: карточка пришла на часы, мелодия не прозвучала; содержимое аудио не публиковать. После восстановления контекста читать DEVELOPMENT_STATUS и verification.json.
