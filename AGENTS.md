# Контекст Luma 0.9.6 (22)

Luma — короткие ночные подсказки и дневник. Основа V.0.9.5 (21). Каждая следующая версия — новая папка V.<major>.<minor>.<patch> в C:\Users\Admin\Desktop\Luma. Не менять предыдущие папки, держать инструменты/сборки внутри новой. Сохранять com.sevchlenko.luma, подпись, данные, дневник и оригиналы записей.

## Последний запрос

Пользователь физически подтвердил: AlarmKit не заканчивается с блокировкой. Попросил Stop через 4 секунды и Watch при обоих состояниях iPhone; разрешил интернет и очень тихий фон между сигналами. Это заменяет старый запрет на фон/интернет. Фон должен быть явно видимым, управляемым и без вибрации часов.

## Архитектура

Два SwiftUI targets: iPhone и минимальный Watch companion. iPhone включает LumaCore/Platform/iPhone; Watch включает только LumaCore/Watch. Не возвращать старые workout/REM/WatchConnectivity исследовательские сервисы.

- NightAudio.swift: настоящий тихий дождь, playback+audio background mode, MPNowPlaying/Stop, ненулевая громкость, 12h лимит. При interruption короткое ограниченное выполнение; при отсутствии resume 8s — disarm. Это НЕ системный wake-up и не гарантия после force quit.
- SystemAlarmService.swift: AlarmKit, ledger schema 3, admission до/после await, prearmed Stop fireAt+4, независимость от alarmUpdates/перестроения, durable cancellation. disarmForRuntimeLoss сохраняет cadence/session.
- AlarmKitScheduler.swift: fixed occurrence с WAV; stop alerting UUID, cancel late scheduled UUID; tolerate concurrent dismissal только после проверки отсутствия ID.
- PhoneAudio.swift: не деактивирует общую сессию, пока NightAudio её использует; конфликтующие записи запрещены.
- WatchCuePlan.swift: full snapshot с revision, UUID/датами/названиями, лимит 60/12h; reject stale/replayed revisions.
- WatchCueLink.swift: updateApplicationContext + immediate message при reachability, только фактический ack.
- WatchCueStore.swift: Watch local notifications, nonrepeating, собственный WAV4, pending verification, cancellation, queued revision protection, завершение WC background tasks.
- LumaWatchApp.swift: permission/status/refresh и foreground sound delegate.
- AppModel.swift: связывает runtime, AlarmKit queue и Watch snapshot; холодный запуск без аудио disarms старую очередь.
- AlarmKitSoundBuilder/CueAudioImporter: пользовательские WAV4 с fade, исходники целы, Float32 обработка отдельно от PCM16 файла.
- AlarmPlanner/IndirectMethod/LocalStore/дневник/REM-алгоритмы сохранены.

Фреймворки: AlarmKit/ActivityKit/AppIntents на iOS26, SwiftUI/Foundation/Combine, AVFoundation, UIKit, MediaPlayer, WatchConnectivity, WatchKit, UserNotifications (Watch scheduling, iPhone legacy cleanup), CryptoKit/OSLog/HealthKit исторически. Watch не просит workout/HealthKit/микрофон.

## Важные ограничения

Нельзя выдавать длину WAV за Stop. Нельзя обещать выполнение таймера suspended процесса. Здесь runtime зависит от реально играющего аудио; AlarmKit может его прервать, поэтому требуется физический тест. Не добавлять фиктивные тренировки, приватные API, push-by-the-second или бесконечный background task.

Фон не отправляет haptics. Watch cues планируются заранее, а не sendMessage в секунду звонка. Watch local notifications не обходят Focus/permissions/locked wrist. AlarmKit mirroring может дать дополнительное системное оповещение; проверить на устройстве.

Четыре секунды — одно событие, не вся серия. Отмена текущего UUID сохраняет следующие. Полная отмена/потеря runtime передаёт пустой Watch plan. Ошибку отмены не скрывать текстом «всё снято». При force quit остановка не гарантирована; перед закрытием снять очередь в приложении.

## Проверки

Обязательный Mac прогон scripts/check-on-mac.sh и CI gates, включая Watch. Не обходить проверки ради IPA. Windows grammar/static/integrity — не swiftc/XCTest/устройство. Verified-флаги остаются false до внешней записи locked/unlocked и 30-минутной серии.

Expected preserved hashes брать из V.0.9.5, lf-text только CRLF→LF, бинарные raw. Предыдущие файлы проверять raw SHA-256. Пользователь может добавить новый IPA во время работы: отдельно фиксировать такие добавления, не менять исходный снимок и не утверждать, что агент их создал.

Читать DEVELOPMENT_STATUS/verification для фактического статуса CI. Документация Apple изучена в этой работе с разрешения пользователя; источники — Docs/ALARM_RESEARCH.md. Предыдущую гипотезу EOF считать неудачной по сообщению пользователя.
