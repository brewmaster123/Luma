import Foundation
import XCTest
@testable import LumaCore

final class WaveCueInspectorTests: XCTestCase {
  private func wave(frames: Int = 88200, channels: UInt16 = 1,
    extra: String? = nil) -> Data {
    var body = Data("WAVEfmt ".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { body.append(contentsOf: $0) }
    }
    append(UInt32(16)); append(UInt16(1)); append(channels)
    append(UInt32(22050)); append(UInt32(22050) * UInt32(channels) * 2)
    append(channels * 2); append(UInt16(16))
    if let extra { body.append(Data(extra.utf8)); append(UInt32(4)); append(UInt32(0)) }
    body.append(Data("data".utf8)); append(UInt32(frames) * UInt32(channels) * 2)
    body.append(Data(repeating: 0, count: frames * Int(channels) * 2))
    var result = Data("RIFF".utf8), size = UInt32(body.count).littleEndian
    withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
    result.append(body)
    return result
  }
  func testExactlyFourSecondsOfMonoPCMIsAccepted() throws {
    let facts = try XCTUnwrap(WaveCueInspector.inspect(wave()))
    XCTAssertEqual(facts.frames, 88200)
    XCTAssertEqual(facts.dataBytes, 176400)
    XCTAssertTrue(facts.isFourSecondCue)
  }
  func testLongShortAndStereoFilesAreRejectedAsCueAssets() throws {
    for input in [wave(frames: 88201), wave(frames: 44100), wave(channels: 2)] {
      XCTAssertFalse(try XCTUnwrap(WaveCueInspector.inspect(input)).isFourSecondCue)
    }
  }
  func testSamplerAndPlaylistChunksRejectEmbeddedRepetition() throws {
    for name in ["smpl", "plst"] {
      let facts = try XCTUnwrap(WaveCueInspector.inspect(wave(extra: name)))
      XCTAssertTrue(facts.hasLoopMetadata)
      XCTAssertFalse(facts.isFourSecondCue)
    }
  }
  func testMalformedOrTruncatedRIFFIsRejected() {
    let original = wave()
    XCTAssertNil(WaveCueInspector.inspect(Data(original.dropLast())))
    XCTAssertNil(WaveCueInspector.inspect(Data("not a WAV".utf8)))
    var damaged = original; damaged[20] = 3 // IEEE Float is not PCM16.
    XCTAssertNil(WaveCueInspector.inspect(damaged))
    var invalidAlignment = original; invalidAlignment[32] = 4
    XCTAssertNil(WaveCueInspector.inspect(invalidAlignment))
  }
  func testBundledAlarmSoundHasExactlyFourSecondsAndNoLoopChunks() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Resources/luma-alarm-4.wav"))
    XCTAssertTrue(try XCTUnwrap(WaveCueInspector.inspect(data)).isFourSecondCue)
    // This tests the file, not whether the system repeats it on an iPhone.
    XCTAssertFalse(LumaFeatures.alarmKitWaveEOFDeviceVerified)
  }
}
