import SwiftUI

struct PhoneRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            NightView(openSettings: { tab = 2 }).tag(0)
                .tabItem { Label("Ночь", systemImage: "moon") }
            JournalView().tag(1).tabItem { Label("Дневник", systemImage: "book.closed") }
            SettingsView().tag(2).tabItem { Label("Настройки", systemImage: "slider.horizontal.3") }
        }
        .tint(LumaStyle.lavender)
        .toolbarBackground(LumaStyle.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .sheet(isPresented: $model.showOnboarding) { IntroductionView() }
        .alert("Luma", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("Понятно", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

struct NightView: View {
    @EnvironmentObject private var model: AppModel
    let openSettings: () -> Void
    @State private var showDetails = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("LUMA").font(.headline).tracking(5)
                            Text("Осознанные сновидения").font(.caption).foregroundStyle(LumaStyle.secondary)
                        }
                        Spacer()
                        Button { model.message = model.watchReachable
                            ? "Часы на связи. Для пробы откройте на них Luma."
                            : "Откройте Luma на Apple Watch. Статус сессии появится после ответа часов." } label: {
                            Image(systemName: "applewatch").font(.title3).frame(width: 46, height: 46)
                                .background(LumaStyle.surface, in: Circle())
                                .overlay(alignment: .bottomTrailing) {
                                    Circle().fill(model.watchReachable ? LumaStyle.mint : LumaStyle.secondary)
                                        .frame(width: 8, height: 8).padding(3)
                                }
                        }.accessibilityLabel(model.watchReachable ? "Apple Watch на связи" : "Подключить Apple Watch")
                    }

                    VStack(spacing: 0) {
                        MoonOrb().frame(height: 135)
                        Text("Тихий сигнал.\nБлиже к сновидению.")
                            .font(.system(.largeTitle, design: .serif)).multilineTextAlignment(.center)
                        Text("Ничего не нужно выключать.")
                            .font(.subheadline).foregroundStyle(LumaStyle.secondary).padding(.top, 12)
                    }.padding(.bottom, 4)

                    LumaCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                SmallLabel(text: model.settings.mode == .scheduled ? "ВРЕМЯ СИГНАЛА" : "ОКНО ДЛЯ СИГНАЛА")
                                Spacer()
                                Button("Изменить", action: openSettings).font(.caption)
                            }
                            if let plan = model.planForDisplay {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(plan.windowStart, format: .dateTime.hour().minute())
                                        .font(.system(.largeTitle, design: .rounded).weight(.medium)).monospacedDigit()
                                    if model.settings.mode == .experimentalREM {
                                        Text("—").foregroundStyle(LumaStyle.secondary)
                                        Text(plan.windowEnd, format: .dateTime.hour().minute())
                                            .font(.title2).monospacedDigit()
                                    }
                                    Spacer(minLength: 0)
                                }
                                Text(plan.windowStart, format: .dateTime.day().month(.wide))
                                    .font(.caption).foregroundStyle(LumaStyle.secondary)
                            }
                            Divider().overlay(LumaStyle.border)
                            Label(model.settings.mode == .scheduled ? "По выбранному времени" : "Оценка REM · эксперимент",
                                  systemImage: model.settings.mode == .scheduled ? "clock" : "waveform.path")
                                .font(.subheadline).foregroundStyle(LumaStyle.secondary)
                        }
                    }

                    LumaCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack { SmallLabel(text: "КОРОТКИХ СИГНАЛОВ"); Spacer(); Image(systemName: "waveform").foregroundStyle(LumaStyle.lavender) }
                            CountSelector(selected: model.settings.cueCount, disabled: model.hasPlan) { count in
                                model.changeSettings { $0.cueCount = count }
                            }
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle").foregroundStyle(LumaStyle.mint)
                                Text("Каждый сигнал заканчивается сам. Рисунок вибрации задают часы.")
                                    .foregroundStyle(LumaStyle.secondary)
                            }.font(.caption)
                        }
                    }

                }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 28)
            }.lumaScreen().toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    sessionActions.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 8)
                        .background(LumaStyle.background)
                }
                .sheet(isPresented: $showDetails) { CapabilitiesView() }
        }
    }
    private var sessionActions: some View {
        VStack(spacing: 14) {
            if model.hasPlan {
                Label(model.stateTitle, systemImage: model.archive.planState == .armed ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    .font(.subheadline).foregroundStyle(model.archive.planState == .armed ? LumaStyle.mint : LumaStyle.amber)
                    .multilineTextAlignment(.center)
                if model.archive.planState == .awaitingWatch {
                    Button("Повторить синхронизацию") { model.retrySync() }.font(.subheadline)
                }
                Button("Отменить сессию") { model.cancel() }
                    .buttonStyle(.bordered).disabled(model.isCancelling)
            } else {
                Button { Task { await model.arm() } } label: {
                    HStack { if model.busy { ProgressView() }; Text("Подготовить на часах"); Image(systemName: "arrow.right") }
                }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
            }
            if model.settings.mode == .experimentalREM {
                Text("В фоне данных может не хватить.\nREM-сигнал в этой версии не гарантирован.")
                    .font(.caption).foregroundStyle(LumaStyle.amber).multilineTextAlignment(.center)
            }
            Button("Как это работает") { showDetails = true }
                .font(.subheadline).foregroundStyle(LumaStyle.secondary).padding(.vertical, 6)
        }
    }
}

