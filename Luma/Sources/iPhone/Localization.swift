import Foundation
import SwiftUI

/// 0.9.8: the interface language. Russian is the language the app is written in;
/// English is produced from it (see LocalizationTable.swift). Nothing here is stored
/// with the user's alarms, journal or sounds.
enum AppLanguage: String, CaseIterable, Identifiable {
  case english = "en"
  case russian = "ru"
  var id: String { rawValue }
  /// Each language is named in itself, so it can be found whichever one is on screen.
  var nativeName: String { self == .english ? "English" : "Русский" }
}

final class LanguageStore: ObservableObject {
  static let shared = LanguageStore()
  static let preferenceKey = "com.sevchlenko.luma.interfaceLanguage.v1"
  @Published private(set) var language: AppLanguage

  private init() {
    if let saved = UserDefaults.standard.string(forKey: LanguageStore.preferenceKey),
      let value = AppLanguage(rawValue: saved) {
      language = value
    } else {
      language = LanguageStore.systemLanguage
    }
  }

  /// First launch (and every launch until a language is picked in Settings):
  /// Russian when the iPhone itself speaks Russian, English for any other system language.
  static var systemLanguage: AppLanguage {
    let first = Locale.preferredLanguages.first ?? "en"
    return first.lowercased().hasPrefix("ru") ? .russian : .english
  }

  func choose(_ value: AppLanguage) {
    UserDefaults.standard.set(value.rawValue, forKey: LanguageStore.preferenceKey)
    if language != value { language = value }
  }
}

/// Interface text. The argument is the Russian text; in English its translation is returned.
func tr(_ russian: String) -> String { L10n.text(russian) }

enum L10n {
  static var language: AppLanguage { LanguageStore.shared.language }
  static var isEnglish: Bool { language == .english }

  static func text(_ russian: String) -> String {
    guard isEnglish else { return renamed(russian) }
    return renamed(LumaEnglish.table[russian] ?? russian)
  }

  // MARK: The app's name

  /// The name people see. Until 17 Nov 2026 the app was called Luma; the internal names
  /// (folders, targets, the bundle ID com.sevchlenko.luma, data keys) stay as they were.
  static let appName = "Lumenoir"

  /// The unchanged signal engine still says "Luma" in its messages and alarm titles.
  /// On the way to the screen the old name is replaced, in both languages. Only the word itself
  /// is replaced, so names such as "LumaAlarmKit" are left alone.
  static func renamed(_ text: String) -> String {
    guard text.contains("Luma") else { return text }
    return text.replacingOccurrences(of: "\\bLuma\\b", with: appName, options: .regularExpression)
  }

  // MARK: Text that comes from the signal engine

  /// Status lines and error messages are produced by the unchanged engine in Russian.
  /// They are prepared for the screen here: a few old strings that were saved in a broken
  /// encoding are repaired, wording that mentions the old 3–10 s range is brought up to date,
  /// in English the message is translated, and the old name Luma becomes Lumenoir.
  static func show(_ raw: String) -> String {
    var text = repair(raw)
    if let current = LumaEnglish.russianUpdates[text] {
      text = current
    } else if let match = LumaEnglish.russianUpdates.first(where: { text.hasSuffix(": " + $0.key) }) {
      // 1.0: an engine message behind a prefix ("Очередь сигналов: …") is brought up to date in Russian too.
      text = String(text.dropLast(match.key.count)) + match.value
    }
    guard isEnglish else { return renamed(text) }
    if let direct = LumaEnglish.table[text] { return renamed(direct) }
    for rule in LumaEnglish.rules {
      if let translated = rule.apply(text) { return renamed(translated) }
    }
    return renamed(text)
  }

  /// The engine's note that a test signal has been put in the queue ("Проба через 60 сек. …").
  /// Settings shows the countdown of a test itself, so this note needs no card of its own.
  /// Returns the delay in seconds, or nil for any other message.
  static func probeNoticeDelay(_ raw: String) -> Int? {
    let text = repair(raw)
    let opening = "Проба через "
    guard text.hasPrefix(opening), text.contains("Остановка AlarmKit") else { return nil }
    let digits = text.dropFirst(opening.count).prefix(while: { $0.isNumber })
    return Int(String(digits))
  }

  /// A message built from a fixed opening and a variable tail, e.g. "Часы: <текст ошибки>".
  struct Rule {
    let regex: NSRegularExpression?
    let template: String
    /// Capture groups that are messages themselves and go through `show` again.
    let nested: [Int]

    init(_ pattern: String, _ template: String, nested: [Int] = []) {
      regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
      self.template = template
      self.nested = nested
    }

    func apply(_ text: String) -> String? {
      guard let regex else { return nil }
      let whole = NSRange(text.startIndex..<text.endIndex, in: text)
      guard let match = regex.firstMatch(in: text, options: [], range: whole),
        match.range.location == whole.location, match.range.length == whole.length else { return nil }
      var result = template
      var index = match.numberOfRanges - 1
      while index >= 1 {
        if let range = Range(match.range(at: index), in: text) {
          var piece = String(text[range])
          if nested.contains(index) { piece = L10n.show(piece) }
          result = result.replacingOccurrences(of: "$\(index)", with: piece)
        }
        index -= 1
      }
      return result
    }
  }

