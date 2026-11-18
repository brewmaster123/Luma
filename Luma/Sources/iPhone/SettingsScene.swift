import SwiftUI

/// The Settings painting since 0.9.9: a night forest under an old tree, with a lantern hanging from its
/// branch. It is the user's own concept (18 Nov 2026), without its title and its panels: the cards of
/// Settings stay exactly as they were, only the world behind them is new. The picture was cut into the
/// parts that live (see Design Experiments/Settings-Forest-Concept and the forest notes in the docs).
///
/// Behind the list: the still picture, mist drifting between the trees and over the bridge, the leaves
/// of the canopy stirring, the lantern swinging gently on its chain, its light breathing over the leaves,
/// the trunk and the moss, a slow wave of light running up the glowing vines, the lamps on the bridge,
/// fireflies. When the list is scrolled the forest follows it by a little, as a far layer does.
/// In front of the list: the forest floor with ferns and flowers, into which the cards sink, low mist over it,
/// and a few fireflies close by. Behind the first heading there is no haze at all (the user, 18 Nov 2026, evening);
/// the middle of the picture, behind the cards, is layered undergrowth in mist from the user's second picture.
/// Nothing moves quicker than about a second and a half, and nothing moves while "Reduce Motion" is on.
/// All measures are in points of the 402 x 874 pt design and are carried to the screen by `u`.
enum SettingsLamp {
  /// The lantern breathes slowly and deeply: about five and a half seconds, with a longer wave
  /// under it so that no two breaths are alike. Nothing in it is quicker than a second and a half.
  /// (The curve of the approved Settings lamp, kept as it was.)
  static func level(_ time: TimeInterval, still: Bool) -> Double {
    if still { return 0.6 }
    let t: Double = time * 2 * Double.pi
    let breath: Double = 0.27 * sin(t / 5.6)
    let under: Double = 0.12 * sin(t / 9.1 + 1.2)
    let ripple: Double = 0.045 * sin(t / 1.6 + 0.5)
    let value: Double = 0.55 + breath + under + ripple
    return max(0.1, min(1, value))
  }

  /// The lantern's glass: the light that the cards catch comes from here.
  static func point(_ viewport: AtelierViewport) -> CGPoint {
    CGPoint(x: Forest.glass.x * viewport.u, y: Forest.glass.y * viewport.u)
  }
}

/// How far the Settings list has been scrolled. The forest behind it follows by a fraction.
/// Only the back scene watches it, so scrolling redraws nothing else.
final class ForestDepth: ObservableObject {
  @Published var scrolled: CGFloat = 0
}

/// Where the parts of the forest are, in points of the design (from forest-layout.json).
enum Forest {
  struct Piece {
    let image: String
    let frame: CGRect
    let anchor: UnitPoint
  }

  static let plateHeight: CGFloat = 874.06
  static let lantern = Piece(image: "ForestLantern", frame: CGRect(x: 250.34, y: 46.14, width: 44.43, height: 103.38),
    anchor: UnitPoint(x: 0.5128, y: 0.0386))
  static let pivot = CGPoint(x: 273.13, y: 50.13)
  static let glass = CGPoint(x: 273.41, y: 112.5)
  static let leaves: [Piece] = [
    Piece(image: "ForestLeavesA", frame: CGRect(x: 64.08, y: 0, width: 79.03, height: 91.85),
      anchor: UnitPoint(x: 0.8108, y: 0)),
    Piece(image: "ForestLeavesB", frame: CGRect(x: 140.98, y: 0, width: 59.81, height: 100.39),
      anchor: UnitPoint(x: 0.6429, y: 0)),
    Piece(image: "ForestLeavesC", frame: CGRect(x: 198.65, y: 0, width: 57.67, height: 85.44),
      anchor: UnitPoint(x: 0.4074, y: 0))
  ]
  /// The flowers of the two lower corners; their frames are measured from the bottom of the design.
  static let flowers: [Piece] = [
    Piece(image: "ForestFlowersL", frame: CGRect(x: 0, y: 874.06 - 678.83, width: 64.08, height: 130.3),
      anchor: UnitPoint(x: 0.2667, y: 1.0328)),
    Piece(image: "ForestFlowersR", frame: CGRect(x: 324.68, y: 874.06 - 702.33, width: 77.32, height: 123.89),
      anchor: UnitPoint(x: 0.7735, y: 1.0345))
  ]
  static let lightHeight: CGFloat = 239.23
  static let foreHeight: CGFloat = 163.19
  static let mistTile: CGFloat = 804
  static let bridgeLamps: [CGPoint] = [
    CGPoint(x: 163.9, y: 106.4), CGPoint(x: 176.6, y: 108.0), CGPoint(x: 194.6, y: 112.6), CGPoint(x: 216.8, y: 119.1)
  ]

