import SwiftUI

/// The Settings painting: a night sky and, at the top right, an attic window with a night-light
/// behind its curtain. The window is the lamp of this screen.
///
/// The page is two sheets of art with the list between them. Behind the list: the sky, far fog,
/// the dusk under the house, a still indigo body of cloud, the house and its window. In front of the list:
/// a veil of mist under the house, a dense bank of cloud, the low cloud that lies over the first card,
/// and the lamp's glow. So the foundation of the house sinks in cloud, the cards slide up under the clouds
/// and never over the house; over the open sky they simply dissolve.
/// The clouds under the house are those of the design `Atelier-Night-Prototype-11`, accepted by the user
/// on 16 Nov 2026 ("эти облака меня устраивают").
/// All measures are in points of the 402 pt wide design and are carried to the screen by `u`.
enum SettingsLamp {
  /// The night-light breathes slowly and deeply: about five and a half seconds, with a longer wave
  /// under it so that no two breaths are alike. Nothing in it is quicker than a second and a half.
  static func level(_ time: TimeInterval, still: Bool) -> Double {
    if still { return 0.6 }
    let t: Double = time * 2 * Double.pi
    let breath: Double = 0.27 * sin(t / 5.6)
    let under: Double = 0.12 * sin(t / 9.1 + 1.2)
    let ripple: Double = 0.045 * sin(t / 1.6 + 0.5)
    let value: Double = 0.55 + breath + under + ripple
    return max(0.1, min(1, value))
  }

  static func point(_ viewport: AtelierViewport) -> CGPoint {
    CGPoint(x: 322 * viewport.u, y: 134 * viewport.u)
  }
}

struct SettingsBackScene: View {
  var isActive = true

