# 0.9.6 (22)

Основа — 0.9.5 (21). Предыдущие версии не редактировались.

- Вместо гипотезы EOF: настоящий тихий ночной аудиорежим и заранее поставленные сроки AlarmKit Stop для обоих режимов.
- Stop не ждёт alarmUpdates и не блокируется подготовкой очереди. Late scheduled occurrences отменяются.
- Ограниченный Stop window при interruption; при длительной потере аудио — durable disarm с сохранением cadence.
- Пользовательские Start/Stop, громкость дождя, управление с экрана блокировки. Фон не создаёт Watch haptics.
- Минимальный Watch companion: отдельные local cues, полное расписание с revision/ack, защита от старого snapshot, отмена и foreground sound.
- iPhone/Watch target, embed/scheme/resources и обязательная Watch CI-сборка.
- Три core регрессии Watch plan и три native queue сценария runtime/deadline.
- Данные, 30-минутные интервалы, темы и оригиналы аудио сохранены.

Физическое самозавершение этой версии пока не подтверждено; force quit и прерывания iOS не покрываются гарантией.