  /// One firefly: where it lives, how far and how slowly it wanders, how it glows.
  struct Firefly {
    let x: Double, y: Double, rx: Double, ry: Double, period: Double, phase: Double, blink: Double, size: Double
  }

  /// Fireflies behind the cards: round the tree and the bridge, and along both sides of the list.
  static let backFlies: [Firefly] = [
    Firefly(x: 58, y: 142, rx: 14, ry: 9, period: 11.3, phase: 0.2, blink: 4.1, size: 1.0),
    Firefly(x: 118, y: 92, rx: 10, ry: 7, period: 13.7, phase: 1.9, blink: 5.3, size: 0.8),
    Firefly(x: 206, y: 150, rx: 16, ry: 8, period: 9.8, phase: 3.1, blink: 3.7, size: 0.9),
    Firefly(x: 236, y: 62, rx: 9, ry: 11, period: 12.4, phase: 4.4, blink: 4.8, size: 0.75),
    Firefly(x: 318, y: 172, rx: 12, ry: 7, period: 10.6, phase: 5.2, blink: 4.4, size: 1.0),
    Firefly(x: 352, y: 138, rx: 8, ry: 10, period: 14.9, phase: 0.9, blink: 6.0, size: 0.85),
    Firefly(x: 150, y: 196, rx: 18, ry: 6, period: 12.9, phase: 2.6, blink: 5.6, size: 0.9),
    Firefly(x: 92, y: 218, rx: 12, ry: 8, period: 15.6, phase: 3.8, blink: 4.9, size: 0.8),
    Firefly(x: 12, y: 332, rx: 7, ry: 16, period: 13.1, phase: 1.4, blink: 5.1, size: 0.9),
    Firefly(x: 391, y: 300, rx: 7, ry: 14, period: 11.8, phase: 4.9, blink: 4.6, size: 0.95),
    Firefly(x: 9, y: 486, rx: 6, ry: 18, period: 16.2, phase: 0.5, blink: 6.4, size: 0.8),
    Firefly(x: 393, y: 528, rx: 6, ry: 15, period: 12.2, phase: 2.2, blink: 5.0, size: 0.9),
    Firefly(x: 13, y: 626, rx: 7, ry: 12, period: 14.4, phase: 3.3, blink: 4.2, size: 0.85),
    Firefly(x: 389, y: 664, rx: 8, ry: 12, period: 10.9, phase: 5.8, blink: 5.7, size: 0.9)
  ]

  /// Fireflies in front, over the forest floor; `y` is measured from the bottom of the design.
  static let foreFlies: [Firefly] = [
    Firefly(x: 44, y: 120, rx: 16, ry: 10, period: 12.7, phase: 0.7, blink: 4.7, size: 1.15),
    Firefly(x: 128, y: 96, rx: 20, ry: 8, period: 15.1, phase: 2.9, blink: 5.9, size: 0.9),
    Firefly(x: 232, y: 108, rx: 18, ry: 9, period: 13.8, phase: 4.1, blink: 5.2, size: 1.0),
    Firefly(x: 300, y: 134, rx: 14, ry: 10, period: 11.4, phase: 1.6, blink: 4.3, size: 0.95),
    Firefly(x: 370, y: 98, rx: 12, ry: 9, period: 16.4, phase: 5.4, blink: 6.2, size: 1.1)
  ]

  static func smoothWave(_ time: Double, _ period: Double, _ phase: Double) -> Double {
    sin(time * 2 * Double.pi / period + phase)
  }