  /// Some literals in the engine were once saved as UTF-8 read back as Windows-1251
  /// ("Проверяем" became "РџСЂРѕРІРµСЂСЏРµРј"). The engine files are left as they are;
  /// the text is put right on its way to the screen.
  static func repair(_ text: String) -> String {
    guard text.contains("Р") || text.contains("С") || text.contains("В·") || text.contains("вЂ") else {
      return text
    }
    if let fixed = decodeTwice(text) { return fixed }
    var changed = false
    let words = text.components(separatedBy: " ").map { word -> String in
      guard let fixed = decodeTwice(word) else { return word }
      changed = true
      return fixed
    }
    return changed ? words.joined(separator: " ") : text
  }

  private static func decodeTwice(_ text: String) -> String? {
    guard let data = text.data(using: .windowsCP1251, allowLossyConversion: false),
      let fixed = String(data: data, encoding: .utf8), fixed != text, !fixed.isEmpty else { return nil }
    let plausible = fixed.unicodeScalars.contains { scalar in
      (0x0400...0x04FF).contains(scalar.value) || scalar == "·" || scalar == "…" || scalar == "—" || scalar == "–"
    }
    return plausible ? fixed : nil
  }

  // MARK: Dates, times and numbers in the chosen language

  static var locale: Locale {
    let current = Locale.current
    let code = current.language.languageCode?.identifier ?? ""
    if code == language.rawValue { return current }
    return Locale(identifier: language == .russian ? "ru_RU" : "en_GB")
  }

  /// "16 ноября" / "16 November"; the year is added when it is not the current one.
  static func dayTitle(_ date: Date) -> String {
    let calendar = Calendar.current
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
    let style = sameYear
      ? Date.FormatStyle().day().month(.wide)
      : Date.FormatStyle().day().month(.wide).year()
    return date.formatted(style.locale(locale))
  }

  static func time(_ date: Date) -> String {
    date.formatted(Date.FormatStyle().hour().minute().locale(locale))
  }

  static func dateTime(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
  }

  static func shortDate(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
  }

  static func clock(_ seconds: Double) -> String {
    let value = max(0, Int(seconds))
    return String(format: "%02d:%02d", value / 60, value % 60)
  }

  /// Russian has three plural forms; English has two.
  static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let a = abs(n) % 10, b = abs(n) % 100
    if a == 1 && b != 11 { return one }
    if a >= 2 && a <= 4 && (b < 12 || b > 14) { return few }
    return many
  }

  /// "4 секунды" / "4 seconds"
  static func seconds(_ n: Int) -> String {
    if isEnglish { return "\(n) " + (n == 1 ? "second" : "seconds") }
    return "\(n) " + plural(n, "секунду", "секунды", "секунд")
  }

  /// "каждые 30 минут" / "every 30 minutes"
  static func everyMinutes(_ n: Int) -> String {
    if isEnglish { return n == 1 ? "every minute" : "every \(n) minutes" }
    return plural(n, "каждую", "каждые", "каждые") + " \(n) " + plural(n, "минуту", "минуты", "минут")
  }

  /// "2 записи" / "2 entries"
  static func entries(_ n: Int) -> String {
    if isEnglish { return "\(n) " + (n == 1 ? "entry" : "entries") }
    return "\(n) " + plural(n, "запись", "записи", "записей")
  }

  /// "3 предполагаемых эпизода" / "3 estimated episodes" (records of earlier versions)
  static func episodes(_ n: Int) -> String {
    if isEnglish { return "\(n) " + (n == 1 ? "estimated episode" : "estimated episodes") }
    return "\(n) " + plural(n, "предполагаемый эпизод", "предполагаемых эпизода", "предполагаемых эпизодов")
  }

  /// Short names of the days of the week, keyed by Calendar weekday (1 = Sunday).
  static func weekday(_ number: Int) -> String {
    let russian = [1: "Вс", 2: "Пн", 3: "Вт", 4: "Ср", 5: "Чт", 6: "Пт", 7: "Сб"]
    let english = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
    return (isEnglish ? english[number] : russian[number]) ?? ""
  }

  /// "по будням", "пн, ср", "один раз" / "weekdays", "Mon, Wed", "once"
  static func repeats(_ weekdays: Set<Int>) -> String {
    if weekdays.isEmpty { return isEnglish ? "once" : "один раз" }
    if weekdays == Set([2, 3, 4, 5, 6]) { return isEnglish ? "weekdays" : "по будням" }
    if weekdays == Set([1, 7]) { return isEnglish ? "weekends" : "по выходным" }
    if weekdays.count == 7 { return isEnglish ? "every day" : "каждый день" }
    let order = [2, 3, 4, 5, 6, 7, 1].filter { weekdays.contains($0) }
    let names = order.map { isEnglish ? weekday($0) : weekday($0).lowercased() }
    return names.joined(separator: ", ")
  }
}
