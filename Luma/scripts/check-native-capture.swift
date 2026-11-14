import CoreGraphics
import Foundation
import ImageIO

let imagePath = CommandLine.arguments[1]
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB) else {
  fatalError("The actual reference capture cannot be decoded")
}
let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
  guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
  context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
  return true
}
guard drawn else { fatalError("Cannot inspect the reference capture") }
var samples = 0
var nonBlack = 0
var warmLight = 0
for y in stride(from: 0, to: height, by: 4) {
  for x in stride(from: 0, to: width, by: 4) {
    let offset = (y * width + x) * 4
    let r = Double(pixels[offset])
    let g = Double(pixels[offset + 1])
    let b = Double(pixels[offset + 2])
    samples += 1
    if max(r, max(g, b)) > 12 { nonBlack += 1 }
    if r > 130 && g > 70 && b < r * 0.65 { warmLight += 1 }
  }
}
let visibleFraction = Double(nonBlack) / Double(samples)
let amberFraction = Double(warmLight) / Double(samples)
let report: [String: Any] = ["source": "actual XCTest screenshot", "width": width,
  "height": height, "visibleFraction": visibleFraction, "amberFraction": amberFraction,
  "blankLaunchScreenRejected": visibleFraction > 0.35 && amberFraction > 0.002]
let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: imagePath).deletingLastPathComponent()
  .appendingPathComponent("capture-content-check.json"))
print(String(decoding: json, as: UTF8.self))
guard visibleFraction > 0.35 && amberFraction > 0.002 else {
  fatalError("Reference capture is blank or the dominant illuminated moon is missing")
}
