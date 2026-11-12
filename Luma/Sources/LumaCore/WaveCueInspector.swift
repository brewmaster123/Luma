import Foundation

public struct WaveCueFacts: Equatable, Sendable {
  public var sampleRate: UInt32
  public var channels: UInt16
  public var bits: UInt16
  public var dataBytes: Int
  public var hasLoopMetadata: Bool
  public var frames: Int { dataBytes / max(1, Int(channels) * Int(bits) / 8) }
  public var isFourSecondCue: Bool {
    sampleRate == 22050 && channels == 1 && bits == 16
      && dataBytes == 176400 && frames == 88200 && !hasLoopMetadata
  }
}

/// Checks the WAV resource itself. Absence of embedded loop markers does NOT
/// prove that AlarmKit won't repeat a sound internally.
public enum WaveCueInspector {
  public static func inspect(_ data: Data) -> WaveCueFacts? {
    let b = Array(data)
    guard b.count >= 44, b.count <= 2 * 1024 * 1024 else { return nil }
    func tag(_ i: Int) -> String { String(bytes: b[i..<(i + 4)], encoding: .ascii) ?? "" }
    func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 {
      UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    guard tag(0) == "RIFF", tag(8) == "WAVE", Int(u32(4)) + 8 == b.count else { return nil }
    var position = 12
    var format: (UInt32, UInt16, UInt16)?
    var dataBytes: Int?
    var loop = false
    while position + 8 <= b.count {
      let name = tag(position), size = Int(u32(position + 4)), body = position + 8
      guard size <= b.count - body else { return nil }
      if name == "fmt " {
        guard format == nil, size >= 16 else { return nil }
        let encoding = u16(body)
        if encoding == 0xFFFE {
          let pcmGUID: [UInt8] = [1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113]
          guard size >= 40, Array(b[(body + 24)..<(body + 40)]) == pcmGUID else { return nil }
        } else if encoding != 1 { return nil }
        let rate = u32(body + 4), channels = u16(body + 2), bits = u16(body + 14)
        let alignment = UInt32(channels) * UInt32(bits) / 8
        guard channels > 0, bits > 0, bits % 8 == 0, alignment > 0,
          UInt32(u16(body + 12)) == alignment,
          UInt64(u32(body + 8)) == UInt64(rate) * UInt64(alignment) else { return nil }
        format = (rate, channels, bits)
      } else if name == "data" {
        guard dataBytes == nil else { return nil }
        dataBytes = size
      } else if name == "smpl" || name == "plst" { loop = true }
      position = body + size + (size & 1)
    }
    guard position == b.count, let format, let dataBytes else { return nil }
    return .init(sampleRate: format.0, channels: format.1, bits: format.2,
      dataBytes: dataBytes, hasLoopMetadata: loop)
  }
}
