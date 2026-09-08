import Foundation

/// Conservative, causal, unvalidated rules for a sensor feasibility build.
/// This is NOT Apple's classifier, a trained ML model, or a 70%-accurate detector.
/// Missing movement is unknown, never interpreted as "the user is still".
public struct REMEstimator: Sendable {
  public init() {}

  public func evaluate(heart: [HeartSample], motion: [MotionEpoch], now: Date) -> REMEvidence {
    let earliest = now.addingTimeInterval(-45 * 60)
    let recentStart = now.addingTimeInterval(-12 * 60)
    let valid = heart.filter {
      $0.date >= earliest && $0.date <= now && $0.bpm.isFinite && (30...210).contains($0.bpm)
    }
    // Never combine independent sensors into one physiological series.
    let grouped = Dictionary(grouping: valid, by: \.source)
    guard
      let series = grouped.values.max(by: { a, b in
        (a.map(\.date).max() ?? .distantPast) < (b.map(\.date).max() ?? .distantPast)
      })
    else { return .unavailable("Нет доступных измерений пульса.") }
    let unique = Dictionary(grouping: series, by: \.date).compactMap { _, samples in samples.first }
      .sorted { $0.date < $1.date }
    let recent = unique.filter { $0.date >= recentStart }
    guard let first = recent.first, let last = recent.last,
      recent.count >= 6, last.date.timeIntervalSince(first.date) >= 6 * 60
    else {
      return .unavailable("Пока слишком мало измерений пульса для оценки.")
    }
    guard now.timeIntervalSince(last.date) <= 90 else {
      return .unavailable("Последнее измерение пульса устарело.")
    }
    guard zip(recent, recent.dropFirst()).allSatisfy({ $1.date.timeIntervalSince($0.date) <= 150 })
    else {
      return .unavailable("Между измерениями пульса слишком большие промежутки.")
    }
    let baseline = unique.filter { $0.date < recentStart }
    guard baseline.count >= 6, let b0 = baseline.first, let b1 = baseline.last,
      b1.date.timeIntervalSince(b0.date) >= 10 * 60
    else {
      return .unavailable("Нужен более длинный участок для сравнения пульса.")
    }
    let epochs = motion.filter {
      $0.end <= now && $0.start >= now.addingTimeInterval(-180) && $0.end > $0.start
        && $0.end.timeIntervalSince($0.start) <= 45 && $0.rmsG.isFinite && $0.rmsG >= 0
        && $0.sampleCount >= 50
    }.sorted { $0.start < $1.start }
    guard epochs.count >= 3, let mLast = epochs.last, now.timeIntervalSince(mLast.end) <= 45,
      zip(epochs, epochs.dropFirst()).allSatisfy({ $1.start >= $0.end }),
      epochs.reduce(0.0, { $0 + $1.end.timeIntervalSince($1.start) }) >= 75
    else {
      return .unavailable("Нет свежего непрерывного участка данных о движении.")
    }
    let movement = epochs.reduce(0.0) { $0 + $1.rmsG } / Double(epochs.count)
    let current = median(recent.map(\.bpm))
    let resting = median(baseline.map(\.bpm))
    let sd = standardDeviation(recent.map(\.bpm))
    // Hand-set thresholds are intentionally transparent. Validate/replace before release.
    let rise = min(1, max(0, (current - resting) / 8))
    let variability = min(1, max(0, (sd - 1) / 5))
    let stillness = min(1, max(0, 1 - movement / 0.035))
    let score = 0.40 * rise + 0.35 * variability + 0.25 * stillness
    let candidate = score >= 0.72 && movement < 0.020 && current < 100
    return REMEvidence(
      kind: candidate ? .candidate : .unlikely,
      heuristicScore: score, latestSampleAt: last.date,
      explanation: candidate
        ? "Есть сочетание изменений пульса и низкой двигательной активности. Это не подтверждение REM."
        : "Доступные сигналы не дают устойчивых REM-подобных признаков.")
  }

  private func median(_ numbers: [Double]) -> Double {
    let sorted = numbers.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }
  private func standardDeviation(_ numbers: [Double]) -> Double {
    let mean = numbers.reduce(0, +) / Double(numbers.count)
    return sqrt(numbers.reduce(0) { $0 + pow($1 - mean, 2) } / Double(numbers.count))
  }
}
