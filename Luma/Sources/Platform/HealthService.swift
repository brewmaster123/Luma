import Foundation
import HealthKit

final class HealthService {
  private let store = HKHealthStore()
  private var observer: HKObserverQuery?
  var onChange: (@MainActor () async -> Void)?
  static var available: Bool { HKHealthStore.isHealthDataAvailable() }
  enum ReadRequestState { case needed, handled, unavailable, unknown }
  private var readTypes: Set<HKObjectType> {
    [HKObjectType.quantityType(forIdentifier: .heartRate)!,
     HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
     HKObjectType.quantityType(forIdentifier: .respiratoryRate)!]
  }

  /// This describes whether a sheet is needed, never whether reading was allowed.
  @MainActor func readRequestState() async throws -> ReadRequestState {
    guard Self.available else { return .unavailable }
    let status = try await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
    switch status {
    case .shouldRequest: return .needed
    case .unnecessary: return .handled
    case .unknown: return .unknown
    @unknown default: return .unknown
    }
  }

  @MainActor func requestReadAccess() async throws {
    guard Self.available else {
      throw AppError.message("Данные «Здоровья» недоступны на этом устройстве.")
    }
    let types = readTypes
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      store.requestAuthorization(toShare: [], read: types) { success, error in
        if let error {
          continuation.resume(throwing: error)
        } else if success {
          continuation.resume()
        } else {
          continuation.resume(throwing: AppError.message("Запрос доступа не завершён."))
        }
      }
    }
    // HealthKit deliberately does not reveal whether read authorization was granted.
  }

  func heartSamples(now: Date) async throws -> [HeartSample] {
    let type = HKObjectType.quantityType(forIdentifier: .heartRate)!
    let predicate = HKQuery.predicateForSamples(
      withStart: now.addingTimeInterval(-3600), end: now,
      options: [.strictStartDate, .strictEndDate])
    let samples = try await query(type: type, predicate: predicate, limit: 1500)
    let unit = HKUnit.count().unitDivided(by: .minute())
    return samples.compactMap { sample in
      guard let value = sample as? HKQuantitySample,
        value.metadata?[HKMetadataKeyWasUserEntered] as? Bool != true,
        isWatchSample(value)
      else { return nil }
      let bpm = value.quantity.doubleValue(for: unit)
      return HeartSample(
        date: value.endDate, bpm: bpm,
        source: value.sourceRevision.source.bundleIdentifier + "/"
          + (value.sourceRevision.productType ?? value.device?.model ?? "watch"))
    }
  }

  func breathSamples(now: Date) async throws -> [BreathSample] {
    let type = HKObjectType.quantityType(forIdentifier: .respiratoryRate)!
    let predicate = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-3600), end: now)
    let unit = HKUnit.count().unitDivided(by: .minute())
    return try await query(type: type, predicate: predicate, limit: 1000).compactMap { sample in
      guard let value = sample as? HKQuantitySample, isWatchSample(value),
        value.metadata?[HKMetadataKeyWasUserEntered] as? Bool != true
      else { return nil }
      return BreathSample(date: value.endDate, perMinute: value.quantity.doubleValue(for: unit))
    }
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

  @MainActor func beginObserving() async throws {
    guard Self.available else { return }
    let type = HKObjectType.quantityType(forIdentifier: .heartRate)!
    if observer == nil {
      let query = HKObserverQuery(sampleType: type, predicate: nil) {
        [weak self] _, completion, error in
        guard error == nil else {
          completion()
          return
        }
        Task { @MainActor in
          await self?.onChange?()
          completion()  // Acknowledge even when no readable samples exist.
        }
      }
      observer = query
      store.execute(query)
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      store.enableBackgroundDelivery(for: type, frequency: .hourly) { success, error in
        if let error {
          continuation.resume(throwing: error)
        } else if success {
          continuation.resume()
        } else {
          continuation.resume(
            throwing: AppError.message("Фоновые обновления «Здоровья» недоступны."))
        }
      }
    }
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
