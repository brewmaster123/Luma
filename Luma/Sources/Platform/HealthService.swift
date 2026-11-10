import Foundation
import HealthKit

/// Optional completed sleep history for the journal. AlarmKit never waits for it.
final class HealthService {
  private let store = HKHealthStore()
  @MainActor func requestReadAccess() async throws {
    guard HKHealthStore.isHealthDataAvailable() else {
      throw AppError.message("Данные «Здоровья» недоступны на этом устройстве.")
    }
    let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    try await store.requestAuthorization(toShare: [], read: [type])
  }
  func sleepSegments(now: Date) async throws -> [SleepSegment] {
    let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    let predicate = HKQuery.predicateForSamples(
      withStart: now.addingTimeInterval(-36 * 3600), end: now)
    return try await query(type: type, predicate: predicate, limit: 2000).compactMap { sample in
      guard let value = sample as? HKCategorySample, isWatchSample(value) else { return nil }
      let stage: SleepStage
      switch value.value {
      case HKCategoryValueSleepAnalysis.awake.rawValue: stage = .awake
      case HKCategoryValueSleepAnalysis.asleepCore.rawValue: stage = .core
      case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: stage = .deep
      case HKCategoryValueSleepAnalysis.asleepREM.rawValue: stage = .rem
      case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: stage = .unspecified
      default: return nil  // inBed is not a physiological stage.
      }
      return SleepSegment(
        id: value.uuid.uuidString, start: value.startDate, end: value.endDate,
        stage: stage, source: value.sourceRevision.source.bundleIdentifier)
    }.sorted { $0.start < $1.start }
  }
  private func query(type: HKSampleType, predicate: NSPredicate?, limit: Int) async throws
    -> [HKSample]
  {
    try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: type, predicate: predicate, limit: limit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
      ) {
        _, samples, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: samples ?? [])
        }
      }
      store.execute(query)
    }
  }
  private func isWatchSample(_ sample: HKSample) -> Bool {
    (sample.sourceRevision.productType?.hasPrefix("Watch") == true)
      || (sample.device?.model?.localizedCaseInsensitiveContains("watch") == true)
  }
}
