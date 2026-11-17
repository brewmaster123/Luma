import Foundation

/// 0.9.8: English for the status line on the watch. The queue code keeps producing its
/// Russian status texts unchanged; this only decides how one of them is shown.
/// The watch follows its own system language: Russian stays Russian, anything else is English.
enum WatchText {
  static var english: Bool {
    Bundle.main.preferredLocalizations.first?.hasPrefix("ru") != true
  }

  static func show(_ text: String) -> String {
    renamed(english ? translated(text) : text)
  }

  private static func translated(_ text: String) -> String {
    let direct = NSLocalizedString(text, comment: "")
    if direct != text { return direct }
    let queued = "В очереди на часах: "
    if text.hasPrefix(queued) {
      return "Queued on the watch: " + String(text.dropFirst(queued.count))
    }
    return text
  }

  /// Since 17 Nov 2026 the app is called Lumenoir. The queue code still writes the old name
  /// "Luma" into its status texts; it is replaced here on the way to the screen (the word itself only).
  static func renamed(_ text: String) -> String {
    guard text.contains("Luma") else { return text }
    return text.replacingOccurrences(of: "\\bLuma\\b", with: "Lumenoir", options: .regularExpression)
  }
}
