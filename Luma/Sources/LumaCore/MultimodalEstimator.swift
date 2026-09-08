import Foundation

public struct SensorEvaluation: Sendable {
  public var evidence: REMEvidence
  public var features: FeatureSnapshot
}
public enum Personalization {
  public static func examples(state: LumaState) -> [(FeatureSnapshot, Bool)] {
    var nights = Set<Int64>()
    return state.feedback.sorted { $0.updatedAt > $1.updatedAt }.compactMap { f in
      guard f.noticed == .yes, f.lucid != .unsure,
        let s = state.sessions.first(where: { $0.id == f.sessionID }), s.status == .ended,
        s.source.usesWatch
      else { return nil }
      let e =
        f.episodeID.flatMap { id in s.episodes.first { $0.id == id } }
        ?? (s.episodes.count == 1 ? s.episodes.first : nil)
      guard let x = e?.features, let hr = x.heartRate, let sd = x.heartSpread, hr.isFinite,
        sd.isFinite,
        nights.insert(Int64(floor((s.startedAt.timeIntervalSince1970 - 43200) / 86400))).inserted
      else { return nil }
      return (x, f.lucid == .yes)
    }
  }
  /// Self-reports optimize cue context, never label REM. Bounded influence after diverse, independent nights.
  public static func adjustment(for f: FeatureSnapshot, state: LumaState) -> Double {
    guard state.personalizationEnabled, f.source.usesWatch, let hr = f.heartRate,
      let sd = f.heartSpread
    else { return 0 }
    let data = examples(state: state)
    let yes = data.filter { $0.1 }
    let no = data.filter { !$0.1 }
    guard data.count >= 12, yes.count >= 4, no.count >= 4 else { return 0 }
    func affinity(_ data: [(FeatureSnapshot, Bool)]) -> Double {
      data.reduce(0) { total, item in
        var d = pow((hr - item.0.heartRate!) / 12, 2) + pow((sd - item.0.heartSpread!) / 5, 2)
        func add(_ a: Double?, _ b: Double?, _ scale: Double, _ weight: Double) {
          if let a, let b, a.isFinite, b.isFinite { d += weight * pow((a - b) / scale, 2) }
        }
        add(f.respiration, item.0.respiration, 4, 0.4)
        add(f.acousticBreathing, item.0.acousticBreathing, 5, 0.2)
        add(f.movement, item.0.movement, 0.015, 0.3)
        add(f.soundDB, item.0.soundDB, 12, 0.1)
        return total + exp(-0.5 * d)
      } / Double(data.count)
    }
    return max(-0.025, min(0.025, (affinity(yes) - affinity(no)) * 0.025))
  }
}
public struct MultimodalEstimator: Sendable {
  public init() {}
  public func evaluate(
    source: SensorSource, heart: [HeartSample], motion: [MotionEpoch], breath: [BreathSample],
    audio: [AudioEpoch], now: Date, state: LumaState
  ) -> SensorEvaluation {
    var f = FeatureSnapshot(date: now, source: source)
    func missing(_ text: String) -> SensorEvaluation {
      SensorEvaluation(evidence: .unavailable(text), features: f)
    }
    let a = audio.filter {
      !$0.contaminated && $0.start >= now.addingTimeInterval(-600) && $0.end <= now
        && (55...65).contains($0.end.timeIntervalSince($0.start)) && $0.levelDB.isFinite
        && $0.transientFraction.isFinite && $0.periodicity.isFinite
        && (0...1).contains($0.transientFraction) && (0...1).contains($0.periodicity)
        && (-140...0).contains($0.levelDB)
    }.sorted { $0.end < $1.end }
    let freshAudio =
      a.count >= 6 && now.timeIntervalSince(a.last?.end ?? .distantPast) <= 65
      && zip(a, a.dropFirst()).allSatisfy {
        $1.start >= $0.end.addingTimeInterval(-1) && $1.end.timeIntervalSince($0.end) <= 65
      }
    let periodic = a.compactMap(\.breathingProxy).filter { $0.isFinite && (6...30).contains($0) }
    if freshAudio {
      f.soundDB = a.last?.levelDB
      f.acousticBreathing = periodic.last
    }
    if source.usesWatch {
      f.respiration =
        breath.filter {
          $0.date <= now && now.timeIntervalSince($0.date) < 180 && $0.perMinute.isFinite
            && (6...35).contains($0.perMinute)
        }.max { $0.date < $1.date }?.perMinute
    }
    if source == .phone {
      guard freshAudio, periodic.count >= 5, let last = a.last, last.levelDB > -65,
        mean(a.map(\.periodicity)) >= 0.45, mean(a.map(\.transientFraction)) < 0.15
      else { return missing("Микрофон собирает данные. Нужен устойчивый акустический сигнал.") }
      let variation = deviation(periodic) / max(1, mean(periodic))
      let score = min(1, variation / 0.18) * 0.65 + (1 - mean(a.map(\.transientFraction))) * 0.35
      f.score = score
      return SensorEvaluation(
        evidence: REMEvidence(
          kind: score >= 0.80 && variation >= 0.10 ? .candidate : .unlikely, heuristicScore: score,
          latestSampleAt: last.end,
          explanation:
            "Оценка по звуку — эксперимент. Шумы и дыхание другого человека могут мешать."),
        features: f)
    }
    let h = heart.filter {
      $0.date <= now && $0.date >= now.addingTimeInterval(-2700) && $0.bpm.isFinite
        && (30...210).contains($0.bpm)
    }
    guard
      let stream = Dictionary(grouping: h, by: \.source).values.max(by: {
        ($0.map(\.date).max() ?? .distantPast) < ($1.map(\.date).max() ?? .distantPast)
      })
    else { return missing("Ожидаем свежий пульс Apple Watch.") }
    let unique = Dictionary(grouping: stream, by: \.date).compactMap { $0.value.first }.sorted {
      $0.date < $1.date
    }
    let recent = unique.filter { $0.date >= now.addingTimeInterval(-720) }
    let baseline = unique.filter { $0.date < now.addingTimeInterval(-720) }
    guard recent.count >= 6, baseline.count >= 6, let first = recent.first, let last = recent.last,
      now.timeIntervalSince(last.date) <= 90, last.date.timeIntervalSince(first.date) >= 360,
      baseline.last!.date.timeIntervalSince(baseline.first!.date) >= 600,
      zip(recent, recent.dropFirst()).allSatisfy({ $1.date.timeIntervalSince($0.date) <= 150 })
    else { return missing("Пульса мало или он поступает с задержкой. Подсказка пропускается.") }
    let hr = mean(recent.map(\.bpm))
    let sd = deviation(recent.map(\.bpm))
    f.heartRate = hr
    f.heartSpread = sd
    let me = REMEstimator().evaluate(heart: unique, motion: motion, now: now)
    let freshMotion = me.kind != .insufficient
    if freshMotion {
      f.movement = mean(
        motion.filter { $0.end <= now && now.timeIntervalSince($0.end) <= 180 }.map(\.rmsG))
    }
    guard freshMotion || (source == .combined && freshAudio && periodic.count >= 5) else {
      return missing("Ожидаем движения часов или пригодный звук с iPhone.")
    }
    var score =
      me.heuristicScore
      ?? (0.40 * min(1, max(0, (hr - mean(baseline.map(\.bpm))) / 8)) + 0.35
        * min(1, max(0, (sd - 1) / 5)) + 0.25 * max(0, 1 - mean(a.map(\.transientFraction)) / 0.2))
    score += Personalization.adjustment(for: f, state: state)
    f.score = score
    let candidate =
      score >= 0.74 && hr < 100 && (f.movement.map { $0 < 0.020 } ?? true)
      && (f.respiration.map { (8...26).contains($0) } ?? true)
      && (!freshAudio || mean(a.map(\.transientFraction)) < 0.2)
    return SensorEvaluation(
      evidence: REMEvidence(
        kind: candidate ? .candidate : .unlikely, heuristicScore: score, latestSampleAt: last.date,
        explanation:
          "Сопоставляем доступные пульс, движение, дыхание и звук. Это не подтверждение REM."),
      features: f)
  }
  private func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
  private func deviation(_ a: [Double]) -> Double {
    let m = mean(a)
    return a.isEmpty ? 0 : sqrt(a.reduce(0) { $0 + pow($1 - m, 2) } / Double(a.count))
  }
}
