import SwiftUI

/// Only this decorative subtree ticks; timers, controls and the rest of the app do not redraw
/// at the animation cadence. PNG layers retain their original aspect and colour profile.
struct ReferenceNightScene: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visible = false
  @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
  @State private var ticking = false
  @State private var clockOrigin = Date()
  @State private var heldTime: TimeInterval = 0

  private var fixedTime: TimeInterval? {
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("-reference-screenshot") || arguments.contains("-reference-ui-test") { return 0 }
    return arguments.first(where: { $0.hasPrefix("-reference-time=") })
      .flatMap { Double($0.dropFirst("-reference-time=".count)) }
  }
  private var shouldAnimate: Bool {
    fixedTime == nil && visible && scenePhase == .active && !reduceMotion
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 30.0 : 1.0 / 60.0,
      paused: !shouldAnimate)) { timeline in
      let elapsed = fixedTime ?? (heldTime + (ticking
        ? max(0, timeline.date.timeIntervalSince(clockOrigin)) : 0))
      ReferenceNightArtwork(time: elapsed, animate: shouldAnimate)
    }
    .onAppear { visible = true; setTicking(shouldAnimate) }
    .onDisappear { setTicking(false); visible = false }
    .onChange(of: shouldAnimate) { _, running in setTicking(running) }
    .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
      lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }

  private func setTicking(_ running: Bool) {
    guard running != ticking else { return }
    let now = Date()
    if running { clockOrigin = now }
    else { heldTime += max(0, now.timeIntervalSince(clockOrigin)) }
    ticking = running
  }
}

private struct ReferenceNightArtwork: View {
  let time: TimeInterval
  let animate: Bool
  private var moonAngle: Double { 1.5 * sin(time * 2 * .pi / 11.2) }

  var body: some View {
    GeometryReader { geometry in
      // Fill preserves every layer's proportions. A taller phone crops the lateral sky,
      // whereas the 1024:1536 reference viewport has no crop or stretch.
      let scale = max(geometry.size.width / 1024, geometry.size.height / 1536)
      let origin = CGPoint(x: (geometry.size.width - 1024 * scale) / 2,
        y: (geometry.size.height - 1536 * scale) / 2)
      ZStack(alignment: .topLeading) {
        ReferenceNightStyle.sky
        artwork("ReferenceNightBackdrop", height: 1536, scale: scale, origin: origin)
        starField(scale: scale, origin: origin)
        artwork("ReferenceCloudFar", height: 520, scale: scale, origin: origin)
          .offset(x: sin(time * 2 * .pi / 112) * 0.8 * scale,
            y: sin(time * 2 * .pi / 147) * 0.25 * scale)
        artwork("ReferenceCloudNear", height: 520, scale: scale, origin: origin)
          .offset(x: -sin(time * 2 * .pi / 87) * 1.8 * scale,
            y: sin(time * 2 * .pi / 121) * 0.35 * scale)
        Image("ReferenceMoon")
          .resizable().interpolation(.high)
          .frame(width: 1024 * scale, height: 520 * scale)
          .rotationEffect(.degrees(moonAngle), anchor: UnitPoint(x: 554.0 / 1024.0, y: 0))
          .opacity(0.9875 + 0.0125 * cos(time * 2 * .pi / 12))
          .offset(x: origin.x, y: origin.y)
        artwork("ReferenceCloudBottom", height: 1536, scale: scale, origin: origin)
          .offset(x: sin(time * 2 * .pi / 136) * 1.1 * scale)
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
    Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
      context.translateBy(x: origin.x, y: origin.y)
      context.scaleBy(x: scale, y: scale)
      for (index, point) in ReferenceMoonGeometry.stars.enumerated() {
        guard !ReferenceMoonGeometry.excludes(point, angle: moonAngle) else { continue }
        let radius: CGFloat = index % 7 == 0 ? 1.1 : 0.65
        let alpha = 0.22 + 0.10 * sin(time * 2 * .pi / (9 + Double(index % 11)) + Double(index))
        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
          width: 2 * radius, height: 2 * radius)),
          with: .color(ReferenceNightStyle.text.opacity(alpha)))
      }
      if animate { drawMeteor(context: &context) }
    }
  }

  private func drawMeteor(context: inout GraphicsContext) {
    guard let meteor = ReferenceMoonGeometry.meteor(at: time) else { return }
    // Test the whole candidate path, not merely its currently visible head.
    for sample in 0...16 {
      let fraction = CGFloat(sample) / 16
      let point = CGPoint(
        x: meteor.from.x + (meteor.to.x - meteor.from.x) * fraction,
        y: meteor.from.y + (meteor.to.y - meteor.from.y) * fraction)
      if ReferenceMoonGeometry.excludes(point, angle: moonAngle) { return }
    }
    let progress = CGFloat(meteor.progress)
    let x = meteor.from.x + (meteor.to.x - meteor.from.x) * progress
    let y = meteor.from.y + (meteor.to.y - meteor.from.y) * progress
    let dx = meteor.to.x - meteor.from.x, dy = meteor.to.y - meteor.from.y
    let distance = max(1, hypot(dx, dy))
    let tail = 34 * sin(progress * .pi)
    let start = CGPoint(x: x - dx / distance * tail, y: y - dy / distance * tail)
    let end = CGPoint(x: x, y: y)
    guard !ReferenceMoonGeometry.excludes(start, angle: moonAngle) else { return }
    var trail = Path()
    trail.move(to: start); trail.addLine(to: end)
    context.opacity = 0.42 * sin(Double(progress) * .pi)
    context.stroke(trail, with: .linearGradient(
      Gradient(colors: [.clear, ReferenceNightStyle.text]),
      startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: 1.0, lineCap: .round))
  }
}

