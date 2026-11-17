import Combine
import SwiftUI

/// Gives a decorative scene its clock. The clock stands still while the scene is hidden, the app is
/// in the background or "Reduce Motion" is on, and goes on from the same moment afterwards.
/// Only the scene inside redraws at the animation rate; controls and lists do not.
struct SceneClock<Content: View>: View {
  var isActive: Bool
  /// Frames per second the scene asks for; slow scenes ask for fewer.
  var rate: Double = 60
  let content: (TimeInterval, Bool) -> Content
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visible = false
  @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
  @State private var ticking = false
  @State private var clockOrigin = Date()
  @State private var heldTime: TimeInterval = 0

  init(isActive: Bool, rate: Double = 60,
    @ViewBuilder content: @escaping (TimeInterval, Bool) -> Content) {
    self.isActive = isActive
    self.rate = rate
    self.content = content
  }

  private var shouldAnimate: Bool {
    isActive && visible && scenePhase == .active && !reduceMotion
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / (lowPower ? min(30.0, rate) : rate),
      paused: !shouldAnimate)) { timeline in
      let elapsed = heldTime + (ticking
        ? max(0, timeline.date.timeIntervalSince(clockOrigin)) : 0)
      content(elapsed, shouldAnimate)
    }
    .onAppear { visible = true; setTicking(shouldAnimate) }
    .onDisappear { setTicking(false); visible = false }
    .onChange(of: shouldAnimate) { _, running in setTicking(running) }
    // The system may post this notice on any thread; the state is changed on the main one.
    .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
      .receive(on: DispatchQueue.main)) { _ in
      lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
  }

  private func setTicking(_ running: Bool) {
    guard running != ticking else { return }
    let now = Date()
    if running { clockOrigin = now }
    else { heldTime += max(0, now.timeIntervalSince(clockOrigin)) }
    ticking = running
  }
}

/// The Night painting: backdrop, stars, two cloud layers and the moon on its chain with its glow.
/// The moon's art, size, glow and swing (±1.5°, 11.2 s) are those of the approved design and are not to be changed.
struct NightScene: View {
  var isActive = true

