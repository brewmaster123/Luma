import SwiftUI
import UniformTypeIdentifiers

struct LumaExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var details = false
    @State private var export = false
    @State private var document = LumaExportDocument()
    @State private var confirmDelete = false
    private var selectedTime: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: model.settings.startHour, minute: model.settings.startMinute,
                                  second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.changeSettings { $0.startHour = parts.hour ?? 5; $0.startMinute = parts.minute ?? 30 }
        })
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("В вашем ритме.").font(.system(.largeTitle, design: .serif))
                    Text("Только то, что нужно для спокойной ночи.").font(.subheadline).foregroundStyle(LumaStyle.secondary)
                    if model.hasPlan {
                        Label("Для изменений сначала отмените текущую сессию.", systemImage: "lock")
                            .font(.subheadline).foregroundStyle(LumaStyle.amber)
                    }
                    modeCard
                    timingCard
                    signalCard
                    dataCard
                    Button { details = true } label: {
                        HStack { Label("Возможности этой версии", systemImage: "info.circle"); Spacer(); Image(systemName: "chevron.right") }
                            .font(.subheadline).padding(.vertical, 10)
                    }
                    Text("Luma 0.1 · проверочная сборка\nТочность определения REM ещё не измерена.")
                        .font(.caption).foregroundStyle(LumaStyle.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                }.padding(24)
            }.lumaScreen().navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $details) { CapabilitiesView() }
                .fileExporter(isPresented: $export, document: document, contentType: .json, defaultFilename: "Luma-diary") { result in
                    if case .failure(let error) = result { model.message = error.localizedDescription }
                }
                .confirmationDialog("Удалить дневник и журнал сигналов на этом устройстве?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Удалить записи", role: .destructive) { model.deleteHistory() }
                }
        }
    }
    private var modeCard: some View {
        LumaCard {
            VStack(alignment: .leading, spacing: 16) {
                SmallLabel(text: "КОГДА ПОДАТЬ СИГНАЛ")
                ForEach(NightMode.allCases) { mode in
                    Button { model.changeSettings { $0.mode = mode } } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: model.settings.mode == mode ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(LumaStyle.lavender).font(.title3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(mode.title).font(.headline)
                                Text(mode == .scheduled ? "В выбранное вами время" : "Экспериментально. В фоне сигнал может быть пропущен.")
                                    .font(.caption).foregroundStyle(LumaStyle.secondary)
                            }
                            Spacer(minLength: 0)
                        }.frame(minHeight: 50)
                    }.buttonStyle(.plain).disabled(model.hasPlan)
                        .accessibilityAddTraits(model.settings.mode == mode ? .isSelected : [])
                }
            }
        }
    }
    private var timingCard: some View {
        LumaCard {
            VStack(alignment: .leading, spacing: 12) {
                SmallLabel(text: "ВРЕМЯ")
                DatePicker(model.settings.mode == .scheduled ? "Подать сигнал в" : "Начало окна", selection: selectedTime,
                           displayedComponents: .hourAndMinute).disabled(model.hasPlan)
                if model.settings.mode == .experimentalREM {
                    Picker("Продолжительность окна", selection: Binding(get: { model.settings.windowMinutes }, set: { v in model.changeSettings { $0.windowMinutes = v } })) {
                        Text("20 минут").tag(20); Text("30 минут").tag(30)
                    }.disabled(model.hasPlan)
                }
                Text("Одна сессия, без ежедневного повтора. Если время уже прошло, планируется следующий день.")
                    .font(.caption).foregroundStyle(LumaStyle.secondary)
            }
        }
    }
    private var signalCard: some View {
        LumaCard {
            VStack(alignment: .leading, spacing: 16) {
                SmallLabel(text: "СИГНАЛ НА ЗАПЯСТЬЕ")
                CountSelector(selected: model.settings.cueCount, disabled: model.hasPlan) { count in model.changeSettings { $0.cueCount = count } }
                Picker("Пауза между сигналами", selection: Binding(get: { model.settings.intervalSeconds }, set: { v in model.changeSettings { $0.intervalSeconds = v } })) {
                    Text("8 секунд").tag(8); Text("12 секунд").tag(12); Text("20 секунд").tag(20)
                }.disabled(model.hasPlan)
                Divider().overlay(LumaStyle.border)
                Button { Task { await model.preview() } } label: {
                    Label("Попробовать на часах", systemImage: "waveform")
                        .font(.subheadline).frame(minHeight: 44)
                }
                Text("Для пробы откройте Luma на часах. В пробе пауза 1,5 секунды. Ночью подаются отдельные уведомления с выбранной паузой; рисунок постукиваний задаёт watchOS. Каждый сигнал заканчивается сам.")
                    .font(.caption).foregroundStyle(LumaStyle.secondary)
            }
        }
    }
    private var dataCard: some View {
        LumaCard {
            VStack(alignment: .leading, spacing: 12) {
                SmallLabel(text: "ВАШИ ДАННЫЕ")
                Button { Task { await model.connectHealth() } } label: { Label("Доступ к данным «Здоровья»", systemImage: "heart") }.frame(minHeight: 44)
                Button {
                    do { document = LumaExportDocument(data: try model.exportData()); export = true }
                    catch { model.message = error.localizedDescription }
                } label: { Label("Экспортировать записи", systemImage: "square.and.arrow.up") }.frame(minHeight: 44)
                Button(role: .destructive) { confirmDelete = true } label: { Label("Удалить записи", systemImage: "trash") }.frame(minHeight: 44)
                Text("Данные «Здоровья» доступны только для чтения. Записи дневника не передаются на сервер и не синхронизируются между устройствами.")
                    .font(.caption).foregroundStyle(LumaStyle.secondary)
            }.font(.subheadline)
        }
    }
}
