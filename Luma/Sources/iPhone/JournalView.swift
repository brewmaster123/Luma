import Charts
import SwiftUI

struct JournalView: View {
  @EnvironmentObject private var model: AppModel
  @State private var section = 0
  @State private var session: NightSession?
  @State private var dream: DreamEntry?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("Дневник").font(LumaStyle.font(30, "Medium", relativeTo: .largeTitle))
        Text("Сохраните то, что хочется запомнить.").foregroundStyle(LumaStyle.secondary)
        HStack(spacing: 10) {
          Button("Сеансы") { section = 0 }.padding(13).background(
            section == 0 ? LumaStyle.surface : .clear, in: Capsule())
          Button {
            section = 1
          } label: {
            HStack(spacing: 7) {
              Text("Толкование снов")
              Text("Скоро").font(LumaStyle.font(9, "SemiBold")).padding(5).background(
                LumaStyle.lavender.opacity(0.13), in: Capsule())
            }
          }.padding(.vertical, 13)
        }.font(LumaStyle.font(12, "Medium")).foregroundStyle(LumaStyle.lavender)
        if section == 1 {
          LumaCard {
            VStack(alignment: .leading, spacing: 20) {
              Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(
                LumaStyle.lavender)
              Text("У каждого сна\nсвоя история.").font(LumaStyle.font(25, "Medium"))
              Text(
                "Толкование снов появится в одном из будущих обновлений. Пока сохраняйте сновидения в дневнике — этот раздел ещё не анализирует записи."
              ).font(LumaStyle.font(14)).foregroundStyle(LumaStyle.secondary)
            }
          }
        } else {
          LumaCard {
            VStack(alignment: .leading, spacing: 9) {
              Text("Отклик — только по желанию").font(LumaStyle.font(16, "Medium"))
              Text(
                "Заметили подсказку? Удалось осознать сон? Можно оставить пару слов после ночи или просто продолжить свой день."
              ).font(LumaStyle.font(13)).foregroundStyle(LumaStyle.secondary)
            }
          }
          if model.state.sessions.isEmpty {
            Text("Здесь появится ваш первый ночной сеанс.").font(LumaStyle.font(14))
              .foregroundStyle(LumaStyle.secondary).padding(.vertical, 12)
          }
          ForEach(model.state.sessions) { s in
            Button {
              session = s
            } label: {
              LumaCard {
                HStack {
                  VStack(alignment: .leading, spacing: 9) {
                    Text(s.startedAt.formatted(date: .abbreviated, time: .omitted)).font(
                      LumaStyle.font(18, "Medium"))
                    Text("\(s.episodes.count) предполагаемых эпизодов · \(s.source.title)").font(
                      LumaStyle.font(11)
                    ).foregroundStyle(LumaStyle.secondary)
                    Text(
                      s.status != .ended
                        ? "Сеанс ещё не завершён"
                        : model.state.feedback.contains(where: { $0.sessionID == s.id })
                          ? "Отклик сохранён" : "Оставить отклик · необязательно"
                    ).font(LumaStyle.font(11)).foregroundStyle(LumaStyle.lavender)
                  }
                  Spacer()
                  Image(systemName: "chevron.right").foregroundStyle(LumaStyle.secondary)
                }
              }
            }.buttonStyle(.plain)
          }
          if !model.sleep.isEmpty { SleepHistoryCard(segments: model.sleep) }
          HStack {
            Text("Мои сновидения").font(LumaStyle.font(21, "Medium"))
            Spacer()
            Button {
              dream = DreamEntry()
            } label: {
              Image(systemName: "plus").frame(width: 44, height: 44)
            }.accessibilityLabel("Записать сон")
          }
          if model.archive.diary.isEmpty {
            Text("Образы, места, ощущения. Можно начать с одной строки.").font(LumaStyle.font(13))
              .foregroundStyle(LumaStyle.secondary)
          }
          ForEach(model.archive.diary) { d in
            Button {
              dream = d
            } label: {
              LumaCard {
                VStack(alignment: .leading, spacing: 10) {
                  Text(d.date.formatted(date: .abbreviated, time: .omitted)).font(
                    LumaStyle.font(11)
                  ).foregroundStyle(LumaStyle.secondary)
                  Text(d.text).font(LumaStyle.font(14)).lineLimit(4)
                }
              }
            }.buttonStyle(.plain)
          }
        }
      }.padding(22)
    }.lumaScreen().toolbar(.hidden, for: .navigationBar)
      .sheet(item: $session) { s in
        SessionFeedbackView(
          session: s, feedback: model.state.feedback.first(where: { $0.sessionID == s.id })
        ).environmentObject(model)
      }
      .sheet(item: $dream) { DreamEditor(dream: $0).environmentObject(model) }
  }
}
struct SessionFeedbackView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let session: NightSession
  @State private var feedback: SessionFeedback
  @State private var deleting = false
  init(session: NightSession, feedback: SessionFeedback?) {
    self.session = session
    _feedback = State(initialValue: feedback ?? SessionFeedback(sessionID: session.id))
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Text(session.startedAt.formatted(date: .abbreviated, time: .shortened)).font(
            LumaStyle.font(22, "Medium"))
          Text("Это ваш опыт, а не оценка за ночь.").foregroundStyle(LumaStyle.secondary)
          ForEach(session.episodes) { e in
            LumaCard {
              VStack(alignment: .leading, spacing: 8) {
                Text(e.date.formatted(date: .omitted, time: .shortened)).font(
                  LumaStyle.font(19, "Medium"))
                Text("Предполагаемый REM · экспериментальная оценка").font(LumaStyle.font(11))
                  .foregroundStyle(LumaStyle.secondary)
                if let hr = e.features.heartRate {
                  Text("Пульс: \(Int(hr.rounded())) уд/мин").font(LumaStyle.font(13))
                }
                if let rate = e.features.respiration {
                  Text("Дыхание с часов: \(rate,specifier:"%.1f")/мин").font(LumaStyle.font(13))
                }
                if let proxy = e.features.acousticBreathing {
                  Text("Периодичность звука: \(proxy,specifier:"%.1f")/мин").font(
                    LumaStyle.font(12))
                }
                if let phone = e.phoneResult {
                  Text("iPhone: \(phone)").font(LumaStyle.font(11)).foregroundStyle(
                    LumaStyle.secondary)
                }
                if let watch = e.watchResult {
                  Text("Watch: \(watch)").font(LumaStyle.font(11)).foregroundStyle(
                    LumaStyle.secondary)
                }
              }
            }
          }
          if session.status == .ended {
            LumaCard {
              VStack(alignment: .leading, spacing: 22) {
                answer("Заметили подсказку?", $feedback.noticed)
                answer("Удалось осознать, что вы спите?", $feedback.lucid)
                answer("Подсказка разбудила вас?", $feedback.awakened)
                if session.episodes.count > 1 {
                  Picker("К какому сигналу относится отклик?", selection: $feedback.episodeID) {
                    Text("Не уверен(а) / в целом за ночь").tag(Optional<UUID>.none)
                    ForEach(session.episodes) { e in
                      Text(e.date.formatted(date: .omitted, time: .shortened)).tag(Optional(e.id))
                    }
                  }.font(LumaStyle.font(12))
                }
                Text(
                  "Если время не помните, оставьте общий отклик. При нескольких сигналах он не используется для личной настройки."
                ).font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary)
              }
            }
            Text("Что запомнилось?").font(LumaStyle.font(17, "Medium"))
            TextEditor(text: $feedback.note).frame(minHeight: 140).scrollContentBackground(.hidden)
              .padding(12).background(LumaStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            Button("Сохранить отклик") {
              model.saveFeedback(feedback)
              dismiss()
            }.buttonStyle(PrimaryButtonStyle())
            if model.state.feedback.contains(where: { $0.sessionID == session.id }) {
              Button("Удалить отклик", role: .destructive) { deleting = true }.frame(
                maxWidth: .infinity, minHeight: 44)
            }
          } else {
            Text("Отклик можно оставить после завершения сеанса.").foregroundStyle(
              LumaStyle.secondary)
          }
        }.padding(22)
      }.lumaScreen().navigationTitle("Отклик о ночи").navigationBarTitleDisplayMode(.inline).toolbar
      { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
    }
    .confirmationDialog("Удалить отклик?", isPresented: $deleting, titleVisibility: .visible) {
      Button("Удалить", role: .destructive) {
        model.deleteFeedback(session.id)
        dismiss()
      }
    }
  }
  private func answer(_ title: String, _ value: Binding<FeedbackAnswer>) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(LumaStyle.font(14))
      Picker(title, selection: value) {
        ForEach(FeedbackAnswer.allCases) { Text($0.title).tag($0) }
      }.pickerStyle(.segmented)
    }
  }
}
struct DreamEditor: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State var dream: DreamEntry
  @State private var deleting = false
  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 20) {
        Text("Каким был ваш сон?").font(LumaStyle.font(25, "Medium"))
        TextEditor(text: $dream.text).scrollContentBackground(.hidden).padding(12).background(
          LumaStyle.surface, in: RoundedRectangle(cornerRadius: 20))
        Button("Сохранить сон") {
          model.saveDream(dream)
          dismiss()
        }.buttonStyle(PrimaryButtonStyle()).disabled(
          dream.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if model.archive.diary.contains(where: { $0.id == dream.id }) {
          Button("Удалить сон", role: .destructive) { deleting = true }.frame(minHeight: 44)
        }
      }.padding(24).lumaScreen().toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
      }
    }
    .confirmationDialog("Удалить сон?", isPresented: $deleting, titleVisibility: .visible) {
      Button("Удалить", role: .destructive) {
        model.deleteDream(id: dream.id)
        dismiss()
      }
    }
  }
}
struct SleepHistoryCard: View {
  let segments: [SleepSegment]
  var body: some View {
    LumaCard {
      VStack(alignment: .leading, spacing: 12) {
        Text("Сон по данным Apple Watch").font(LumaStyle.font(16, "Medium"))
        Chart(segments) { s in
          RectangleMark(
            xStart: .value("Начало", s.start), xEnd: .value("Конец", s.end),
            y: .value("Стадия", s.stage.title), height: .ratio(0.75)
          ).foregroundStyle(s.stage == .rem ? LumaStyle.lavender : LumaStyle.secondary.opacity(0.4))
        }.frame(height: 150)
        Text(
          "Утренняя история Apple — тоже алгоритмическая оценка. Совпадение с ней не подтверждает точность Luma."
        ).font(LumaStyle.font(11)).foregroundStyle(LumaStyle.secondary)
      }
    }
  }
}
