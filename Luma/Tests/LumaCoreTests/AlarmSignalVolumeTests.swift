import Foundation
import XCTest
@testable import LumaCore

final class AlarmSignalVolumeTests: XCTestCase {
  func testMissingOrInvalidLevelsMeanTheQuieterDefault() {
    XCTAssertEqual(AlarmSignalVolume.defaultPercent, 50)
    for value: Int? in [nil, Int.min, -10, 0, 10, 15, 55, 101, 110, Int.max] {
      XCTAssertEqual(AlarmSignalVolume.validated(value), 50)
    }
  }
  func testTheScaleIsTwentyToOneHundredInStepsOfTen() {
    XCTAssertEqual(AlarmSignalVolume.range, 20...100)
    for value in stride(from: 20, through: 100, by: 10) {
      XCTAssertEqual(AlarmSignalVolume.validated(value), value)
    }
  }
  func testFullLevelIsExactlyTheOldSound() {
    XCTAssertEqual(AlarmSignalVolume.gain(100), 1)
    XCTAssertEqual(AlarmSignalVolume.decibels(100), 0)
  }
  func testHalfIsTenDecibelsQuieter() {
    XCTAssertEqual(AlarmSignalVolume.decibels(50), -10, accuracy: 1e-9)
    XCTAssertEqual(AlarmSignalVolume.gain(50), 0.316_227_766, accuracy: 1e-6)
  }
  func testGainRisesWithTheLevelAndNeverClips() {
    var previous = 0.0
    for value in stride(from: 20, through: 100, by: 10) {
      let gain = AlarmSignalVolume.gain(value)
      XCTAssertGreaterThan(gain, previous)
      XCTAssertLessThanOrEqual(gain, 1)
      previous = gain
    }
  }
  func testStoredValueIsReadBackAndBadValuesFallBack() {
    let name = "luma.alarm-volume.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else { return XCTFail("No test defaults") }
    defer { defaults.removePersistentDomain(forName: name) }
    XCTAssertEqual(AlarmSignalVolume.current(defaults), 50)
    defaults.set(80, forKey: AlarmSignalVolume.preferenceKey)
    XCTAssertEqual(AlarmSignalVolume.current(defaults), 80)
    defaults.set(85, forKey: AlarmSignalVolume.preferenceKey)
    XCTAssertEqual(AlarmSignalVolume.current(defaults), 50)
    defaults.set("loud", forKey: AlarmSignalVolume.preferenceKey)
    XCTAssertEqual(AlarmSignalVolume.current(defaults), 50)
  }
}
