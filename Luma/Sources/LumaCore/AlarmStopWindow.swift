import Foundation

/// An app-driven deadline, not an OS guarantee or an audio completion callback.
public struct AlarmStopWindow: Codable, Equatable, Sendable {
  public let startsAt: Date
  public let duration: TimeInterval
  public var endsAt: Date { startsAt.addingTimeInterval(duration) }
  public init?(startsAt: Date, duration: TimeInterval) {
    guard startsAt.timeIntervalSince1970.isFinite, duration.isFinite,
      duration > 0, duration <= 28.5 else { return nil }
    self.startsAt = startsAt; self.duration = duration
  }
  public func remaining(at date: Date) -> TimeInterval { max(0, endsAt.timeIntervalSince(date)) }
  public func hasExpired(at date: Date) -> Bool { date >= endsAt }
  private enum CodingKeys: String, CodingKey { case startsAt, duration }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let date = try values.decode(Date.self, forKey: .startsAt)
    let seconds = try values.decode(TimeInterval.self, forKey: .duration)
    guard let valid = Self(startsAt: date, duration: seconds) else {
      throw DecodingError.dataCorruptedError(forKey: .duration, in: values,
        debugDescription: "Invalid alarm stop duration")
    }
    self = valid
  }
}
extension LumaAlarm {
  /// Resolve a firing that may already be late when the app resumes.
  public func mostRecentOccurrence(at date: Date, calendar: Calendar = .current) -> Date? {
    guard enabled else { return nil }
    if weekdays.isEmpty { return onceAt <= date ? onceAt : nil }
    return weekdays.filter { (1...7).contains($0) }.compactMap {
      calendar.nextDate(after: date.addingTimeInterval(0.001),
        matching: DateComponents(hour: min(23, max(0, hour)), minute: min(59, max(0, minute)),
          second: 0, weekday: $0), matchingPolicy: .nextTime, repeatedTimePolicy: .first,
        direction: .backward)
    }.max()
  }
}
