# Источники и решение 0.9.6

Проверены 12 ноября 2026 с разрешения пользователя; ниже выводы из API, а не протокол испытания устройства.

[AlarmConfiguration](https://developer.apple.com/documentation/alarmkit/alarmmanager/alarmconfiguration) задаёт расписание, presentation, intents и звук. Публичного параметра четырёхсекундного ringing duration в рассмотренной конфигурации нет. Это вывод по перечисленным API. [AlertSound](https://developer.apple.com/documentation/activitykit/alertconfiguration/alertsound) выбирает default/named звук, не loop policy. Гипотеза WAV EOF не прошла по сообщению пользователя.

[FAQ инженера Apple](https://developer.apple.com/forums/thread/797158): запланированные alarms переживают завершение процесса; stopIntent относится к остановке пользователем. Поэтому таймер внутри приостановленного приложения не решает задачу.

[AVAudioSession.playback](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback): background audio mode позволяет продолжать настоящее воспроизведение после блокировки. [Interruption](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification): прерывание деактивирует сессию; уведомление после suspension может быть задержано. Вывод: реальный ночной звук — источник runtime с условиями, не гарантия бессмертного процесса.

[Extending background execution](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time): ограниченное время завершения работы, не планировщик запуска в будущем. NightAudio использует короткое окно только для окончания Stop при interruption, не на всю ночь.

[Watch notification forwarding](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding): локальное оповещение, созданное watchOS-приложением, предназначено самим Watch; обычный iOS-origin notification маршрутизируется по активности устройств. Поэтому в 0.9.6 Watch получают расписание заранее и ставят собственные cues.

[WatchConnectivity sample](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity) описывает передачу full context и завершение фоновых WC tasks. Подтверждение принятой очереди учитывается отдельно от посылки сообщения. Передача не является точным alarm-time wake-up.

Не выбран WKExtendedRuntimeSession как способ бесконечной 30-минутной серии: [runtime sessions](https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions) требуют foreground для планирования и допускают только одну scheduled session. Не возвращены фиктивные workout/keep-alive датчики.

Результирующий код: genuine sleep audio + absolute Stop deadlines + bounded interruption completion + independent Watch local queue. Остались условия runtime/permissions/Focus и необходимость физического теста.
