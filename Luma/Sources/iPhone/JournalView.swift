import SwiftUI
import Charts

struct JournalView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: DreamEntry?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Сохраните то,\nчто приснилось.").font(.system(.largeTitle, design: .serif))
                    Text("Иногда всё начинается с одного воспоминания.")
                        .font(.subheadline).foregroundStyle(LumaStyle.secondary)
                    Button { editing = DreamEntry() } label: {
                        Label("Записать сновидение", systemImage: "plus")
                    }.buttonStyle(PrimaryButtonStyle())
                    SleepHistoryCard(segments: model.sleep)
                    if !model.archive.records.isEmpty { cueHistory }
                    SmallLabel(text: "ВАШИ СНОВИДЕНИЯ")
                    if model.archive.diary.isEmpty {
                        LumaCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "book.closed").font(.title2).foregroundStyle(LumaStyle.lavender)
                                Text("Здесь будет ваша история").font(.headline)
                                Text("После пробуждения запишите образ, ощущение или несколько слов. Все записи остаются на этом устройстве.")
                                    .font(.subheadline).foregroundStyle(LumaStyle.secondary)
                            }
                        }
                    } else {
                        ForEach(model.archive.diary) { entry in
                            Button { editing = entry } label: {
                                LumaCard {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(entry.date, format: .dateTime.day().month(.wide))
                                            .font(.caption).foregroundStyle(LumaStyle.secondary)
                                        Text(entry.text.isEmpty ? "Впечатление о ночи" : entry.text)
                                            .font(.body).lineLimit(4).multilineTextAlignment(.leading)
                                        if entry.reportedLucidity {
                                            Label("Отмечен осознанный сон", systemImage: "sparkles")
                                                .font(.caption).foregroundStyle(LumaStyle.lavender)
                                        }
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(24)
            }.lumaScreen().navigationTitle("Дневник").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.refreshSleep() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Обновить данные сна")
                } }
                .refreshable { await model.refreshSleep() }
                .sheet(item: $editing) { entry in DreamEditor(entry: entry) }
        }
    }
    private var cueHistory: some View {
        LumaCard {
            VStack(alignment: .leading, spacing: 16) {
                SmallLabel(text: "ПОСЛЕДНИЕ СИГНАЛЫ")
                ForEach(Array(model.archive.records.sorted { $0.scheduledAt > $1.scheduledAt }.prefix(5))) { record in
                    HStack(alignment: .top) {
                        Image(systemName: record.status == .deliveryObserved ? "checkmark.circle" : "circle.dotted")
                            .foregroundStyle(record.status == .deliveryObserved ? LumaStyle.mint : LumaStyle.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.scheduledAt, format: .dateTime.day().month(.abbreviated).hour().minute()).font(.subheadline)
                            Text(statusText(record)).font(.caption).foregroundStyle(LumaStyle.secondary)
                        }
                    }
                }
                Text("Подтверждение относится к уведомлению. Оно не доказывает, что вибрация была замечена.")
                    .font(.caption).foregroundStyle(LumaStyle.secondary)
            }
        }
    }
    private func statusText(_ record: CueRecord) -> String {
        switch record.status {
        case .deliveryObserved:
            switch SleepComparison().compare(record: record, segments: model.sleep) {
            case .matchesREM: return "Доставлено · совпало с REM на графике Apple"
            case .anotherStage: return "Доставлено · другая стадия на графике Apple"
            case .unknown: return "Доставка уведомления подтверждена"
            }
        case .reserved: return "Запрос зарезервирован; доставка неизвестна"
        case .scheduled: return record.scheduledAt > Date() ? "Запланировано на часах" : "Доставка не подтверждена"
        case .failed: return "Не удалось запланировать"
        case .cancelled: return "Отменено"
        }
    }
}

struct SleepHistoryCard: View {
    let segments: [SleepSegment]
    private var recent: [SleepSegment] {
        guard let last = segments.map(\.end).max() else { return [] }
        return segments.filter { $0.start >= last.addingTimeInterval(-12 * 3600) }
    }
    var body: some View {
        LumaCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack { SmallLabel(text: "ПОСЛЕДНИЙ СОН"); Spacer(); Image(systemName: "applewatch").foregroundStyle(LumaStyle.secondary) }
                if recent.isEmpty {
                    Text("График появится после сна").font(.headline)
                    Text("Разрешите доступ к данным сна. Записи Apple Watch могут появиться с задержкой.")
                        .font(.subheadline).foregroundStyle(LumaStyle.secondary)
                } else {
                    Chart(recent) { segment in
                        RectangleMark(xStart: .value("Начало", segment.start), xEnd: .value("Конец", segment.end),
                                      y: .value("Стадия", segment.stage.title), height: .ratio(0.6))
                            .foregroundStyle(color(segment.stage)).cornerRadius(3)
                            .accessibilityLabel("\(segment.stage.title), \(segment.start.formatted(date: .omitted, time: .shortened))")
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                    .frame(height: 150)
                    Text("По данным Apple Watch. Это утренняя оценка стадий, а не независимая проверка точности Luma.")
                        .font(.caption).foregroundStyle(LumaStyle.secondary)
                }
            }
        }
    }
    private func color(_ stage: SleepStage) -> Color {
        switch stage {
        case .rem: return LumaStyle.lavender
        case .deep: return Color(hex: 0x7778C3)
        case .core: return Color(hex: 0x829AB8)
        case .awake: return LumaStyle.amber
        case .unspecified: return LumaStyle.secondary
        }
    }
}

struct DreamEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var entry: DreamEntry
    @State private var confirmDelete = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Дата", selection: $entry.date, displayedComponents: .date)
                    TextEditor(text: $entry.text).frame(minHeight: 220)
                        .accessibilityLabel("Что вам приснилось")
                } header: { Text("Что вам приснилось?") } footer: { Text("Образы, места, люди, ощущения. Можно всего пару слов.") }
                Section("Впечатления") {
                    Toggle("Я заметил(а) сигнал", isOn: $entry.noticedCue)
                    Toggle("Я осознавал(а), что сплю", isOn: $entry.reportedLucidity)
                }
                if model.archive.diary.contains(where: { $0.id == entry.id }) {
                    Section { Button("Удалить запись", role: .destructive) { confirmDelete = true } }
                }
            }.scrollContentBackground(.hidden).lumaScreen()
                .navigationTitle("Сновидение").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") { model.saveDream(entry); dismiss() }
                            .disabled(entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !entry.noticedCue && !entry.reportedLucidity)
                    }
                }
                .confirmationDialog("Удалить эту запись?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Удалить", role: .destructive) { model.deleteDream(id: entry.id); dismiss() }
                }
        }.preferredColorScheme(.dark).tint(LumaStyle.lavender)
    }
}
