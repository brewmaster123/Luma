import Foundation

public enum AcousticFeatures {
  public static func extract(envelope: [Double], start: Date, end: Date) -> AudioEpoch? {
    guard (550...650).contains(envelope.count), envelope.allSatisfy({ $0.isFinite && $0 >= 0 }),
      (55...65).contains(end.timeIntervalSince(start))
    else { return nil }
    let mean = envelope.reduce(0, +) / Double(envelope.count)
    let x = envelope.map { $0 - mean }
    var best = 0.0
    var bestLag = 0
    if x.reduce(0, { $0 + $1 * $1 }) > 1e-12 {
      for lag in 20...100 {
        var cross = 0.0
        var left = 0.0
        var right = 0.0
        for i in lag..<x.count {
          cross += x[i] * x[i - lag]
          left += x[i] * x[i]
          right += x[i - lag] * x[i - lag]
        }
        let score = cross / max(1e-12, sqrt(left * right))
        if score > best {
          best = score
          bestLag = lag
        }
      }
    }
    let median = envelope.sorted()[envelope.count / 2]
    let spikes =
      Double(envelope.filter { $0 > max(0.01, median * 4) }.count) / Double(envelope.count)
    return AudioEpoch(
      start: start, end: end, levelDB: 20 * log10(max(1e-7, mean)), transientFraction: spikes,
      breathingProxy: best >= 0.45 && bestLag > 0 ? 600 / Double(bestLag) : nil,
      periodicity: min(1, max(0, best)))
  }
}
