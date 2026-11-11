import SwiftUI

struct IndirectMethodCard: View {
  @EnvironmentObject private var model: AppModel
  @State private var showingHelp = false
  @State private var choosingInterval = false
  @State private var showReadiness = false
  @State private var readyToStart = false
  var body: some View {
    LumaCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 0) {
          Text("Непрямой метод").font(LumaStyle.font(17, "SemiBold"))
          Button { showingHelp = true } label: {
            Image(systemName: "questionmark.circle")
              .font(.system(size: 21, weight: .regular))
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(LumaStyle.lavender)
              .frame(width: 44, height: 44, alignment: .center)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain).accessibilityLabel("Как работает непрямой метод")
          .accessibilityIdentifier("indirect.help")
          Spacer(minLength: 4)
        }
        Button { choosingInterval = true } label: {
          HStack {
            Text("Интервал").foregroundStyle(LumaStyle.secondary)
            Spacer()
            Text("\(model.indirectIntervalMinutes) мин")
              .font(LumaStyle.font(14, "Medium"))
              .monospacedDigit()
              .foregroundStyle(LumaStyle.lavender)
              .padding(.horizontal, 12).padding(.vertical, 6)
              .background(LumaStyle.lavender.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          .font(LumaStyle.font(14)).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("indirect.interval")
          .disabled(model.indirectRunning || model.busy)
        if model.indirectRunning {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            if let next = model.systemAlarms.indirectRecords.first(where: { $0.fireAt > context.date }) {
              HStack(spacing: 5) {
                Text("Следующий сигнал через")
                Text(next.fireAt, style: .timer).monospacedDigit()
              }.font(LumaStyle.font(12)).foregroundStyle(LumaStyle.secondary)
            } else {
              Text("В очереди нет новых сигналов. Откройте справку.")
                .font(LumaStyle.font(12)).foregroundStyle(LumaStyle.amber)
            }
          }
        }
        Button {
          if model.indirectRunning { Task { await model.stopIndirectMethod() } }
          else if model.systemAlarms.acceptedLimitations { Task { await model.requestIndirectMethodStart() } }
          else { showReadiness = true }
        } label: {
          Label(model.indirectRunning ? "Завершить" : "Начать",
            systemImage: model.indirectRunning ? "stop.fill" : "play.fill")
        }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy || model.systemAlarms.preparing)
          .accessibilityIdentifier("indirect.start")
      }
    }
    .sheet(isPresented: $choosingInterval) {
      IndirectIntervalSheet().environmentObject(model)
    }
    .sheet(isPresented: $showingHelp) { IndirectHelpView().environmentObject(model) }
    .sheet(isPresented: $showReadiness, onDismiss: {
      if readyToStart { readyToStart = false; Task { await model.requestIndirectMethodStart() } }
    }) {
      SignalReadinessView(continueTitle: "Разрешить и начать") {
        readyToStart = true
      }.environmentObject(model)
    }
  }
}

private struct IndirectIntervalSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var minutes = 30
  var body: some View {
    ScrollView {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Интервал").font(LumaStyle.font(23, "Medium"))
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Закрыть")
      }
      Text("Повторять сигнал каждые")
        .font(LumaStyle.font(13)).foregroundStyle(LumaStyle.secondary)
      Picker("Минут между сигналами", selection: $minutes) {
        ForEach(10...60, id: \.self) { Text("\($0) мин").tag($0) }
      }.pickerStyle(.wheel).frame(height: 185).accessibilityIdentifier("indirect.minutes")
      Button("Сохранить интервал") {
        Task { if await model.setIndirectInterval(minutes) { dismiss() } }
      }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("indirect.save")
    }
    .padding(24)
    }.background(LumaStyle.surface).foregroundStyle(LumaStyle.text)
    .presentationDetents([.large]).presentationDragIndicator(.visible)
    .presentationCornerRadius(28).presentationBackground(LumaStyle.surface)
    .onAppear { minutes = model.indirectIntervalMinutes }
  }
}

private struct IndirectHelpView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text("Непрямой метод").font(LumaStyle.font(25, "Medium"))
          Spacer()
          Button { dismiss() } label: {
            Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("Закрыть справку")
        }
        Text("Функция предназначена для практики непрямого метода после коротких пробуждений.")
        Text("Интервал задаёт время между началами сигналов. Выберите любое значение от 10 до 60 минут, затем нажмите «Начать».")
        Text("Например, при интервале 15 минут сигналы начинаются через 15, 30, 45 минут и так далее. Выбранный интервал сохраняется, пока вы его не измените.")
        Text("Режим предназначен для повторяющихся коротких сигналов до завершения сеанса. Это расписание по времени; оно не определяет фазу сна.")
        Text("Каждый сигнал — отдельное уведомление с конечным звуком длиной 4 секунды. Выключите беззвучный режим и разрешите Luma в Focus. С подключёнными Watch проверьте, на какое устройство приходит уведомление.")
        Text("Luma заранее ставит до 60 сигналов в пределах ближайших 12 часов и пополняет очередь при открытии приложения. При интервале 30 минут это до 24 сигналов. Другие будильники используют ту же очередь. Ориентируйтесь на время последнего поставленного сигнала ниже и открывайте Luma для продления.")
        if let until = model.systemAlarms.queueUntil {
          Text("Сейчас сигналы в очереди до \(until.formatted(date: .abbreviated, time: .shortened)).")
        }
      }.font(LumaStyle.font(14)).lineSpacing(5).padding(24)
    }.foregroundStyle(LumaStyle.text).background(LumaStyle.surface)
      .presentationDetents([.large]).presentationDragIndicator(.visible)
      .presentationCornerRadius(28).presentationBackground(LumaStyle.surface)
  }
}
