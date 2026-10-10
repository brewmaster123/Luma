import Foundation

/// Causal feasibility detector, not a trained or calibrated sleep classifier.
/// BPM dispersion is not beat-to-beat HRV. No HealthKit sleep-stage input exists.
public struct RealtimeREMEngine: Sendable {
  public struct Decision: Sendable {
    public var evaluation: SensorEvaluation
    public var episode: REMEpisode?
  }
  public let startedAt: Date
  private var lastEvaluation: Date?
  private var lastEvidenceSample: Date?
  private var candidateSince: Date?
  private var exitSince: Date?
  private var insideEpisode = false
  private var lastCue: Date?
  private var excludedUntil = Date.distantPast

  public init(startedAt: Date) { self.startedAt = startedAt }

  public mutating func excludeCue(until date: Date) {
    excludedUntil = max(excludedUntil, date)
    candidateSince = nil
    exitSince = nil
  }

  public mutating func consume(heart: [HeartSample], motion: [MotionEpoch], now: Date) -> Decision {
    let evaluation = Self.evaluate(heart: heart, motion: motion, startedAt: startedAt, now: now)
    func result(_ episode: REMEpisode? = nil) -> Decision {
      Decision(evaluation: evaluation, episode: episode)
    }
    guard lastEvaluation.map({ now > $0 }) ?? true else { return result() }
    if let lastEvaluation, now.timeIntervalSince(lastEvaluation) > 45 {
      // Missing runtime must never count towards a sustained onset or exit.
      candidateSince = nil; exitSince = nil
    }
    lastEvaluation = now
    guard now >= excludedUntil else { return result() }
    let e = evaluation.evidence
    guard e.kind != .insufficient, let sample = e.latestSampleAt,
      lastEvidenceSample.map({ sample > $0 }) ?? true else {
      candidateSince = nil; exitSince = nil
      return result()
    }
    lastEvidenceSample = sample
    if e.kind == .unlikely {
      candidateSince = nil
      if insideEpisode {
        if exitSince == nil { exitSince = now }
        if now.timeIntervalSince(exitSince!) >= 180 { insideEpisode = false; exitSince = nil }
      }
      return result()
    }
    exitSince = nil
    guard !insideEpisode else { return result() }
    guard lastCue.map({ now.timeIntervalSince($0) >= 15 * 60 }) ?? true else {
      candidateSince = nil
      return result()
    }
    if candidateSince == nil { candidateSince = now }
    guard now.timeIntervalSince(candidateSince!) >= 90 else { return result() }
    insideEpisode = true; candidateSince = nil; lastCue = now
    return result(REMEpisode(date: now, features: evaluation.features))
  }

  public static func evaluate(heart: [HeartSample], motion: [MotionEpoch], startedAt: Date,
                             now: Date) -> SensorEvaluation {
    var f = FeatureSnapshot(date: now, source: .watch)
    func missing(_ text: String) -> SensorEvaluation {
      SensorEvaluation(evidence: .unavailable(text), features: f)
    }
    guard now.timeIntervalSince(startedAt) >= 20 * 60 else {
      return missing("Собираем личный уровень пульса · первые 20 минут")
    }
    let valid = heart.filter {
      $0.date >= max(startedAt, now.addingTimeInterval(-30 * 60)) && $0.date <= now
        && $0.bpm.isFinite && (30...210).contains($0.bpm)
    }
    let streams = Dictionary(grouping: valid, by: \.source)
    guard let stream = streams.values.max(by: {
      ($0.map(\.date).max() ?? .distantPast) < ($1.map(\.date).max() ?? .distantPast)
    }) else { return missing("Нет свежего пульса часов") }
    let unique = Dictionary(grouping: stream, by: \.date).compactMap { $0.value.first }
      .sorted { $0.date < $1.date }
    let current = unique.filter { $0.date >= now.addingTimeInterval(-180) }
    let baseline = unique.filter { $0.date < now.addingTimeInterval(-5 * 60) }
    guard let first = current.first, let last = current.last,
      current.count >= 8, now.timeIntervalSince(last.date) <= 30,
      last.date.timeIntervalSince(first.date) >= 120,
      zip(current, current.dropFirst()).allSatisfy({ $1.date.timeIntervalSince($0.date) <= 45 })
    else { return missing("Пульса недостаточно или измерения устарели") }
    guard baseline.count >= 30, let b0 = baseline.first, let b1 = baseline.last,
      b1.date.timeIntervalSince(b0.date) >= 8 * 60,
      zip(baseline, baseline.dropFirst()).allSatisfy({ $1.date.timeIntervalSince($0.date) <= 90 })
    else { return missing("Собираем непрерывный участок для сравнения пульса") }
    let epochs = motion.filter {
      $0.start >= max(startedAt, now.addingTimeInterval(-150)) && $0.end <= now
        && (25...40).contains($0.end.timeIntervalSince($0.start))
        && $0.rmsG.isFinite && $0.rmsG >= 0 && $0.sampleCount >= 50
    }.sorted { $0.start < $1.start }
    guard epochs.count >= 3, let lastMotion = epochs.last,
      now.timeIntervalSince(lastMotion.end) <= 40,
      epochs.reduce(0.0, { $0 + $1.end.timeIntervalSince($1.start) }) >= 85,
      zip(epochs, epochs.dropFirst()).allSatisfy({
        $1.start >= $0.end && $1.start.timeIntervalSince($0.end) <= 2
      }) else { return missing("Нет непрерывного участка движений часов") }
    let bpm = mean(current.map(\.bpm))
    let baselineBPM = mean(baseline.map(\.bpm))
    let spread = deviation(current.map(\.bpm))
    let baselineSpread = deviation(baseline.map(\.bpm))
    let movement = mean(epochs.map(\.rmsG))
    let rise = clamp((bpm - baselineBPM) / 8)
    let variation = clamp((spread - max(1, baselineSpread)) / 5)
    let stillness = clamp(1 - movement / 0.025)
    let score = 0.35 * rise + 0.40 * variation + 0.25 * stillness
    f.heartRate = bpm; f.heartSpread = spread; f.movement = movement; f.score = score
    let candidate = score >= 0.72 && movement < 0.015 && bpm < 100
    return SensorEvaluation(evidence: REMEvidence(kind: candidate ? .candidate : .unlikely,
      heuristicScore: score, latestSampleAt: last.date,
      explanation: candidate ? "Проверяем устойчивость REM-подобных признаков"
        : "Свежие данные есть · устойчивых REM-признаков пока нет"), features: f)
  }
  private static func mean(_ values: [Double]) -> Double {
    values.reduce(0, +) / Double(max(1, values.count))
  }
  private static func deviation(_ values: [Double]) -> Double {
    let m = mean(values)
    return sqrt(mean(values.map { pow($0 - m, 2) }))
  }
  private static func clamp(_ value: Double) -> Double { max(0, min(1, value)) }
}

public enum ResearchCuePolicy {
  public static func accepts(_ packet: WirePacket, sessionID: UUID, now: Date,
                             processed: [UUID]) -> Bool {
    packet.kind == .researchCue && packet.sessionID == sessionID
      && packet.researchEpisode != nil && packet.episodeID == packet.researchEpisode?.id
      && !processed.contains(packet.id)
      && (-2...15).contains(now.timeIntervalSince(packet.sentAt))
      && packet.cueDate.map { (-2...5).contains($0.timeIntervalSince(now)) } == true
  }
}