  var body: some View {
    SceneClock(isActive: isActive) { time, animate in
      SettingsBackArtwork(time: time, animate: animate)
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

struct SettingsForeScene: View {
  var isActive = true

  var body: some View {
    SceneClock(isActive: isActive, rate: 30) { time, _ in
      SettingsForeArtwork(time: time)
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

private struct SettingsBackArtwork: View {
  let time: TimeInterval
  let animate: Bool
  @Environment(\.atelierViewport) private var viewport
  @Environment(\.accessibilityReduceMotion) private var reduced

  var body: some View {
    let u: CGFloat = viewport.u
    let width: CGFloat = viewport.size.width
    let height: CGFloat = viewport.size.height
    let level: Double = SettingsLamp.level(time, still: reduced)
    return ZStack(alignment: .topLeading) {
      Rectangle().fill(RadialGradient(stops: [
        .init(color: Color(hex: 0x06132A), location: 0),
        .init(color: Color(hex: 0x040D1E), location: 0.52),
        .init(color: Color(hex: 0x020A17), location: 1)
      ], center: UnitPoint(x: 0.62, y: 0), startRadius: 0, endRadius: 0.62 * height))
      sky(scale: u)
      // Far behind the house: large soft banks of cold fog with no edges. The roof stands out against them.
      SettingsRidge(time: time, scale: u, width: width, tile: 640, height: 251, top: 14,
        start: -150, duration: 200, haze: true)
        .mask { SettingsArt.fromLeft(clearUntil: 60, solidFrom: 230) }
        .mask { SettingsArt.toBottom(solidUntil: 0.46, clearFrom: 0.86) }
        .opacity(0.62)
        .offset(y: (10 + 14) * u)
      // A still body of dusk under the house, so that no sky shows where its walls would be.
      Image("SettingsBase").resizable().interpolation(.high)
        .frame(width: width, height: 250 * u)
        .offset(y: 10 * u)
      // Behind the list, under the house: a still, dense body of cloud in the concept's deep indigo
      // (the cards are a shade darker), so no night shows between the clouds of the house and the first
      // card, whatever the drifting banks in front are doing. Being behind the list, it hides no card.
      Rectangle()
        .fill(LinearGradient(colors: [Color(hex: 0x1A1E36), Color(hex: 0x12172A)],
          startPoint: .top, endPoint: .bottom))
        .frame(width: width, height: 70 * u)
        .mask { SettingsArt.fromLeft(clearUntil: 228, solidFrom: 292) }
        .mask { SettingsArt.band(solidFrom: 16 / 70, solidUntil: 54 / 70, clearFrom: 66 / 70) }
        .offset(y: (10 + 186) * u)
      SettingsRidge(time: time, scale: u, width: width, tile: 430, height: 169, top: 128,
        start: 150, duration: 96)
        .mask { SettingsArt.fromLeft(clearUntil: 100, solidFrom: 220) }
        .mask { SettingsArt.toBottom(solidUntil: 0.36, clearFrom: 0.62) }
        .offset(y: (10 + 128) * u)
      // The house exactly as it is painted, in one piece with the clouds round its base:
      // nothing is ever drawn over its roof, its dormer or its window.
      Image("SettingsHouse").resizable().interpolation(.high)
        .frame(width: 216.87 * u, height: 216.87 * u * 356 / 492)
        .offset(x: 185.13 * u, y: (10 + 37.03) * u)
      // The window with the lamp turned up; its opacity is the lamp's brightness.
      Image("SettingsWindowGlow").resizable().interpolation(.high)
        .frame(width: 73.17 * u, height: 79.34 * u)
        .opacity(level)
        .offset(x: 275.05 * u, y: (10 + 74.05) * u)
    }
    .frame(width: width, height: height, alignment: .topLeading)
    .clipped()
  }

  /// A dense sky: most stars high up, thinning towards the cards. Every eighth one sparkles.
  private func sky(scale: CGFloat) -> some View {
    let moment: Double = time
    let moving: Bool = animate
    let still: Bool = reduced
    return Canvas(opaque: false, rendersAsynchronously: true) {
      (context: inout GraphicsContext, _: CGSize) in
      context.scaleBy(x: scale, y: scale)
      for star in NightSkyData.settingsStars {
        let period: Double = star[4]
        let offset: Double = star[5]
        let sparkles: Bool = star[7] > 0.5
        let wave: Double = still ? 0.8 : 0.55 + 0.45 * sin(moment * 6.2832 / period + offset)
        var alpha: Double = star[3] * wave
        if sparkles && !still {
          let flash: Double = pow(max(0, sin(moment * 6.2832 / (period * 2.3) + offset * 2)), 14)
          alpha = min(1, alpha + flash * 0.75)
        }
        let y: Double = star[1]
        let fade: Double = y > 430 ? max(0, 1 - (y - 430) / 270) : 1
        let seen: Double = alpha * fade
        if seen < 0.01 { continue }
        let tint: Color = SettingsSky.tints[min(4, max(0, Int(star[6])))]
        let center = CGPoint(x: star[0], y: y)
        let radius: CGFloat = CGFloat(star[2])
        let shade: GraphicsContext.Shading = .color(tint.opacity(seen))
        context.fill(NightSky.dot(center, radius), with: shade)
        if star[2] > 0.95 {
          let halo: GraphicsContext.Shading = .color(tint.opacity(seen * 0.07))
          context.fill(NightSky.dot(center, radius * 2.3), with: halo)
          if sparkles {
            let reach: CGFloat = radius * CGFloat(2.2 + 2.4 * alpha)
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - reach, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + reach, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - reach))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + reach))
            let ray: GraphicsContext.Shading = .color(tint.opacity(seen * 0.5))
            context.stroke(cross, with: ray, style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
          }
        }
      }
      if moving { SettingsSky.draw(&context, time: moment) }
    }
  }
}

private struct SettingsForeArtwork: View {
  let time: TimeInterval
  @Environment(\.atelierViewport) private var viewport
  @Environment(\.accessibilityReduceMotion) private var reduced

  var body: some View {
    let u: CGFloat = viewport.u
    let width: CGFloat = viewport.size.width
    let level: Double = SettingsLamp.level(time, still: reduced)
    return ZStack(alignment: .topLeading) {
      // A veil of mist under the house: cards that come up here melt into it.
      SettingsDriftBand(image: "SettingsVeilStrip", tile: 640 * u, width: width, height: 52 * u,
        duration: 116, time: time)
        .mask { SettingsArt.fromLeft(clearUntil: 225, solidFrom: 290) }
        .offset(y: (10 + 162) * u)
      // The foundation of the house sinks in dense cloud. First a bank further back: the painted ridge,
      // mirrored, larger and slower, so it reads as a bank of its own. Its mask keeps it below the line
      // where the painted clouds of the house begin; on the right it is opaque down to the low cloud.
      ZStack(alignment: .topLeading) {
        SettingsBand(time: time, scale: u, width: width, cool: "SettingsCloudFillCool",
          warm: "SettingsCloudFillWarm", tile: 600, height: 236, top: 146, duration: 110,
          mirrored: true)
          .offset(y: 146 * u)
      }
      .frame(width: width, height: 250 * u, alignment: .topLeading)
      .mask {
        Image("SettingsFillMask").resizable().interpolation(.high)
          .frame(width: width, height: 250 * u)
      }
      .offset(y: 10 * u)
      // The lowest cloud, the one that lies over the first card while the list scrolls: the near ridge
      // as before (speed, start, warm light from the window), 22 pt lower, with a soft lumpy underside
      // of its own. Only on the right, past the first heading; below, only its lowest wisps are trimmed.
      ZStack(alignment: .topLeading) {
        SettingsBand(time: time, scale: u, width: width, cool: "SettingsCloudLowCool",
          warm: "SettingsCloudLowWarm", tile: 520, height: 204, top: 178, duration: 70)
          .offset(y: 178 * u)
      }
      .frame(width: width, height: 262 * u, alignment: .topLeading)
      .mask { SettingsArt.fromLeft(clearUntil: 225, solidFrom: 290) }
      .mask { SettingsArt.lowCloudFoot }
      .offset(y: 10 * u)
      // The lamp's glow spills out of the window and breathes with it.
      Circle()
        .fill(RadialGradient(stops: [
          .init(color: Color(hex: 0xFFC98A).opacity(0.341), location: 0),
          .init(color: Color(hex: 0xFFAB5C).opacity(0.141), location: 0.22),
          .init(color: Color(hex: 0xFF9A4A).opacity(0.051), location: 0.44),
          .init(color: Color(hex: 0xFF9A4A).opacity(0), location: 0.66)
        ], center: .center, startRadius: 0, endRadius: 148.5 * u))
        .frame(width: 210 * u, height: 210 * u)
        .scaleEffect(CGFloat(0.82 + 0.24 * level))
        .opacity(0.16 + 0.84 * level)
        .blendMode(.screen)
        .offset(x: (322 - 105) * u, y: (10 + 124 - 105) * u)
    }
    .frame(width: width, height: viewport.size.height, alignment: .topLeading)
    .clipped()
  }
}

/// One drifting bank of cloud. Away from the window it is cold night mist; the same bank in its warm
/// colours is laid over it through a round mask centred on the window, so a cloud warms as it drifts
/// into the window's light and cools again as it leaves.
private struct SettingsRidge: View {
  let time: TimeInterval
  let scale: CGFloat
  let width: CGFloat
  let tile: CGFloat
  let height: CGFloat
  let top: CGFloat
  let start: CGFloat
  let duration: Double
  var haze = false

  var body: some View {
    ZStack(alignment: .topLeading) {
      DriftStrip(image: haze ? "SettingsRidgeHaze" : "SettingsRidgeCool", tile: tile * scale,
        width: width, height: height * scale, start: start * scale, duration: duration, time: time)
      if !haze {
        DriftStrip(image: "SettingsRidgeWarm", tile: tile * scale, width: width,
          height: height * scale, start: start * scale, duration: duration, time: time)
          .mask {
            RadialGradient(colors: [.black, .clear],
              center: UnitPoint(x: 312 * scale / max(1, width), y: (118 - top) / height),
              startRadius: 58 * scale, endRadius: 186 * scale)
          }
      }
    }
    .frame(width: width, height: height * scale, alignment: .topLeading)
  }
}

/// A drifting bank of the clouds under the house, drawn from strips laid out once (`SettingsDriftBand`).
/// Like `SettingsRidge`, it is cold night mist away from the window and warm in its light. A mirrored bank
/// drifts the other way round inside the mirror, so on screen it moves with everything else, and its warm
/// circle stays on the window.
private struct SettingsBand: View {
  let time: TimeInterval
  let scale: CGFloat
  let width: CGFloat
  let cool: String
  let warm: String
  let tile: CGFloat
  let height: CGFloat
  let top: CGFloat
  let duration: Double
  var mirrored = false

  var body: some View {
    // The window's light falls at 312 pt; in a mirrored bank that place is drawn at 402 - 312 = 90 pt.
    let lampX: CGFloat = mirrored ? 90 : 312
    let center = UnitPoint(x: lampX * scale / max(1, width), y: (118 - top) / height)
    return ZStack(alignment: .topLeading) {
      SettingsDriftBand(image: cool, tile: tile * scale, width: width, height: height * scale,
        duration: duration, reverse: mirrored, time: time)
      SettingsDriftBand(image: warm, tile: tile * scale, width: width, height: height * scale,
        duration: duration, reverse: mirrored, time: time)
        .mask {
          RadialGradient(colors: [.black, .clear], center: center,
            startRadius: 58 * scale, endRadius: 186 * scale)
        }
    }
    .frame(width: width, height: height * scale, alignment: .topLeading)
    .scaleEffect(x: mirrored ? -1 : 1, y: 1, anchor: .center)
  }
}

/// One picture laid out once for the whole drift: the strip already holds the picture repeated and is as
/// wide as the screen plus one tile. It slides one tile and starts again where it looks the same, so two
/// copies are never joined on screen and no thin line can drift with the clouds (`DriftStrip` sets copies
/// side by side with a little overlap, which can show in the soft, half-clear parts of a cloud).
private struct SettingsDriftBand: View {
  let image: String
  /// How far the picture repeats inside the strip, on screen.
  let tile: CGFloat
  let width: CGFloat
  let height: CGFloat
  /// Seconds in which the strip travels one tile.
  let duration: Double
  var reverse = false
  let time: TimeInterval

  var body: some View {
    let safeTile: CGFloat = max(8, tile)
    let length: Double = max(1, duration)
    let raw: Double = time.truncatingRemainder(dividingBy: length)
    let progress = CGFloat((raw < 0 ? raw + length : raw) / length)
    let shift: CGFloat = reverse ? (progress - 1) * safeTile : -progress * safeTile
    return Image(image).resizable().interpolation(.medium)
      .frame(width: width + safeTile, height: height)
      .offset(x: shift)
      .frame(width: width, height: height, alignment: .topLeading)
      .clipped()
  }
}

private enum SettingsArt {
  /// Clear at the left, solid further right; both in points of the 402 pt design.
  static func fromLeft(clearUntil: CGFloat, solidFrom: CGFloat) -> LinearGradient {
    LinearGradient(stops: [
      .init(color: .clear, location: 0), .init(color: .clear, location: clearUntil / 402),
      .init(color: .black, location: solidFrom / 402), .init(color: .black, location: 1)
    ], startPoint: .leading, endPoint: .trailing)
  }

  /// Clear at the top and at the bottom, solid in between; as fractions of the height.
  static func band(solidFrom: CGFloat, solidUntil: CGFloat, clearFrom: CGFloat) -> LinearGradient {
    let stops: [Gradient.Stop] = [
      Gradient.Stop(color: Color.clear, location: 0),
      Gradient.Stop(color: Color.black, location: solidFrom),
      Gradient.Stop(color: Color.black, location: solidUntil),
      Gradient.Stop(color: Color.clear, location: clearFrom),
      Gradient.Stop(color: Color.clear, location: 1)
    ]
    return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
  }

  /// The foot of the lowest cloud, in its 262 pt box from the top of the house: the cloud ends in a soft
  /// underside of its own, so this only trims its lowest wisps (246...262 pt, page 256...272 pt).
  static var lowCloudFoot: LinearGradient {
    let stops: [Gradient.Stop] = [
      Gradient.Stop(color: Color.black, location: 0),
      Gradient.Stop(color: Color.black, location: 0.9389),               // 246 pt
      Gradient.Stop(color: Color.black.opacity(0.647), location: 0.9618), // 252 pt
      Gradient.Stop(color: Color.black.opacity(0.502), location: 0.9695), // 254 pt
      Gradient.Stop(color: Color.black.opacity(0.106), location: 0.9885), // 259 pt
      Gradient.Stop(color: Color.clear, location: 1)
    ]
    return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
  }

  /// Solid at the top, clear further down; both as fractions of the height.
  static func toBottom(solidUntil: CGFloat, clearFrom: CGFloat) -> LinearGradient {
    LinearGradient(stops: [
      .init(color: .black, location: 0), .init(color: .black, location: solidUntil),
      .init(color: .clear, location: clearFrom), .init(color: .clear, location: 1)
    ], startPoint: .top, endPoint: .bottom)
  }
}

/// Falling stars and comets of the Settings sky.
/// A falling star is never born in open sky: it lights up out of sight, beyond the top, left or right
/// edge of the screen or behind the roof, and comes in already alight. Its trail is never longer than
/// the way it has flown. The sequence is fixed (ten minutes long, then it repeats), so the sky needs
/// no state of its own.
enum SettingsSky {
  static let tints: [Color] = [
    Color(hex: 0xF3C79C), Color(hex: 0xD6DDF4), Color(hex: 0xF4E4C6), Color(hex: 0xC7D1EC),
    Color(hex: 0xFFFFFF)
  ]

  struct Event {
    var comet: Bool
    var at: Double
    var duration: Double
    var x: Double
    var y: Double
    var dx: Double
    var dy: Double
    var tail: Double
    var width: Double
    var alpha: Double
  }

  static let loop: Double = 600
  static let events: [Event] = makeEvents()

  private static func makeEvents() -> [Event] {
    var seed: UInt64 = 20261116
    func random() -> Double {
      seed = (1664525 &* seed &+ 1013904223) & 0xFFFF_FFFF
      return Double(seed) / 4294967296.0
    }
    func meteor(at moment: Double) -> Event {
      let choice: Double = random()
      var x: Double = 0, y: Double = 0, angle: Double = 0, length: Double = 0
      if choice < 0.32 {
        // from above the screen
        x = 20 + random() * 360
        y = -26
        let rightwards: Bool = random() < (x < 200 ? 0.72 : 0.28)
        let slope: Double = 0.6 + random() * 0.4
        angle = rightwards ? slope : Double.pi - slope
        length = 190 + random() * 110
      } else if choice < 0.62 {
        // from beyond the left edge
        x = -26
        y = 10 + random() * 130
        angle = 0.22 + random() * 0.36
        length = 210 + random() * 120
      } else if choice < 0.8 {
        // from beyond the right edge
        x = 428
        y = 4 + random() * 30
        angle = Double.pi - (0.18 + random() * 0.26)
        length = 210 + random() * 110
      } else {
        // from behind the roof, under the tiles above the dormer
        x = 350 + random() * 44
        y = 77 - (x - 316) * 0.3023 + 16 + random() * 12
        angle = Double.pi - (0.07 + random() * 0.17)
        length = 230 + random() * 100
      }
      let speed: Double = 230 + random() * 130
      let tail: Double = 34 + random() * 44
      let width: Double = 0.9 + random() * 0.7
      let alpha: Double = 0.5 + random() * 0.4
      return Event(comet: false, at: moment, duration: length / speed, x: x, y: y,
        dx: cos(angle) * length, dy: sin(angle) * length, tail: tail, width: width, alpha: alpha)
    }
    func comet(at moment: Double) -> Event {
      let fromRight: Bool = random() < 0.5
      let x: Double = fromRight ? 240 + random() * 150 : 10 + random() * 150
      let y: Double = 24 + random() * 120
      let angle: Double = (fromRight ? Double.pi - 0.2 : 0.2) + (random() - 0.5) * 0.3
      let length: Double = 90 + random() * 70
      let duration: Double = 9 + random() * 5
      let tail: Double = 26 + random() * 16
      return Event(comet: true, at: moment, duration: duration, x: x, y: y,
        dx: cos(angle) * length, dy: sin(angle) * length, tail: tail, width: 1, alpha: 0.42)
    }
    var result: [Event] = []
    var moment: Double = 1.2
    while moment < loop - 3 {
      result.append(meteor(at: moment))
      // Now and then a second one follows the first.
      if random() < 0.16 { result.append(meteor(at: moment + 0.18 + random() * 0.3)) }
      moment += 2.4 + random() * 4.4
    }
    moment = 9
    while moment < loop - 16 {
      result.append(comet(at: moment))
      moment += 15 + random() * 17
    }
    return result.sorted { $0.at < $1.at }
  }

  static func draw(_ context: inout GraphicsContext, time: Double) {
    let local: Double = time.truncatingRemainder(dividingBy: loop)
    for event in events {
      if event.at > local { break }
      if local >= event.at + event.duration { continue }
      let k: Double = (local - event.at) / event.duration
      let length: Double = max(1, (event.dx * event.dx + event.dy * event.dy).squareRoot())
      let x: Double = event.x + event.dx * k
      let y: Double = event.y + event.dy * k
      let envelope: Double = event.comet
        ? NightSky.smooth(0, 0.2, k) * (1 - NightSky.smooth(0.78, 1, k))
        : NightSky.smooth(0, 0.06, k) * (1 - NightSky.smooth(0.55, 1, k))
      let tail: Double = event.comet
        ? event.tail : min(event.tail, k * length) * (0.4 + 0.6 * envelope)
      let head = CGPoint(x: x, y: y)
      let from = CGPoint(x: x - event.dx / length * tail, y: y - event.dy / length * tail)
      let bright: Color = event.comet ? Color(hex: 0xDFE6FF) : Color(hex: 0xFFF1D6)
      let faint: Color = event.comet ? Color(hex: 0xDFE6FF).opacity(0) : Color(hex: 0xFBE6C3).opacity(0)
      let spark: Color = event.comet ? Color(hex: 0xEEF1FF) : Color(hex: 0xFFF6E4)
      var trail = Path()
      trail.move(to: from)
      trail.addLine(to: head)
      var line = context
      line.opacity = event.alpha * envelope
      let gradient = Gradient(colors: [faint, bright])
      let shade: GraphicsContext.Shading = .linearGradient(gradient, startPoint: from, endPoint: head)
      line.stroke(trail, with: shade,
        style: StrokeStyle(lineWidth: CGFloat(event.width), lineCap: .round))
      var dot = context
      dot.opacity = (event.comet ? 0.75 : 0.9) * envelope
      dot.fill(NightSky.dot(head, CGFloat(event.comet ? 1 : event.width * 0.75)), with: .color(spark))
      var glow = context
      glow.opacity = (event.comet ? 0.2 : 0.16) * envelope
      glow.fill(NightSky.dot(head, CGFloat(event.comet ? 3.4 : event.width * 3)), with: .color(spark))
    }
  }
}