struct IntroductionView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MoonOrb().frame(height: 160)
                    Text("Немного тишины.\nНемного осознанности.")
                        .font(.system(.largeTitle, design: .serif))
                    introRow("applewatch", "Подсказка на запястье", "Выберите 1, 2, 3 или 5 коротких сигналов. Они заканчиваются сами.")
                    introRow("moon", "Ваше время", "Начните с сигналов по времени. Режим оценки REM пока экспериментальный.")
                    introRow("lock", "Личное остаётся личным", "Без регистрации и аналитики. Записи хранятся на ваших устройствах.")
                    Button { Task { await model.connectHealth() } } label: {
                        Text(model.busy ? "Подключаем…" : "Подключить данные сна")
                    }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
                    Button("Продолжить без данных сна") { model.completeIntroduction() }
                        .font(.subheadline).frame(maxWidth: .infinity)
                    Text("Затем откройте Luma на часах и разрешите сигналы. Для тихой вибрации нужен бесшумный режим часов; разрешите Luma в фокусировании «Сон».")
                        .font(.caption).foregroundStyle(LumaStyle.secondary)
                }.padding(24)
            }.lumaScreen().navigationTitle("Добро пожаловать").navigationBarTitleDisplayMode(.inline)
        }.preferredColorScheme(.dark).tint(LumaStyle.lavender)
    }
    private func introRow(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(LumaStyle.lavender).frame(width: 32)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(LumaStyle.secondary)
            }
        }
    }
}

struct CapabilitiesView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Подсказка,\nкоторая затихает сама.").font(.system(.largeTitle, design: .serif))
                    explanation("По времени", "Часы планируют выбранное число коротких уведомлений. Они не повторяются бесконечно. Включите бесшумный режим, чтобы получать тактильные сигналы без звука.")
                    explanation("По признакам REM", "Проверяются изменения пульса и движения. Это предварительные правила без доказанной точности. Непрерывное наблюдение ночью в этой сборке не обеспечивается: в фоне свежих данных часто недостаточно. Тогда Luma пропускает сигнал.")
                    explanation("О числе вибраций", "Настройка 1–5 задаёт количество уведомлений в серии. Рисунок и число физических постукиваний внутри уведомления определяет watchOS. В пробе при открытом приложении подаётся выбранное число одиночных тактильных команд.")
                    explanation("Утренний график", "Стадии загружаются из записей Apple Watch после сна. Совпадение с ними — сравнение алгоритмов, а не независимое подтверждение REM. Отправленный запрос ещё не означает, что вибрация была доставлена или замечена.")
                    explanation("Сессия на одну ночь", "Настройка действует на одну сессию, без ежедневного повтора. Отмена с телефона завершена только после ответа часов. При отсутствии связи отмените сессию на самих часах.")
                }.padding(24)
            }.lumaScreen().navigationTitle("Как работает Luma").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(LumaStyle.lavender)
    }
    private func explanation(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline).foregroundStyle(LumaStyle.lavender)
            Text(text).font(.body).foregroundStyle(LumaStyle.secondary)
        }
    }
}