  var body: some View {
    SceneClock(isActive: isActive) { time, animate in
      NightArtwork(time: time, animate: animate)
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

private struct NightArtwork: View {
  let time: TimeInterval
  let animate: Bool
  private var moonAngle: Double { 1.5 * sin(time * 2 * .pi / 11.2) }
  /// Lamp breathing: three slow waves, never a blink.
  /// The moon dims by at most 3 %, its glow by at most 4.4 %.
  private var breath: Double {
    // Written in steps so that the compiler has nothing to puzzle over; the values are the same.
    let turn: Double = 2 * Double.pi * time
    let slow: Double = 0.55 * cos(turn / 12)
    let slower: Double = 0.3 * cos(turn / 31)
    let quick: Double = 0.15 * cos(turn / 7.4)
    return slow + slower + quick
  }

  var body: some View {
    GeometryReader { geometry in
      // The painting fills the screen and keeps its proportions; a phone crops its sides.
      let scale = max(geometry.size.width / 1024, geometry.size.height / 1536)
      let origin = CGPoint(x: (geometry.size.width - 1024 * scale) / 2,
        y: (geometry.size.height - 1536 * scale) / 2)
      ZStack(alignment: .topLeading) {
        Atelier.sky
        artwork("NightBackdrop", height: 1536, scale: scale, origin: origin)
        starField(scale: scale, origin: origin)
        artwork("NightCloudFar", height: 520, scale: scale, origin: origin)
          .offset(x: sin(time * 2 * .pi / 112) * 1.2 * scale,
            y: sin(time * 2 * .pi / 147) * 0.4 * scale)
        artwork("NightCloudNear", height: 520, scale: scale, origin: origin)
          .offset(x: -sin(time * 2 * .pi / 87) * 2.0 * scale,
            y: sin(time * 2 * .pi / 121) * 0.6 * scale)
        ZStack {
          Image("NightMoonHalo").resizable().interpolation(.high)
            .opacity(1 - 0.022 * (1 - breath))
          Image("NightMoon").resizable().interpolation(.high)
            .opacity(1 - 0.015 * (1 - breath))
        }
        .frame(width: 1024 * scale, height: 520 * scale)
        .rotationEffect(.degrees(moonAngle), anchor: UnitPoint(x: 554.0 / 1024.0, y: 0))
        .offset(x: origin.x, y: origin.y)
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      .clipped()
    }
  }

  private func artwork(_ name: String, height: CGFloat, scale: CGFloat, origin: CGPoint) -> some View {
    Image(name).resizable().interpolation(.high)
      .frame(width: 1024 * scale, height: height * scale)
      .offset(x: origin.x, y: origin.y)
  }

  private func starField(scale: CGFloat, origin: CGPoint) -> some View {
    Canvas(opaque: false, rendersAsynchronously: true) {
      (context: inout GraphicsContext, _: CGSize) in
      renderSky(context: &context, scale: scale, origin: origin)
    }
  }

  private func renderSky(context: inout GraphicsContext, scale: CGFloat, origin: CGPoint) {
    context.translateBy(x: origin.x, y: origin.y)
    context.scaleBy(x: scale, y: scale)
    let angle: Double = moonAngle
    // One screen point, measured in the painting's units.
    let unit: CGFloat = 1.0 / max(0.01, scale)
    for star in NightSkyData.stars {
      let softRow: Int = Int(star[8])
      let seen: Double = softRow < 0
        ? 1.0 : NightSky.sample(NightSkyData.softness[softRow], angle: angle)
      if seen < 0.01 { continue }
      let period: Double = star[4]
      let offset: Double = star[5]
      let slow: Double = 0.5 + 0.5 * sin(time * 6.28 / period + offset)
      let quick: Double = 0.07 * sin(time * 6.28 / (period * 0.21) + offset * 3.1)
      let twinkle: Double = 0.65 + 0.35 * slow + quick
      let alpha: Double = max(0.0, min(1.0, star[3] * star[7] * seen * twinkle))
      let radius: CGFloat = max(0.35 * unit, CGFloat(star[2]))
      let center = CGPoint(x: star[0], y: star[1])
      let tint: Color = NightSky.tints[min(3, max(0, Int(star[6])))]
      let shade: GraphicsContext.Shading = .color(tint.opacity(alpha))
      context.fill(NightSky.dot(center, radius), with: shade)
      if star[2] > 1.2 {
        let halo: GraphicsContext.Shading = .color(tint.opacity(alpha * 0.14))
        context.fill(NightSky.dot(center, CGFloat(star[2]) * 2.6), with: halo)
      }
    }
    renderMicroStars(context: &context, angle: angle, unit: unit)
    if animate {
      renderMeteor(context: &context, unit: unit)
      renderComet(context: &context, unit: unit)
    }
  }

  /// Sub-pixel points only: nothing bright ever enters the crescent's opening.
  private func renderMicroStars(context: inout GraphicsContext, angle: Double, unit: CGFloat) {
    for (index, star) in NightSkyData.microStars.enumerated() {
      let clear: Double = star[2]
      if clear < 0.04 { continue }
      let seen: Double = NightSky.sample(Array(star[3...]), angle: angle)
      if seen < 0.01 { continue }
      let period: Double = 19.0 + Double(index % 4) * 3.0
      let wave: Double = sin(time * 2.0 * Double.pi / period + Double(index) * 0.73)
      let alpha: Double = (0.12 + 0.03 * wave) * clear * seen
      let radius: CGFloat = max(0.2 * unit, 0.36 + CGFloat(index % 3) * 0.06)
      let shade: GraphicsContext.Shading = .color(Color(hex: 0xF9EBC8).opacity(alpha))
      context.fill(NightSky.dot(CGPoint(x: star[0], y: star[1]), radius), with: shade)
    }
  }

  private func renderMeteor(context: inout GraphicsContext, unit: CGFloat) {
    let last: Double = NightSkyData.meteors.last?[0] ?? 0
    let local: Double = time.truncatingRemainder(dividingBy: last + 90)
    for event in NightSkyData.meteors {
      let start: Double = event[0]
      let duration: Double = event[6]
      if local < start { break }
      if local >= start + duration { continue }
      let k: Double = (local - start) / duration
      let ax: CGFloat = CGFloat(event[1]), ay: CGFloat = CGFloat(event[2])
      let dx: CGFloat = CGFloat(event[3]) - ax, dy: CGFloat = CGFloat(event[4]) - ay
      let length: CGFloat = max(1.0, (dx * dx + dy * dy).squareRoot())
      let x: CGFloat = ax + dx * CGFloat(k)
      let y: CGFloat = ay + dy * CGFloat(k)
      let tail: CGFloat = CGFloat(event[5] * sin(Double.pi * k))
      let from = CGPoint(x: x - dx / length * tail, y: y - dy / length * tail)
      let to = CGPoint(x: x, y: y)
      var trail = Path()
      trail.move(to: from); trail.addLine(to: to)
      var layer = context
      layer.opacity = event[7] * sin(Double.pi * k)
      let gradient = Gradient(colors: [Color(hex: 0xF2D7A0).opacity(0), Color(hex: 0xF2D7A0)])
      let shade: GraphicsContext.Shading = .linearGradient(gradient, startPoint: from, endPoint: to)
      let style = StrokeStyle(lineWidth: max(0.5 * unit, CGFloat(event[8])), lineCap: .round)
      layer.stroke(trail, with: shade, style: style)
      return
    }
  }

  private func renderComet(context: inout GraphicsContext, unit: CGFloat) {
    let last: Double = NightSkyData.comets.last?[0] ?? 0
    let local: Double = time.truncatingRemainder(dividingBy: last + 60)
    for event in NightSkyData.comets {
      let start: Double = event[0]
      let duration: Double = event[6]
      if local < start { break }
      if local >= start + duration { continue }
      let k: Double = (local - start) / duration
      let envelope: Double = NightSky.smooth(0, 0.22, k) * (1 - NightSky.smooth(0.78, 1, k))
      let ax: CGFloat = CGFloat(event[1]), ay: CGFloat = CGFloat(event[2])
      let dx: CGFloat = CGFloat(event[3]) - ax, dy: CGFloat = CGFloat(event[4]) - ay
      let length: CGFloat = max(1.0, (dx * dx + dy * dy).squareRoot())
      let x: CGFloat = ax + dx * CGFloat(k)
      let y: CGFloat = ay + dy * CGFloat(k)
      let tail: CGFloat = CGFloat(event[5])
      let from = CGPoint(x: x - dx / length * tail, y: y - dy / length * tail)
      let to = CGPoint(x: x, y: y)
      var trail = Path()
      trail.move(to: from); trail.addLine(to: to)
      var layer = context
      layer.opacity = 0.34 * envelope
      let gradient = Gradient(colors: [Color(hex: 0xDFE6FF).opacity(0), Color(hex: 0xDFE6FF)])
      let shade: GraphicsContext.Shading = .linearGradient(gradient, startPoint: from, endPoint: to)
      layer.stroke(trail, with: shade, style: StrokeStyle(lineWidth: max(0.5 * unit, 0.9), lineCap: .round))
      var head = context
      head.opacity = 0.62 * envelope
      head.fill(NightSky.dot(to, max(0.45 * unit, 0.8)), with: .color(Color(hex: 0xEEF1FF)))
      return
    }
  }
}

/// Small helpers shared by the Night and Settings skies.
enum NightSky {
  static let tints: [Color] = [
    Color(hex: 0xE4D4B9), Color(hex: 0xD6DDF4), Color(hex: 0xF4E4C6), Color(hex: 0xC7D1EC)
  ]

  static func dot(_ center: CGPoint, _ radius: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
      width: 2 * radius, height: 2 * radius))
  }

  /// A value sampled at -1.5 ... +1.5 degrees of the moon's swing, read between the samples.
  static func sample(_ row: [Double], angle: Double) -> Double {
    guard row.count > 1 else { return row.first ?? 1 }
    let position: Double = max(0, min(Double(row.count - 1), (angle + 1.5) / 0.5))
    let lower: Int = Int(position.rounded(.down))
    let upper: Int = min(row.count - 1, lower + 1)
    return row[lower] + (row[upper] - row[lower]) * (position - Double(lower))
  }

  static func smooth(_ a: Double, _ b: Double, _ value: Double) -> Double {
    let k = max(0, min(1, (value - a) / (b - a)))
    return k * k * (3 - 2 * k)
  }
}

/// The cloud bank at the foot of Night and Settings: the same picture in the same place on both.
/// Lists slide under it; the three tab icons stand on it. It sways by less than a point.
struct CloudBank: View {
  var isActive = true
  @Environment(\.atelierViewport) private var viewport

  var body: some View {
    SceneClock(isActive: isActive) { time, _ in
      let sway: CGFloat = CGFloat(sin(time * 2.0 * Double.pi / 136.0)) * 1.2 * viewport.artScale
      Image("NightCloudBank").resizable().interpolation(.high)
        .frame(width: 1024 * viewport.artScale, height: 266 * viewport.artScale)
        .offset(x: viewport.artOrigin.x + sway, y: viewport.bankTop)
        .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        .clipped()
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}
