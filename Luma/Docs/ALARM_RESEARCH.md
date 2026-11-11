# AlarmKit и конечные сигналы — решение 0.9.2

Проверено по публичным материалам Apple 11 ноября 2026. Это исследование API и кода, не физический тест.

## Причина дефекта в основе

В 0.9.1 `AlarmKitSoundBuilder` уже создавал CAF 22 050 Гц / 88 200 frames. Умный будильник и непрямой метод использовали один `SystemAlarmService`.

После постановки `armDeadline` ожидал `record.stopAt` через `Task.sleep` и вызывал `refresh`. Остановка выполнялась в `handle` через `AlarmManager.stop(id:)`, с резервной отменой. Опрос, `alarmUpdates` и короткое UIKit background time имели ту же зависимость от исполняющегося процесса. Сам `stopIntent` предназначался для ручного закрытия.

Это подтверждает архитектурный дефект: системный alarm продолжает жить независимо от процесса, а автоматический Stop зависел от него. Если iOS приостановила Luma, код не выполняется к четырёхсекундному сроку. Конкретный запуск на устройстве здесь не воспроизведён; без device logs нельзя приписать все наблюдавшиеся случаи единственной причине.

## Ответы на вопросы об API

| Вопрос | Вывод |
|---|---|
| Повторяет ли AlarmKit короткий файл? | В изученной документации не найден контракт «играть ровно один раз и завершить alarm». Универсальное поведение повтора на всех iOS не установлено. Старый код и пользовательский тест уже показывают, что короткий файл не решает задачу. |
| Можно запретить повтор звука? | В публичных AlarmConfiguration и AlertSound.named не найден параметр loop count / play once / alert duration. Отсутствие такого контракта не доказывает одинаковый внутренний цикл на всех версиях. |
| Завершает ли EOF активный alarm? | Такой переход состояния не документирован. Его нельзя выводить из длины файла. |
| Можно программно вызвать stop/cancel? | Да, при выполнении приложения и наличии доступа к API. Stop удаляет одноразовый alarm, повторный переводит к следующему расписанию. |
| Выполнится ли вызов в suspended процессе? | Обычное ожидание не обеспечивает возобновление. Короткое background time предназначено закончить текущую работу, а не ожидать следующий получасовой интервал. |
| Есть системное автозавершение через 4 секунды? | В изученных публичных конфигурациях не найдено. Countdown/timer duration задаёт ожидание **до** сигнала; postAlert — отсчёт после snooze/repeat, не длительность звонка. |

Проверенные первичные источники:

- [AlarmKit](https://developer.apple.com/documentation/alarmkit): системные alarms/timers.
- [AlarmManager](https://developer.apple.com/documentation/alarmkit/alarmmanager): schedule, stop, cancel, состояние и async updates.
- [stop(id:)](https://developer.apple.com/documentation/alarmkit/alarmmanager/stop(id:)) и [cancel(id:)](https://developer.apple.com/documentation/alarmkit/alarmmanager/cancel(id:)): явное управление жизненным циклом.
- [AlarmConfiguration](https://developer.apple.com/documentation/alarmkit/alarmmanager/alarmconfiguration): публичные входные параметры.
- [AlarmAttributes metadata](https://developer.apple.com/documentation/alarmkit/alarmattributes/metadata) и [пример настройки представления](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit): UI/metadata/tint, без ограничения длительности аудио.
- [postAlert](https://developer.apple.com/documentation/alarmkit/alarm/countdownduration-swift.struct/postalert): snooze countdown.
- [AlertSound.named](https://developer.apple.com/documentation/activitykit/alertconfiguration/alertsound/named(_:)): файл в main bundle или Library/Sounds. Этот API не предоставляет управление повтором.
- [WWDC25: AlarmKit](https://developer.apple.com/videos/play/wwdc2025/230/): lifecycle, действия кнопок, countdown, custom sound и Watch.
- [UIKit background execution](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time): процесс вскоре приостанавливается, доступное продолжение ограничено.
- [AlarmKit FAQ, Apple DTS](https://developer.apple.com/forums/thread/797158): alarms сохраняются после force quit/reboot; stopIntent связан с dismiss; пересечения alarms не имеют гарантированного победителя.

Форматы для AlarmKit: AlertSound.named документирует расположение, но не даёт в этой странице полного отдельного контракта длительности/кодеков. Прежний CAF нельзя считать правильным механизмом завершения только потому, что он валиден как PCM. В 0.9.2 новый звук не передаётся AlarmKit.

## Выбор A / B / C

- **A отклонён:** четырёхсекундный файл уже был в основе; системное окончание alarm при EOF и отсутствие повтора не доказаны.
- **B отклонён:** stop/cancel поддерживаются, но гарантированного четырёхсекундного запуска кода в suspended процессе не найдено.
- **C реализован:** заранее поставленные локальные уведомления, каждое с обычным конечным custom sound и `repeats: false`. Процесс приложения не нужен для команды прекращения звука.

[UNNotificationSound](https://developer.apple.com/documentation/usernotifications/unnotificationsound) документирует custom sound из bundle/Library/Sounds, Linear PCM/IMA4/µLaw/aLaw в WAV/AIFF/CAF и ограничение менее 30 секунд. Используется PCM16 mono, 22 050 Гц, 4,0 секунды. Отсутствие app-driven Stop устраняет исходную зависимость; фактическое звучание/окончание на устройстве остаётся предметом измерения.

[Планирование локальных уведомлений](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app) передаёт доставку системе, в том числе без работающего приложения. [Руководство по обработке](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/SchedulingandHandlingLocalNotifications.html) объясняет автоматическое снятие неповторяющегося запроса и foreground delegate. Не используется background push или notification service extension для «пробуждения на четыре секунды».

## Пределы альтернативы

По [Apple Support](https://support.apple.com/en-ie/108274) беззвучный режим подавляет звук, Focus нужно настроить, а уведомления обычно приходят на один из iPhone/Watch. В 0.9.2 нет Critical Alerts entitlement и не запрашивается его привилегия. Права на обычные уведомления не доказывают текущую слышимость.

[AVAudioSession playback](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback) позволяет продолжать настоящее воспроизведение в фоне. Это не обоснование точного старта нового звука через полчаса из уже suspended приложения. Постоянная тишина, искусственный workout, BGTaskScheduler и таймер как гарантированное пробуждение не используются.

Ни один изученный вариант не даёт здесь универсальной гарантии четырёх слышимых секунд на iPhone при любом Silent/Focus/Watch/force-quit состоянии. Новый путь ограничивает один системный звук конечным ресурсом, сохраняет расписание серии и честно сообщает условия доставки.

## Force quit

Ожидается, что уже принятые локальные запросы обслуживаются системой без Luma. Не ожидается пополнение конечной очереди или callback начала/конца звука в завершённом процессе. Force quit отдельно проверяется на физическом iPhone; он не считается проверенным по документации. После установки обновления старые AlarmKit alarms не исчезают до первого успешного запуска миграции.
