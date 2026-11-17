import SwiftUI

/// A strip of one picture repeated side by side that drifts slowly and without end.
/// Used for mist over the Journal's water and for the fog and clouds round the house in Settings.
struct DriftStrip: View {
  let image: String
  /// Width of one copy of the picture on screen.
  let tile: CGFloat
  let width: CGFloat
  let height: CGFloat
  /// Where the first copy begins before any drift.
  var start: CGFloat = 0
  /// Seconds in which the strip travels one tile.
  let duration: Double
  var reverse = false
  let time: TimeInterval

  var body: some View {
    let safeTile: CGFloat = max(8, tile)
    let progress = CGFloat(time.truncatingRemainder(dividingBy: duration) / duration)
    let shift: CGFloat = reverse ? (progress - 1) * safeTile : -progress * safeTile
    let remainder: CGFloat = (start + shift).truncatingRemainder(dividingBy: safeTile)
    // The left edge of the first copy: at the screen's left edge or just before it.
    let first: CGFloat = remainder > 0 ? remainder - safeTile : remainder
    let count: Int = max(1, Int(((width - first) / safeTile).rounded(.up)))
    return ZStack(alignment: .topLeading) {
      ForEach(0..<count, id: \.self) { index in
        Image(image).resizable().interpolation(.medium)
          // Half a point of overlap, so no seam shows between two copies.
          .frame(width: safeTile + 0.5, height: height)
          .offset(x: first + CGFloat(index) * safeTile)
      }
    }
    .frame(width: width, height: height, alignment: .topLeading)
    .clipped()
  }
}

/// The Journal painting: a white stone above still water at night.
/// The stone is the lamp of this screen. Its light swells and falls like a slow breath, the water under it
/// ripples, and two veils of mist drift across. Nothing here reacts to touch.
struct JournalScene: View {
  var isActive = true

