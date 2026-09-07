import SwiftUI
import Combine

struct WatchRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var settings = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let violet = Color(red: 0.78, green: 0.72, blue: 0.96)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "moon.stars").font(.system(size: 34, weight: .light))
                        .foregroundStyle(violet).padding(.top, 8).accessibilityHidden(true)
                    Text("LUMA").font(.caption.weight(.semibold)).tracking(4)
                    Text(model.stateTitle).font(.headline).multilineTextAlignment(.center)
                    if let plan = model.planForDisplay {
                        Text(plan.windowStart, format: .dateTime.hour().minute())
                            .font(.system(.title, design: .rounded)).monospacedDigit()
                        Text("\(model.settings.cueCount.rawValue) коротких сигналов · сами затихнут")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if model.archive.plan?.settings.mode == .experimentalREM && model.hasPlan {
                        VStack(spacing: 6) {
                            Text(model.evidence.title).font(.caption).foregroundStyle(violet)
                            Text("В фоне оценка может быть недоступна.").font(.caption2).foregroundStyle(.secondary)
                        }.multilineTextAlignment(.center)
                    }
                    if model.hasPlan {
                        Button("Отменить сессию", role: .destructive) { model.cancel() }
                    } else {
                        Button { Task { await model.arm() } } label: { Text("Включить сессию") }
                            .tint(violet).buttonStyle(.borderedProminent).disabled(model.busy)
                    }
                    Button("Проба сигнала") { Task { await model.preview() } }
                    Button("Настройки") { settings = true }
                    if !model.archive.onboardingComplete {
                        Button("Разрешить сигналы") { Task { await model.requestSignalAccess() } }
                        Button("Подключить «Здоровье»") { Task { await model.connectHealth() } }
                    }
                }.padding(.horizontal, 4).padding(.bottom, 10)
            }.navigationTitle("Luma")
                .sheet(isPresented: $settings) { watchSettings }
                .onReceive(timer) { _ in if model.isForeground { Task { await model.refreshSensors() } } }
                .alert("Luma", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                    Button("Понятно", role: .cancel) { model.message = nil }
                } message: { Text(model.message ?? "") }
        }
    }
    private var watchSettings: some View {
        NavigationStack {
            Form {
                Picker("Коротких сигналов", selection: Binding(get: { model.settings.cueCount }, set: { v in model.changeSettings { $0.cueCount = v } })) {
                    ForEach(CueCount.allCases) { count in Text("\(count.rawValue)").tag(count) }
                }.disabled(model.hasPlan)
                Picker("Режим", selection: Binding(get: { model.settings.mode }, set: { v in model.changeSettings { $0.mode = v } })) {
                    ForEach(NightMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.disabled(model.hasPlan)
                Text("Время и паузу между сигналами настройте на iPhone. Изменения применятся после включения новой сессии.")
                    .font(.footnote)
                Button("Разрешить сигналы") { Task { await model.requestSignalAccess() } }
                Button("Данные «Здоровья»") { Task { await model.connectHealth() } }
                Text("Для тихих сигналов включите бесшумный режим часов и разрешите Luma в фокусировании «Сон». Рисунок вибрации уведомлений задаёт watchOS.").font(.footnote)
                Text("REM-режим — непроверенная оценка. Непрерывное наблюдение ночью не обеспечивается.").font(.footnote)
            }.navigationTitle("Настройки")
        }
    }
}