  /// Draws fireflies: a warm core and a soft halo; each wanders on its own slow figure and glows
  /// up and down on its own breath.
  static func draw(_ flies: [Firefly], in context: inout GraphicsContext, time: Double, scale: CGFloat,
    originY: CGFloat, fromBottom: Bool, height: CGFloat, still: Bool) {
    for fly in flies {
      let wanderX: Double = still ? 0 : fly.rx * smoothWave(time, fly.period, fly.phase)
      let wanderY: Double = still ? 0 : fly.ry * smoothWave(time, fly.period * 1.37, fly.phase * 1.7)
      let pulse: Double = still ? 0.6 : pow(max(0, 0.5 + 0.5 * smoothWave(time, fly.blink, fly.phase * 2.3)), 1.8)
      let glowing: Double = 0.18 + 0.82 * pulse
      let x = CGFloat(fly.x + wanderX) * scale
      let yDesign = CGFloat(fly.y + wanderY) * scale
      let y = fromBottom ? height - yDesign : originY + yDesign
      let center = CGPoint(x: x, y: y)
      let size = CGFloat(fly.size) * scale
      let halo = 9 * size
      context.fill(Path(ellipseIn: CGRect(x: x - halo, y: y - halo, width: 2 * halo, height: 2 * halo)),
        with: .radialGradient(Gradient(colors: [Color(hex: 0xFFC56A).opacity(0.30 * glowing),
          Color(hex: 0xFFB04E).opacity(0.10 * glowing), Color(hex: 0xFFB04E).opacity(0)]),
          center: center, startRadius: 0, endRadius: halo))
      let core = 1.25 * size
      context.fill(Path(ellipseIn: CGRect(x: x - core, y: y - core, width: 2 * core, height: 2 * core)),
        with: .color(Color(hex: 0xFFE9B0).opacity(0.92 * glowing)))
    }
  }
}

struct SettingsBackScene: View {
  var isActive = true
  var depth: ForestDepth? = nil