enum ReferenceMoonGeometry {
  static let anchor = CGPoint(x: 554, y: 0)
  /// A curved, padded region tracing the actual inner crescent and open sky to its right.
  /// Points are inverse-rotated around the same anchor as the artwork before testing.
  private static let opening: Path = {
    var path = Path()
    path.move(to: CGPoint(x: 576, y: 154))
    path.addCurve(to: CGPoint(x: 647, y: 369),
      control1: CGPoint(x: 425, y: 191), control2: CGPoint(x: 430, y: 414))
    path.addLine(to: CGPoint(x: 1100, y: 400))
    path.addLine(to: CGPoint(x: 1100, y: 135))
    path.closeSubpath()
    return path
  }()
  private static let margin = opening.cgPath.copy(strokingWithWidth: 44,
    lineCap: .round, lineJoin: .round, miterLimit: 2)

  static func excludes(_ point: CGPoint, angle: Double) -> Bool {
    let radians = CGFloat(-angle * .pi / 180)
    let dx = point.x - anchor.x, dy = point.y - anchor.y
    let local = CGPoint(
      x: anchor.x + dx * cos(radians) - dy * sin(radians),
      y: anchor.y + dx * sin(radians) + dy * cos(radians))
    return opening.contains(local) || margin.contains(local)
  }

  static let stars: [CGPoint] = [
    CGPoint(x: 253, y: 31), CGPoint(x: 177, y: 103), CGPoint(x: 114, y: 126),
    CGPoint(x: 205, y: 178), CGPoint(x: 82, y: 211), CGPoint(x: 238, y: 109),
    CGPoint(x: 324, y: 161), CGPoint(x: 157, y: 78), CGPoint(x: 358, y: 74),
    CGPoint(x: 403, y: 126), CGPoint(x: 330, y: 36), CGPoint(x: 425, y: 26),
    CGPoint(x: 699, y: 31), CGPoint(x: 740, y: 97), CGPoint(x: 815, y: 61),
    CGPoint(x: 884, y: 94), CGPoint(x: 959, y: 70), CGPoint(x: 976, y: 120),
    CGPoint(x: 725, y: 456), CGPoint(x: 966, y: 458), CGPoint(x: 81, y: 486),
    CGPoint(x: 167, y: 314), CGPoint(x: 271, y: 235), CGPoint(x: 219, y: 63)
  ]

  struct Meteor {
    var from: CGPoint
    var to: CGPoint
    var progress: Double
  }

  static func meteor(at time: TimeInterval) -> Meteor? {
    // A deterministic 96-event sequence enables reproducible screenshots; gaps stay 40–90s.
    let cycle = 6237.0
    let localTime = time.truncatingRemainder(dividingBy: cycle)
    var start = 48.0
    for index in 0..<96 {
      let duration = 0.85 + Double(index % 4) * 0.12
      if localTime >= start && localTime <= start + duration {
        let path: (CGPoint, CGPoint)
        switch index % 4 {
        case 0: path = (CGPoint(x: 70, y: 58), CGPoint(x: 310, y: 124))
        case 1: path = (CGPoint(x: 994, y: 34), CGPoint(x: 812, y: 75))
        case 2: path = (CGPoint(x: 970, y: 1306), CGPoint(x: 785, y: 1351))
        default: path = (CGPoint(x: 67, y: 1260), CGPoint(x: 235, y: 1318))
        }
        let from = CGPoint(x: path.0.x + CGFloat((index * 29) % 21 - 10),
          y: path.0.y + CGFloat((index * 17) % 19 - 9))
        let to = CGPoint(x: path.1.x + CGFloat((index * 11) % 23 - 11),
          y: path.1.y + CGFloat((index * 7) % 19 - 9))
        return Meteor(from: from, to: to, progress: (localTime - start) / duration)
      }
      start += 40 + Double((index * 37 + 19) % 51)
    }
    return nil
  }
}