  var body: some View {
    // The scene is slow; thirty frames a second are enough for it.
    SceneClock(isActive: isActive, rate: 30) { time, _ in
      JournalArtwork(time: time)
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

enum JournalLayout {
  /// The Journal is drawn for 402 x 874 pt. The painting fills the screen from the top.
  static func scale(_ viewport: AtelierViewport) -> CGFloat { max(viewport.u, viewport.v) }
  /// The stone, in screen points.
  static func stone(_ viewport: AtelierViewport) -> CGPoint {
    let a = scale(viewport)
    return CGPoint(x: (viewport.size.width - 402 * a) / 2 + 309 * a, y: 161 * a)
  }
}

private struct JournalArtwork: View {
  let time: TimeInterval
  @Environment(\.atelierViewport) private var viewport
  @Environment(\.accessibilityReduceMotion) private var reduced

  /// Four waves that never line up, so the breath never repeats itself.
  private var level: Double {
    if reduced { return 0.5 }
    let t: Double = time * 2 * Double.pi
    let slow: Double = 0.27 * sin(t / 4.7)
    let middle: Double = 0.15 * sin(t / 2.9 + 1.7)
    let quick: Double = 0.08 * sin(t / 1.13 + 0.6)
    let tremor: Double = 0.03 * sin(t / 0.41 + 2.2)
    let value: Double = 0.52 + slow + middle + quick + tremor
    return max(0.1, min(1, value))
  }

  var body: some View {
    let a: CGFloat = JournalLayout.scale(viewport)
    let width: CGFloat = viewport.size.width
    let x0: CGFloat = (width - 402 * a) / 2
    let plateHeight: CGFloat = 874 * a
    let plateWidth: CGFloat = plateHeight * 1179 / 2556
    let plate = CGRect(x: (width - plateWidth) / 2, y: 0, width: plateWidth, height: plateHeight)
    let glowHeight: CGFloat = plateHeight * 1320 / 2556
    let light: Double = level
    return ZStack(alignment: .topLeading) {
      Atelier.sky
      Image("JournalPlate").resizable().interpolation(.high)
        .frame(width: plate.width, height: plate.height)
        .offset(x: plate.minX)
      // The same picture with the stone turned up; its opacity is the stone's brightness.
      Image("JournalGlow").resizable().interpolation(.high)
        .frame(width: plate.width, height: glowHeight)
        .mask {
          LinearGradient(stops: [
            .init(color: .black, location: 0), .init(color: .black, location: 0.8),
            .init(color: .clear, location: 1)
          ], startPoint: .top, endPoint: .bottom)
        }
        .opacity(light)
        .offset(x: plate.minX)
      water(scale: a, x0: x0, plate: plate, glowHeight: glowHeight, light: light)
      DriftStrip(image: "JournalMistA", tile: 600 * a, width: width, height: 66 * a,
        start: x0, duration: 84, time: time)
        .mask {
          LinearGradient(stops: [
            .init(color: .black, location: 0), .init(color: .black, location: 0.52),
            .init(color: Color.black.opacity(0.467), location: 0.78),
            .init(color: Color.black.opacity(0.267), location: 1)
          ], startPoint: .leading, endPoint: .trailing)
        }
        .opacity(0.5 * (0.5 + 0.5 * light))
        .blendMode(.screen)
        .offset(y: 158 * a)
      DriftStrip(image: "JournalMistB", tile: 900 * a, width: width, height: 150 * a,
        start: x0, duration: 136, reverse: true, time: time)
        .opacity(0.3 * (0.5 + 0.5 * light))
        .blendMode(.screen)
        .offset(y: 186 * a)
      Circle()
        .fill(RadialGradient(stops: [
          .init(color: Color(hex: 0xE3EBFF).opacity(0.369), location: 0),
          .init(color: Color(hex: 0xC9D8FF).opacity(0.149), location: 0.24),
          .init(color: Color(hex: 0xAAC1FF).opacity(0.059), location: 0.46),
          .init(color: Color(hex: 0xAAC1FF).opacity(0), location: 0.68)
        ], center: .center, startRadius: 0, endRadius: 226.3 * a))
        .frame(width: 320 * a, height: 320 * a)
        .scaleEffect(CGFloat(0.88 + 0.2 * light))
        .opacity(0.1 + 0.8 * light)
        .blendMode(.screen)
        .offset(x: x0 + (309 - 160) * a, y: (158 - 160) * a)
    }
    .frame(width: width, height: viewport.size.height, alignment: .topLeading)
    .clipped()
  }

  /// The water is the picture's own water, drawn again in thin rows; each row is moved sideways a little,
  /// and the movement travels like ripples: the far rows barely stir, the near ones more.
  /// The stone's brighter picture is laid over by the same rule, so the reflection breathes with the stone.
  private func water(scale a: CGFloat, x0: CGFloat, plate: CGRect, glowHeight: CGFloat,
    light: Double) -> some View {
    let region = CGRect(x: x0 + 112 * a, y: 199 * a, width: 290 * a, height: 128 * a)
    let plateInside = CGRect(x: plate.minX - region.minX, y: plate.minY - region.minY,
      width: plate.width, height: plate.height)
    let glowInside = CGRect(x: plateInside.minX, y: plateInside.minY,
      width: plateInside.width, height: glowHeight)
    let still: Bool = reduced
    let moment: Double = time
    return Canvas(opaque: false, rendersAsynchronously: true) {
      (context: inout GraphicsContext, size: CGSize) in
      let plateImage = context.resolve(Image("JournalPlate"))
      let glowImage = context.resolve(Image("JournalGlow"))
      let step: CGFloat = 2
      var y: CGFloat = 0
      while y < size.height {
        let pageY: Double = 199.0 + Double(y / a)
        let depth: Double = max(0, (pageY - 193.0) / 134.0)
        let wave: Double = 0.62 * sin(34.0 * depth.squareRoot() - 1.15 * moment)
          + 0.38 * sin(19.0 * depth + 0.63 * moment + 1.3)
        let shift: CGFloat = still ? 0 : CGFloat((0.2 + 2.5 * depth) * wave) * a
        var row = context
        row.clip(to: Path(CGRect(x: 0, y: y, width: size.width, height: step)))
        row.draw(plateImage, in: plateInside.offsetBy(dx: shift, dy: 0))
        if light > 0.01 {
          row.opacity = light
          row.draw(glowImage, in: glowInside.offsetBy(dx: shift, dy: 0))
        }
        y += step
      }
    }
    .frame(width: region.width, height: region.height)
    .mask {
      LinearGradient(stops: [
        .init(color: .clear, location: 0), .init(color: .black, location: 0.22),
        .init(color: .black, location: 1)
      ], startPoint: .leading, endPoint: .trailing)
    }
    .mask {
      LinearGradient(stops: [
        .init(color: .black, location: 0), .init(color: .black, location: 0.62),
        .init(color: .clear, location: 1)
      ], startPoint: .top, endPoint: .bottom)
    }
    .offset(x: region.minX, y: region.minY)
  }
}