  var body: some View {
    SceneClock(isActive: isActive) { time, animate in
      ForestBackArtwork(time: time, animate: animate, depth: depth ?? ForestDepth.still)
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

struct SettingsForeScene: View {
  var isActive = true

  var body: some View {
    SceneClock(isActive: isActive, rate: 30) { time, _ in
      ForestForeArtwork(time: time)
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

extension ForestDepth {
  /// For a scene with no list in front of it.
  static let still = ForestDepth()
}

private struct ForestBackArtwork: View {
  let time: TimeInterval
  let animate: Bool
  @ObservedObject var depth: ForestDepth
  @Environment(\.atelierViewport) private var viewport
  @Environment(\.accessibilityReduceMotion) private var reduced

  var body: some View {
    let u: CGFloat = viewport.u
    let width: CGFloat = viewport.size.width
    let height: CGFloat = viewport.size.height
    let still: Bool = reduced
    let level: Double = SettingsLamp.level(time, still: still)
    // The forest follows the list by a twentieth of its travel, at most 16 pt: a far layer.
    let lift: CGFloat = still ? 0 : -min(16, max(0, depth.scrolled) * 0.05) * u
    let swing: Double = still ? 0 : 1.05 * Forest.smoothWave(time, 6.8, 0) + 0.3 * Forest.smoothWave(time, 3.1, 1.1)
    return ZStack(alignment: .topLeading) {
      Color(hex: 0x070D14)
      ZStack(alignment: .topLeading) {
        Image("ForestPlate").resizable().interpolation(.high)
          .frame(width: 402 * u, height: Forest.plateHeight * u)
        // Mist between the trees and over the bridge, drifting slowly to the left. It stays above the first
        // heading (218 pt): no haze may lie behind the text (the user, 18 Nov 2026, evening).
        ForestMistBand(time: time, scale: u, width: width, height: 64, duration: 170, reverse: false)
          .opacity(0.20)
          .offset(y: 112 * u)
        // The canopy stirs: three clusters, each on its own breath of air, hinged on the branch.
        ForEach(Array(Forest.leaves.enumerated()), id: \.offset) { index, piece in
          let k = Double(index)
          let angle: Double = still ? 0
            : 0.85 * Forest.smoothWave(time, 5.3 + 0.8 * k, 0.2 + 1.6 * k) + 0.28 * Forest.smoothWave(time, 2.3 + 0.4 * k, 1 + k)
          ForestPieceView(piece: piece, scale: u, angle: angle)
        }
        // What glows by itself: the vines on the trunk and the mushrooms. A slow wave of light
        // runs up the vines, about once every seven seconds.
        Image("ForestVines").resizable().interpolation(.high)
          .frame(width: 402 * u, height: Forest.lightHeight * u)
          .blendMode(.screen)
          .opacity(0.26 + 0.12 * level)
        if !still {
          Image("ForestVines").resizable().interpolation(.high)
            .frame(width: 402 * u, height: Forest.lightHeight * u)
            .mask(alignment: .topLeading) { vineWave(u: u) }
            .blendMode(.screen)
            .opacity(0.55)
        }
        // The lantern's light on the leaves, the trunk and the moss breathes with it.
        Image("ForestLight").resizable().interpolation(.high)
          .frame(width: 402 * u, height: Forest.lightHeight * u)
          .blendMode(.screen)
          .opacity(0.14 + 0.5 * level)
        lamps(u: u, still: still)
        // A wide halo round the lantern, then the lantern on its chain, then the bloom of its glass.
        let glass = swungGlass(swing)
        // The halo ends above the first heading, so the heading never stands in a warm haze.
        halo(at: glass, radius: 100 * u, strength: 0.10 + 0.30 * level)
        ForestPieceView(piece: Forest.lantern, scale: u, angle: swing)
        bloom(at: glass, radius: 30 * u, strength: 0.22 + 0.4 * level)
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
          Forest.draw(Forest.backFlies, in: &context, time: time, scale: u, originY: 0, fromBottom: false,
            height: size.height, still: still)
        }
        .frame(width: 402 * u, height: Forest.plateHeight * u)
      }
      .offset(y: lift)
    }
    .frame(width: width, height: height, alignment: .topLeading)
    .clipped()
  }

  /// A band of light that climbs the trunk: clear, then bright, then clear again.
  private func vineWave(u: CGFloat) -> some View {
    let period: Double = 7.2
    let raw: Double = time.truncatingRemainder(dividingBy: period) / period
    let band: CGFloat = 110 * u
    let travel: CGFloat = Forest.lightHeight * u + band
    let y: CGFloat = Forest.lightHeight * u - CGFloat(raw) * travel
    return LinearGradient(stops: [
      .init(color: .clear, location: 0), .init(color: .black, location: 0.5), .init(color: .clear, location: 1)
    ], startPoint: .top, endPoint: .bottom)
    .frame(width: 402 * u, height: band)
    .offset(y: y)
  }

  /// The little lamps on the far bridge: each glows on its own slow breath.
  private func lamps(u: CGFloat, still: Bool) -> some View {
    let moment: Double = time
    return Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
      for (index, lamp) in Forest.bridgeLamps.enumerated() {
        let k = Double(index)
        let glow: Double = still ? 0.6 : 0.55 + 0.45 * Forest.smoothWave(moment, 2.9 + 0.7 * k, 1.3 * k)
        let center = CGPoint(x: lamp.x * u, y: lamp.y * u)
        let radius: CGFloat = 6.5 * u
        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
          with: .radialGradient(Gradient(colors: [Color(hex: 0xFFC879).opacity(0.34 * glow),
            Color(hex: 0xFFA64D).opacity(0)]), center: center, startRadius: 0, endRadius: radius))
      }
    }
    .frame(width: 402 * u, height: Forest.lightHeight * u)
    .blendMode(.screen)
  }

  /// Where the lantern's glass is when the lantern has swung by `angle` degrees about its hook.
  private func swungGlass(_ angle: Double) -> CGPoint {
    let radians: Double = angle * Double.pi / 180
    let dx: Double = Double(Forest.glass.x - Forest.pivot.x)
    let dy: Double = Double(Forest.glass.y - Forest.pivot.y)
    return CGPoint(x: Forest.pivot.x + CGFloat(dx * cos(radians) - dy * sin(radians)),
      y: Forest.pivot.y + CGFloat(dx * sin(radians) + dy * cos(radians)))
  }

  private func halo(at point: CGPoint, radius: CGFloat, strength: Double) -> some View {
    let u: CGFloat = viewport.u
    return Circle()
      .fill(RadialGradient(stops: [
        .init(color: Color(hex: 0xFFC98A).opacity(0.55), location: 0),
        .init(color: Color(hex: 0xFFAB5C).opacity(0.22), location: 0.3),
        .init(color: Color(hex: 0xFF9A4A).opacity(0.07), location: 0.62),
        .init(color: Color(hex: 0xFF9A4A).opacity(0), location: 1)
      ], center: .center, startRadius: 0, endRadius: radius))
      .frame(width: 2 * radius, height: 2 * radius)
      .opacity(strength)
      .blendMode(.screen)
      .offset(x: point.x * u - radius, y: point.y * u - radius)
  }

  private func bloom(at point: CGPoint, radius: CGFloat, strength: Double) -> some View {
    let u: CGFloat = viewport.u
    return Circle()
      .fill(RadialGradient(stops: [
        .init(color: Color(hex: 0xFFF1C9).opacity(0.9), location: 0),
        .init(color: Color(hex: 0xFFC77E).opacity(0.38), location: 0.35),
        .init(color: Color(hex: 0xFFA552).opacity(0), location: 1)
      ], center: .center, startRadius: 0, endRadius: radius))
      .frame(width: 2 * radius, height: 2 * radius)
      .opacity(strength)
      .blendMode(.screen)
      .offset(x: point.x * u - radius, y: point.y * u - radius)
  }
}

private struct ForestForeArtwork: View {
  let time: TimeInterval
  @Environment(\.atelierViewport) private var viewport
  @Environment(\.accessibilityReduceMotion) private var reduced

  var body: some View {
    let u: CGFloat = viewport.u
    let width: CGFloat = viewport.size.width
    let height: CGFloat = viewport.size.height
    let still: Bool = reduced
    return ZStack(alignment: .topLeading) {
      // The forest floor, held to the bottom of the screen: the list ends inside it.
      Image("ForestFore").resizable().interpolation(.high)
        .frame(width: 402 * u, height: Forest.foreHeight * u)
        .offset(y: height - Forest.foreHeight * u)
      // Low mist over the floor.
      ForestMistBand(time: time, scale: u, width: width, height: 80, duration: 150, reverse: false)
        .opacity(0.30)
        .offset(y: height - 150 * u)
      // The flowers and ferns of the two corners nod on their stems.
      ForEach(Array(Forest.flowers.enumerated()), id: \.offset) { index, piece in
        let k = Double(index)
        let angle: Double = still ? 0
          : 1.1 * Forest.smoothWave(time, 6.3 + 1.1 * k, 0.6 + 2.1 * k) + 0.35 * Forest.smoothWave(time, 2.6 + 0.5 * k, k)
        ForestPieceView(piece: piece, scale: u, angle: angle, fromBottom: height)
      }
      Canvas(opaque: false, rendersAsynchronously: true) { context, size in
        Forest.draw(Forest.foreFlies, in: &context, time: time, scale: u, originY: 0, fromBottom: true,
          height: size.height, still: still)
      }
      .frame(width: width, height: height)
    }
    .frame(width: width, height: height, alignment: .topLeading)
    .clipped()
  }
}

/// One moving part of the forest, in its place, turned by `angle` degrees about its hinge.
/// With `fromBottom` its frame is measured from the bottom of the screen (the forest floor).
private struct ForestPieceView: View {
  let piece: Forest.Piece
  let scale: CGFloat
  let angle: Double
  var fromBottom: CGFloat? = nil

  var body: some View {
    let y: CGFloat = fromBottom.map { $0 - piece.frame.minY * scale } ?? piece.frame.minY * scale
    return Image(piece.image).resizable().interpolation(.high)
      .frame(width: piece.frame.width * scale, height: piece.frame.height * scale)
      .rotationEffect(.degrees(angle), anchor: piece.anchor)
      .offset(x: piece.frame.minX * scale, y: y)
  }
}

/// A band of mist that drifts sideways. The mist picture tiles seamlessly, so two copies side by side
/// slide by one tile and start again where it looks the same.
private struct ForestMistBand: View {
  let time: TimeInterval
  let scale: CGFloat
  let width: CGFloat
  /// Height in points of the design.
  let height: CGFloat
  /// Seconds in which the mist travels one tile.
  let duration: Double
  var reverse = false

  var body: some View {
    let tile: CGFloat = Forest.mistTile * scale
    let length: Double = max(1, duration)
    let raw: Double = time.truncatingRemainder(dividingBy: length)
    let progress = CGFloat((raw < 0 ? raw + length : raw) / length)
    let shift: CGFloat = reverse ? (progress - 1) * tile : -progress * tile
    return HStack(spacing: 0) {
      Image("ForestMist").resizable().interpolation(.medium)
        .frame(width: tile, height: height * scale)
      Image("ForestMist").resizable().interpolation(.medium)
        .frame(width: tile, height: height * scale)
    }
    .offset(x: shift)
    .frame(width: width, height: height * scale, alignment: .topLeading)
    .clipped()
  }
}
