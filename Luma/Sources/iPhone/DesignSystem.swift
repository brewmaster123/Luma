import SwiftUI
import UIKit
import CoreText

/// 0.9.8 "Atelier Night": a dark room and one night-light.
/// On Night the lamp is the moon, in the Journal the white stone, in Settings the attic window.
/// Text, cards, buttons and sheets are the same on all three screens and take their light from that lamp.
enum Atelier {
  static let ink = Color(hex: 0xE8E5EC)      // "Жемчужный": the one text colour
  static let dim = Color(hex: 0xB4B1C2)      // captions
  static let faint = Color(hex: 0x8F8CA6)    // hints under rows
  static let off = Color(hex: 0x7E7D98)      // inactive icons
  static let foot = Color(hex: 0x77768F)
  static let body = Color(hex: 0xCDC7D6)     // running text in sheets
  static let note = Color(hex: 0x9794AB)
  static let sky = Color(hex: 0x020A17)
  static let well = Color(hex: 0x090D1B)     // sunk fields

  static func display(_ size: CGFloat) -> Font { .custom("PoiretOne-Regular", fixedSize: size) }
  static func ui(_ size: CGFloat, _ weight: String = "Regular") -> Font {
    .custom("Manrope-\(weight)", size: size, relativeTo: .body)
  }
  static func uiFixed(_ size: CGFloat, _ weight: String = "Regular") -> Font {
    .custom("Manrope-\(weight)", fixedSize: size)
  }
  /// Poiret One digits that do not jump when a number changes.
  static func numbers(_ size: CGFloat) -> Font {
    let original = UIFont(name: "PoiretOne-Regular", size: size)
      ?? UIFont.systemFont(ofSize: size, weight: .light)
    let features: [[UIFontDescriptor.FeatureKey: Int]] = [
      [.type: kNumberCaseType, .selector: kUpperCaseNumbersSelector],
      [.type: kNumberSpacingType, .selector: kMonospacedNumbersSelector]
    ]
    let descriptor = original.fontDescriptor.addingAttributes([.featureSettings: features])
    return Font(UIFont(descriptor: descriptor, size: size))
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255)
  }
}

// MARK: - The screen and its lamp

/// The whole screen, including the areas under the status bar and the home indicator.
/// The design is drawn for 402 x 874 pt; `u` and `v` carry it to other iPhones.
struct AtelierViewport: Equatable {
  var size = CGSize(width: 402, height: 874)
  var topInset: CGFloat = 0
  var bottomInset: CGFloat = 0
  var u: CGFloat { size.width / 402 }
  var v: CGFloat { size.height / 874 }
  /// The Night painting (1024 x 1536) fills the screen; its sides are cropped on a phone.
  var artScale: CGFloat { max(size.width / 1024, size.height / 1536) }
  var artOrigin: CGPoint {
    CGPoint(x: (size.width - 1024 * artScale) / 2, y: (size.height - 1536 * artScale) / 2)
  }
  /// Top of the alarm list on Night and the geometry of the cloud bank that lies over its lower edge.
  var alarmRowHeight: CGFloat { max(50, 112 * size.height / 1536) }
  var alarmRowGap: CGFloat { 16 * size.height / 1536 }
  var alarmListTop: CGFloat { 0.7386 * size.height }
  var bankTop: CGFloat { alarmListTop + 2 * alarmRowHeight + alarmRowGap - 95 * artScale }
  /// Lists end on this line, inside the body of the cloud bank.
  var bankClipLine: CGFloat { bankTop + 109 * artScale }
  var tabBarTop: CGFloat { 0.9108 * size.height }
}

private struct AtelierViewportKey: EnvironmentKey {
  static let defaultValue = AtelierViewport()
}

/// Where the light comes from and what colour it is.
struct AtelierLamp: Equatable {
  /// Position on the screen; nil means "lit from straight above" (sheets cover the scene).
  var point: CGPoint? = nil
  var wash = Color(hex: 0xFFC98E)
  var rim = Color(hex: 0xFFE2BA)
  var thread = Color(hex: 0xFFE7C4)

  static func warm(at point: CGPoint?) -> AtelierLamp { AtelierLamp(point: point) }
  static func pearl(at point: CGPoint?) -> AtelierLamp {
    AtelierLamp(point: point, wash: Color(hex: 0xC3D2FF), rim: Color(hex: 0xE2E9FF), thread: Color(hex: 0xEEF1FF))
  }
  /// Unit vector from a control towards the lamp.
  func direction(from frame: CGRect) -> CGVector {
    guard let point else { return CGVector(dx: 0, dy: -1) }
    let dx = point.x - frame.midX, dy = point.y - frame.midY
    let length = (dx * dx + dy * dy).squareRoot()
    return length > 1 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 0, dy: -1)
  }
}

private struct AtelierLampKey: EnvironmentKey {
  static let defaultValue = AtelierLamp()
}

extension EnvironmentValues {
  var atelierViewport: AtelierViewport {
    get { self[AtelierViewportKey.self] }
    set { self[AtelierViewportKey.self] = newValue }
  }
  var atelierLamp: AtelierLamp {
    get { self[AtelierLampKey.self] }
    set { self[AtelierLampKey.self] = newValue }
  }
}

// MARK: - Velvet buttons

/// A wide button: a cushion of dark velvet with a closed line of stitching.
/// The lamp brushes the side that faces it; the far side sinks into the dark.
struct VelvetPlate: View {
  var secondary = false
  @Environment(\.atelierLamp) private var lamp

  var body: some View {
    GeometryReader { geometry in
      plate(size: geometry.size, light: lamp.direction(from: geometry.frame(in: .global)))
    }
    .allowsHitTesting(false)
  }

  private func plate(size: CGSize, light: CGVector) -> some View {
    let w = max(1, size.width), h = max(1, size.height), side = min(w, h)
    let reach = abs(light.dx) * w + abs(light.dy) * h
    let lit = UnitPoint(x: 0.5 + light.dx * reach / (2 * w), y: 0.5 + light.dy * reach / (2 * h))
    let far = UnitPoint(x: 0.5 - light.dx * reach / (2 * w), y: 0.5 - light.dy * reach / (2 * h))
    let tones: [Color] = secondary
      ? [Color(hex: 0x1D1E37), Color(hex: 0x14172A), Color(hex: 0x0B0F1E)]
      : [Color(hex: 0x241F38), Color(hex: 0x18172B), Color(hex: 0x0C1020)]
    let glow: Double = secondary ? 0.088 : 0.16
    let seam = max(3.5, (side * 0.105).rounded())
    let length = max(24, 2 * (w - h) + 2 * CGFloat.pi * (side / 2 - seam))
    let count = 2 * max(6, Int((length / 11.4).rounded()))
    let unit = length / CGFloat(count)
    let dash = unit * 0.42
    let fill = LinearGradient(stops: [
      .init(color: tones[0], location: 0), .init(color: tones[1], location: 0.45),
      .init(color: tones[2], location: 1)
    ], startPoint: lit, endPoint: far)
    let wash = RadialGradient(stops: [
      .init(color: lamp.wash.opacity(glow), location: 0),
      .init(color: lamp.wash.opacity(glow * 0.5), location: 0.35),
      .init(color: lamp.wash.opacity(glow * 0.15), location: 0.7),
      .init(color: lamp.wash.opacity(0), location: 1)
    ], center: UnitPoint(x: lit.x + light.dx * side * 0.25 / w, y: lit.y + light.dy * side * 0.25 / h),
      startRadius: 0, endRadius: max(0.62 * w, 1.25 * side))
    let rim = LinearGradient(stops: [
      .init(color: lamp.rim.opacity(0.62), location: 0), .init(color: lamp.rim.opacity(0.26), location: 0.28),
      .init(color: lamp.rim.opacity(0.07), location: 0.6), .init(color: lamp.rim.opacity(0), location: 1)
    ], startPoint: lit, endPoint: far)
    let thread = LinearGradient(stops: [
      .init(color: lamp.thread.opacity(secondary ? 0.5 : 0.62), location: 0),
      .init(color: lamp.thread.opacity(secondary ? 0.35 : 0.42), location: 0.5),
      .init(color: lamp.thread.opacity(secondary ? 0.25 : 0.3), location: 1)
    ], startPoint: lit, endPoint: far)
    let shade = LinearGradient(colors: [Color.black.opacity(0.34), Color.black.opacity(0)],
      startPoint: far, endPoint: UnitPoint(x: 0.5, y: 0.5))
    return ZStack {
      Capsule().fill(Color.black.opacity(secondary ? 0.4 : 0.5))
        .blur(radius: side * 0.16)
        .offset(x: -light.dx * side * 0.1, y: -light.dy * side * 0.1 + side * 0.08)
      Capsule().fill(fill)
      Capsule().fill(wash)
      Capsule().fill(shade)
      Capsule().strokeBorder(rim.opacity(secondary ? 0.8 : 1), lineWidth: 1.3)
      Capsule().inset(by: seam).stroke(Color(hex: 0x04050D).opacity(0.3), lineWidth: 2.4)
      Capsule().inset(by: seam)
        .stroke(thread, style: StrokeStyle(lineWidth: 0.95, lineCap: .round, dash: [dash, unit - dash]))
    }
    .frame(width: w, height: h)
  }
}

struct VelvetButtonStyle: ButtonStyle {
  var secondary = false
  var height: CGFloat = 49
  var fontSize: CGFloat = 19
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduced

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Atelier.display(fontSize))
      .tracking(fontSize * 0.05)
      .foregroundStyle(Atelier.ink.opacity(secondary ? 0.8 : 1))
      .lineLimit(1).minimumScaleFactor(0.7)
      .padding(.horizontal, 18)
      .frame(maxWidth: .infinity, minHeight: height)
      .background(VelvetPlate(secondary: secondary))
      .contentShape(Capsule())
      .opacity(enabled ? 1 : 0.42)
      .scaleEffect(configuration.isPressed && !reduced ? 0.985 : 1)
      .animation(reduced ? nil : .easeOut(duration: 0.18), value: configuration.isPressed)
  }
}

/// The round face of a small button ("pebble").
struct PebbleFace: View {
  @Environment(\.atelierLamp) private var lamp

  var body: some View {
    GeometryReader { geometry in
      face(side: min(geometry.size.width, geometry.size.height),
        light: lamp.direction(from: geometry.frame(in: .global)))
    }
    .allowsHitTesting(false)
  }

  private func face(side: CGFloat, light: CGVector) -> some View {
    let lit = UnitPoint(x: 0.5 + light.dx / 2, y: 0.5 + light.dy / 2)
    let far = UnitPoint(x: 0.5 - light.dx / 2, y: 0.5 - light.dy / 2)
    let fill = LinearGradient(stops: [
      .init(color: Color(hex: 0x241F38), location: 0), .init(color: Color(hex: 0x18172B), location: 0.45),
      .init(color: Color(hex: 0x0C1020), location: 1)
    ], startPoint: lit, endPoint: far)
    let wash = RadialGradient(stops: [
      .init(color: lamp.wash.opacity(0.14), location: 0), .init(color: lamp.wash.opacity(0.07), location: 0.35),
      .init(color: lamp.wash.opacity(0.02), location: 0.7), .init(color: lamp.wash.opacity(0), location: 1)
    ], center: UnitPoint(x: lit.x + light.dx * 0.25, y: lit.y + light.dy * 0.25),
      startRadius: 0, endRadius: 1.25 * side)
    let rim = LinearGradient(stops: [
      .init(color: lamp.rim.opacity(0.62), location: 0), .init(color: lamp.rim.opacity(0.26), location: 0.28),
      .init(color: lamp.rim.opacity(0.07), location: 0.6), .init(color: lamp.rim.opacity(0), location: 1)
    ], startPoint: lit, endPoint: far)
    let seam = max(3.5, (side * 0.105).rounded())
    return ZStack {
      Circle().fill(Color.black.opacity(0.5))
        .blur(radius: side * 0.16)
        .offset(x: -light.dx * side * 0.1, y: -light.dy * side * 0.1 + side * 0.08)
      Circle().fill(fill)
      Circle().fill(wash)
      Circle().strokeBorder(rim, lineWidth: 1.3)
      if side >= 30 {
        Circle().inset(by: seam)
          .stroke(rim.opacity(0.8), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, dash: [2.4, 3.3]))
      }
    }
    .frame(width: side, height: side)
  }
}

enum PebbleSign {
  case plus, minus, close
}

/// The sign on a pebble: two or one thin strokes with round ends.
struct PebbleSignShape: Shape {
  var sign: PebbleSign
  func path(in rect: CGRect) -> Path {
    let side = min(rect.width, rect.height)
    let g = max(4, (side * 0.16).rounded()), q = g * 0.72
    let cx = rect.midX, cy = rect.midY
    var path = Path()
    switch sign {
    case .minus:
      path.move(to: CGPoint(x: cx - g, y: cy)); path.addLine(to: CGPoint(x: cx + g, y: cy))
    case .plus:
      path.move(to: CGPoint(x: cx - g, y: cy)); path.addLine(to: CGPoint(x: cx + g, y: cy))
      path.move(to: CGPoint(x: cx, y: cy - g)); path.addLine(to: CGPoint(x: cx, y: cy + g))
    case .close:
      path.move(to: CGPoint(x: cx - q, y: cy - q)); path.addLine(to: CGPoint(x: cx + q, y: cy + q))
      path.move(to: CGPoint(x: cx + q, y: cy - q)); path.addLine(to: CGPoint(x: cx - q, y: cy + q))
    }
    return path
  }
}

/// A round velvet button. `size` is the drawn face; the touch target is never under 44 pt.
struct PebbleButtonStyle: ButtonStyle {
  var size: CGFloat
  var target: CGFloat = 44
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduced

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Atelier.ink.opacity(0.94))
      .frame(width: size, height: size)
      .background(PebbleFace())
      .frame(width: max(target, size), height: max(target, size))
      .contentShape(Rectangle())
      .opacity(enabled ? 1 : 0.36)
      .scaleEffect(configuration.isPressed && !reduced ? 0.94 : 1)
      .animation(reduced ? nil : .easeOut(duration: 0.2), value: configuration.isPressed)
  }
}

/// A pebble with a plus, a minus or a cross.
struct PebbleButton: View {
  var sign: PebbleSign
  var size: CGFloat
  var target: CGFloat = 44
  var label: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      PebbleSignShape(sign: sign)
        .stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
        .frame(width: size, height: size)
    }
    .buttonStyle(PebbleButtonStyle(size: size, target: target))
    .accessibilityLabel(label)
  }
}

// MARK: - Cards, rows and small controls

/// A list card: a little lighter than the night, with a hair of light on its upper edge.
struct AtelierCard<Content: View>: View {
  var insets = EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)
  let content: Content

  init(insets: EdgeInsets = EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16),
    @ViewBuilder content: () -> Content) {
    self.insets = insets
    self.content = content()
  }

  var body: some View {
    content
      .padding(insets)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AtelierCardBackground())
  }
}

struct AtelierCardBackground: View {
  var radius: CGFloat = 18
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return shape
      .fill(LinearGradient(stops: [
        .init(color: Color(hex: 0x101729).opacity(0.94), location: 0),
        .init(color: Color(hex: 0x0B1222).opacity(0.933), location: 0.55),
        .init(color: Color(hex: 0x0A1020).opacity(0.933), location: 1)
      ], startPoint: .top, endPoint: .bottom))
      .overlay(shape.strokeBorder(Atelier.ink.opacity(0.078), lineWidth: 1))
      .overlay(alignment: .top) {
        Rectangle().fill(Atelier.ink.opacity(0.051)).frame(height: 1)
          .padding(.horizontal, radius).padding(.top, 1)
      }
  }
}

struct AtelierDivider: View {
  var body: some View {
    Rectangle().fill(Atelier.ink.opacity(0.063)).frame(height: 1)
  }
}

/// A sunk field: text areas, voice-note rows, radio marks.
struct AtelierWell: View {
  var radius: CGFloat = 16
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return shape.fill(Atelier.well)
      .overlay(shape.strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5))
      .overlay(alignment: .top) {
        shape.stroke(Color.black.opacity(0.55), lineWidth: 3).blur(radius: 3)
          .mask { shape.fill(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center)) }
      }
      .clipShape(shape)
  }
}

/// The oval behind a small choice: a day of the week, one of three answers.
struct AtelierChip: View {
  var chosen: Bool
  var body: some View {
    if chosen {
      Capsule().fill(LinearGradient(colors: [Color(hex: 0x34334F), Color(hex: 0x27294A)],
        startPoint: .top, endPoint: .bottom))
        .overlay(Capsule().strokeBorder(Color(hex: 0xFFE2BA).opacity(0.22), lineWidth: 0.6))
    } else {
      Capsule().fill(Atelier.well)
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5))
    }
  }
}

/// A switch in the app's own colours. VoiceOver still meets a standard switch.
struct AtelierToggleStyle: ToggleStyle {
  var width: CGFloat = 44
  var height: CGFloat = 24
  @Environment(\.accessibilityReduceMotion) private var reduced
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    let track = LinearGradient(colors: configuration.isOn
      ? [Color(hex: 0x34334F), Color(hex: 0x27294A)] : [Color(hex: 0x10162A), Color(hex: 0x0C1122)],
      startPoint: .top, endPoint: .bottom)
    return Button { configuration.isOn.toggle() } label: {
      Capsule().fill(track)
        .overlay(Capsule().strokeBorder(Atelier.off.opacity(0.15), lineWidth: 0.5))
        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
          Circle().fill(configuration.isOn ? Atelier.ink : Atelier.off)
            .padding(2)
            .frame(width: height, height: height)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .frame(width: width, height: height)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(enabled ? 1 : 0.4)
    .animation(reduced ? nil : .easeOut(duration: 0.2), value: configuration.isOn)
    .accessibilityRepresentation {
      Toggle(isOn: Binding(get: { configuration.isOn }, set: { configuration.isOn = $0 })) {
        configuration.label
      }.toggleStyle(.switch)
    }
  }
}

/// A slider with a velvet thumb.
struct AtelierSlider: View {
  @Binding var value: Double
  var range: ClosedRange<Double>
  var label: String
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    GeometryReader { geometry in
      let width = max(27, geometry.size.width)
      let span = range.upperBound - range.lowerBound
      let fraction = span > 0 ? CGFloat(min(1, max(0, (value - range.lowerBound) / span))) : 0
      let x = 13 + (width - 26) * fraction
      ZStack(alignment: .leading) {
        Capsule().fill(Color(hex: 0x070A16)).frame(height: 6)
        Capsule().fill(Atelier.ink.opacity(0.6)).frame(width: x, height: 6)
        Circle()
          .fill(RadialGradient(colors: [Color(hex: 0x51475F), Color(hex: 0x2A2440), Color(hex: 0x151529)],
            center: UnitPoint(x: 0.5, y: 0.18), startRadius: 0, endRadius: 16))
          .overlay(Circle().strokeBorder(Color(hex: 0xFFE2BA).opacity(0.25), lineWidth: 0.5))
          .frame(width: 26, height: 26)
          .shadow(color: .black.opacity(0.7), radius: 5, y: 4)
          .offset(x: x - 13)
      }
      .frame(width: width, height: 32, alignment: .leading)
      .contentShape(Rectangle())
      // The slider lives inside scrolling lists. It moves only with a sideways drag: a touch alone
      // changes nothing, and a swipe that goes mostly up or down is left to the list.
      .simultaneousGesture(DragGesture(minimumDistance: 2).onChanged { drag in
        guard abs(drag.translation.width) >= abs(drag.translation.height) else { return }
        let part = Double(min(1, max(0, (drag.location.x - 13) / (width - 26))))
        value = range.lowerBound + part * span
      })
    }
    .frame(height: 32)
    .opacity(enabled ? 1 : 0.4)
    .accessibilityRepresentation {
      Slider(value: $value, in: range) { Text(label) }
    }
  }
}

/// The little row of bars that stands for a recording.
struct VoiceBars: View {
  var playing = false
  var body: some View {
    HStack(spacing: 2.5) {
      ForEach(Array([8.0, 15, 10, 21, 13, 18, 8].enumerated()), id: \.offset) { bar in
        Capsule().fill(Atelier.ink.opacity(playing ? 0.78 : 0.36))
          .frame(width: 2, height: CGFloat(bar.element))
      }
    }
    .frame(height: 24)
    .accessibilityHidden(true)
  }
}

/// Section heading in a list ("Сигнал будильника").
struct AtelierSectionTitle: View {
  var text: String
  var body: some View {
    Text(text).font(Atelier.display(23.5)).tracking(0.235)
      .foregroundStyle(Atelier.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - Sheets

/// A sheet is a large cushion of the same velvet. It floats above the lower edge of the screen;
/// its top catches the lamp's light and a closed line of stitching runs all the way round.
struct CushionPanel: View {
  @Environment(\.atelierLamp) private var lamp

  var body: some View {
    GeometryReader { geometry in
      panel(size: geometry.size)
    }
    .allowsHitTesting(false)
  }

  private func panel(size: CGSize) -> some View {
    let w = max(80, size.width), h = max(80, size.height)
    let radius: CGFloat = 38, inset: CGFloat = 9
    let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
    let straight: CGFloat = 2 * (w - 2 * radius) + 2 * (h - 2 * radius)
    let bends: CGFloat = 2 * CGFloat.pi * (radius - inset)
    let length: CGFloat = max(24, straight + bends)
    let count = 2 * max(6, Int((length / 11.8).rounded()))
    let unit = length / CGFloat(count)
    let dash = unit * 0.42
    let fill = LinearGradient(stops: [
      .init(color: Color(hex: 0x28223B), location: 0),
      .init(color: Color(hex: 0x1C1B31), location: min(0.3, 74 / h)),
      .init(color: Color(hex: 0x13172A), location: min(0.6, 230 / h)),
      .init(color: Color(hex: 0x0C1021), location: 1)
    ], startPoint: .top, endPoint: .bottom)
    let wash = RadialGradient(stops: [
      .init(color: lamp.wash.opacity(0.2), location: 0), .init(color: lamp.wash.opacity(0.09), location: 0.4),
      .init(color: lamp.wash.opacity(0.02), location: 0.75), .init(color: lamp.wash.opacity(0), location: 1)
    ], center: UnitPoint(x: 0.5, y: -34 / h), startRadius: 0, endRadius: w * 0.82)
    let rim = LinearGradient(stops: [
      .init(color: lamp.rim.opacity(0.6), location: 0), .init(color: lamp.rim.opacity(0.2), location: 0.3),
      .init(color: lamp.rim.opacity(0), location: 1)
    ], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: min(1, 230 / h)))
    let thread = LinearGradient(stops: [
      .init(color: lamp.thread.opacity(0.58), location: 0),
      .init(color: lamp.thread.opacity(0.32), location: min(0.5, 170 / h)),
      .init(color: lamp.thread.opacity(0.2), location: 1)
    ], startPoint: .top, endPoint: .bottom)
    let shade = LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.42)],
      startPoint: UnitPoint(x: 0.5, y: 1 - min(0.4, 150 / h)), endPoint: .bottom)
    return ZStack {
      shape.fill(Color.black.opacity(0.62)).blur(radius: 18).offset(y: 14)
      shape.fill(fill)
      shape.fill(wash)
      shape.fill(shade)
      shape.strokeBorder(rim, lineWidth: 1.4)
      shape.inset(by: inset).stroke(Color(hex: 0x04050D).opacity(0.34), lineWidth: 2.6)
      shape.inset(by: inset)
        .stroke(thread, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [dash, unit - dash]))
    }
    .frame(width: w, height: h)
  }
}

/// The frame every sheet uses: title, close button, content, all on one cushion.
/// Since 0.9.9 it is shown as a clear full-screen cover (see `atelierSheet`), not as a system sheet:
/// on iOS 26 a full-height system sheet paints itself flat grey and hides the living scene.
/// Here the scene stays visible and moving behind the dim; the cushion rises as in the mock-up,
/// and it closes with the cross, a tap above it, a swipe down from its top edge or the VoiceOver escape gesture.
/// The keyboard is still the system's.
struct AtelierSheet<Content: View>: View {
  let title: String
  var closeLabel: String
  var canClose: Bool
  let content: Content
  @Environment(\.atelierDismiss) private var dismiss
  @Environment(\.atelierClosing) private var closing
  /// Set by the presenter: 1 for a sheet over a main screen, 2 for a sheet opened from that one, and so on.
  @Environment(\.atelierDepth) private var presentedDepth
  @Environment(\.accessibilityReduceMotion) private var reduced
  @ObservedObject private var depths = AtelierSheetDepth.shared
  /// Height of the sheet's content, measured so that a short sheet is only as tall as it needs to be.
  @State private var contentHeight: CGFloat = 360
  /// The cushion has risen into place (mock-up: 0.42 s rise of 26 pt with a fade, the dim in 0.28 s).
  @State private var risen = false
  /// How far the cushion is being pulled down right now. A gesture state, so it springs back by itself
  /// when the drag ends or is cancelled.
  @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.3, dampingFraction: 0.85)))
  private var dragging: CGFloat = 0
  /// Where the cushion was let go when the swipe closes the sheet; it fades from there.
  @State private var released: CGFloat = 0

  init(_ title: String, canClose: Bool = true, @ViewBuilder content: () -> Content) {
    self.title = title
    self.canClose = canClose
    self.closeLabel = tr("Закрыть")
    self.content = content()
  }

  private var shown: Bool { risen && !closing }
  private var depth: Int { max(1, presentedDepth) }
  private var pull: CGFloat { dragging + released }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { close() }
          .gesture(pullToClose)
          .accessibilityHidden(true)
        ScrollViewReader { proxy in
          ScrollView {
            sheetBody
              // A sheet's content can bring a part of itself into view (an explanation it has just opened).
              .environment(\.atelierScroll, proxy)
              .background(GeometryReader { inner in
                Color.clear.preference(key: AtelierSheetHeightKey.self, value: inner.size.height)
              })
          }
          .scrollBounceBehavior(.basedOnSize)
          .scrollIndicators(.hidden)
        }
        .frame(height: max(120, min(contentHeight, geometry.size.height * 0.9)))
        .background(CushionPanel())
        .onPreferenceChange(AtelierSheetHeightKey.self) { height in
          if abs(height - contentHeight) > 0.5 { contentHeight = height }
        }
        .offset(y: pull + (shown ? 0 : 26))
        .scaleEffect(shown ? 1 : 0.985, anchor: .bottom)
        .opacity(shown ? 1 : 0)
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 14)
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    // The layers under the sheet stay visible, but VoiceOver must not wander onto them.
    .background(AtelierModalMarker())
    .background {
      // The mock-up's dim: radial-gradient(130% 62% at 50% 0, #070b17 at 40 %, #03060f at 85 % by 78 %).
      // A sheet opened from another adds only a light veil, so stacked sheets do not sink the scene into black.
      LinearGradient(stops: [
        .init(color: Color(hex: 0x070B17).opacity(depth == 1 ? 0.40 : 0.18), location: 0),
        .init(color: Color(hex: 0x03060F).opacity(depth == 1 ? 0.85 : 0.42), location: 0.48),
        .init(color: Color(hex: 0x03060F).opacity(depth == 1 ? 0.85 : 0.42), location: 1)
      ], startPoint: .top, endPoint: .bottom)
      .opacity(shown ? 1 - min(0.5, pull / 500) : 0)
      .ignoresSafeArea()
      .accessibilityHidden(true)
    }
    .foregroundStyle(Atelier.body)
    .font(Atelier.ui(15))
    .environment(\.atelierLamp, AtelierLamp())
    .lumaMessages(depth: depth)
    .accessibilityAddTraits(.isModal)
    .accessibilityAction(.escape) { close() }
    .animation(reduced ? nil : (shown ? .timingCurve(0.2, 0.85, 0.25, 1, duration: 0.42) : .easeIn(duration: 0.22)),
      value: shown)
    .onAppear {
      depths.opened(depth)
      risen = true
    }
    .onDisappear { depths.closed(depth) }
    .presentationBackground(.clear)
  }

  private func close() {
    guard canClose else { return }
    dismiss()
  }

  private var pullToClose: some Gesture {
    DragGesture(minimumDistance: 8, coordinateSpace: .global)
      .updating($dragging) { drag, state, _ in
        state = canClose ? max(0, drag.translation.height) : 0
      }
      .onEnded { drag in
        guard canClose else { return }
        if drag.translation.height > 110 || drag.predictedEndTranslation.height > 260 {
          var quiet = Transaction()
          quiet.disablesAnimations = true
          withTransaction(quiet) { released = max(0, drag.translation.height) }
          dismiss()
        }
      }
  }

  private var sheetBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        Text(title).font(Atelier.display(27)).tracking(0.54)
          .foregroundStyle(Atelier.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
        PebbleButton(sign: .close, size: 36, target: 40, label: closeLabel) { dismiss() }
          .disabled(!canClose)
      }
      .padding(.bottom, 14)
      Rectangle()
        .fill(LinearGradient(colors: [.clear, Atelier.ink.opacity(0.22), .clear],
          startPoint: .leading, endPoint: .trailing))
        .frame(height: 1)
        .padding(.bottom, 16)
      content
    }
    .padding(EdgeInsets(top: 30, leading: 26, bottom: 28, trailing: 26))
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .top) {
      // The cushion's upper edge is its handle: a swipe down from here closes the sheet. It lies in the
      // empty top margin and scrolls away with the content, so it never covers a control of a scrolled sheet.
      Color.clear.frame(height: 28).contentShape(Rectangle())
        .gesture(pullToClose)
        .accessibilityHidden(true)
    }
  }
}

/// 0.9.9: a sheet is a clear cover, so the screen it was opened from stays in the window behind it.
/// For VoiceOver the cover must still be a closed room. The marker finds the cover's own container among
/// the window's views and marks it modal: VoiceOver then ignores its siblings (the screen and any sheet
/// below). It draws nothing and takes no touches. This is UIKit's own way of making a presented view modal;
/// hiding the screen from SwiftUI instead could hide the sheets presented from it as well.
private struct AtelierModalMarker: UIViewRepresentable {
  func makeUIView(context: Context) -> MarkerView { MarkerView() }
  func updateUIView(_ view: MarkerView, context: Context) {}

  final class MarkerView: UIView {
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      isAccessibilityElement = false
      backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil else { return }
      DispatchQueue.main.async { [weak self] in self?.markContainer() }
    }

    private func markContainer() {
      guard let window else { return }
      var view: UIView = self
      while let parent = view.superview, parent !== window { view = parent }
      // `view` is now the cover's own container, a direct child of the window.
      if view !== self, view.superview === window { view.accessibilityViewIsModal = true }
    }
  }
}

private struct AtelierSheetHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

// MARK: - How sheets are shown

/// Closes the sheet it is given to, with the cushion's own fade instead of the system slide.
/// Sheet views call it exactly as they used to call `dismiss()`.
struct AtelierDismissAction {
  var close: @MainActor () -> Void = {}
  @MainActor func callAsFunction() { close() }
}

private struct AtelierDismissKey: EnvironmentKey {
  static let defaultValue = AtelierDismissAction()
}

private struct AtelierClosingKey: EnvironmentKey {
  static let defaultValue = false
}

private struct AtelierDepthKey: EnvironmentKey {
  static let defaultValue = 0
}

private struct AtelierScrollKey: EnvironmentKey {
  static let defaultValue: ScrollViewProxy? = nil
}

extension EnvironmentValues {
  var atelierDismiss: AtelierDismissAction {
    get { self[AtelierDismissKey.self] }
    set { self[AtelierDismissKey.self] = newValue }
  }
  /// True while a sheet is fading out, just before the cover is removed.
  var atelierClosing: Bool {
    get { self[AtelierClosingKey.self] }
    set { self[AtelierClosingKey.self] = newValue }
  }
  /// How many sheets are open under this view: 0 on the main screens, 1 inside the first sheet, and so on.
  var atelierDepth: Int {
    get { self[AtelierDepthKey.self] }
    set { self[AtelierDepthKey.self] = newValue }
  }
  /// The scroll of the sheet a view sits in (nil outside a sheet).
  var atelierScroll: ScrollViewProxy? {
    get { self[AtelierScrollKey.self] }
    set { self[AtelierScrollKey.self] = newValue }
  }
}

/// Which sheet is on top. Only the topmost layer shows the app's message card,
/// now that the layers underneath are visible through the sheets.
final class AtelierSheetDepth: ObservableObject {
  static let shared = AtelierSheetDepth()
  @Published private(set) var top = 0

  func opened(_ depth: Int) { if depth > top { top = depth } }
  func closed(_ depth: Int) { if depth <= top { top = max(0, depth - 1) } }
}

/// How long the cushion takes to fade away before the cover is removed.
private let atelierFadeOut: TimeInterval = 0.22

/// Presents a sheet bound to a flag.
private struct AtelierSheetPresenter<Sheet: View>: ViewModifier {
  @Binding var isPresented: Bool
  let onDismiss: (() -> Void)?
  let sheet: () -> Sheet
  /// How many sheets lie under the place this one is shown from; the new sheet is one deeper.
  @Environment(\.atelierDepth) private var depth
  @State private var shown = false
  @State private var closing = false

  func body(content: Content) -> some View {
    content
      .fullScreenCover(isPresented: $shown, onDismiss: onDismiss) {
        sheet()
          .environment(\.atelierDismiss, AtelierDismissAction { isPresented = false })
          .environment(\.atelierClosing, closing)
          .environment(\.atelierDepth, depth + 1)
          .presentationBackground(.clear)
      }
      .onChange(of: isPresented, initial: true) { _, wanted in
        if wanted { present() } else { fadeOut() }
      }
      .onChange(of: shown) { _, now in
        // Removed by the system rather than by us: keep the flag in step.
        if !now, !closing, isPresented { isPresented = false }
      }
  }

  private func present() {
    guard !shown, !closing else { return }
    var quiet = Transaction()
    quiet.disablesAnimations = true
    withTransaction(quiet) { shown = true }
  }

  private func fadeOut() {
    guard shown, !closing else { return }
    closing = true
    DispatchQueue.main.asyncAfter(deadline: .now() + atelierFadeOut) {
      var quiet = Transaction()
      quiet.disablesAnimations = true
      withTransaction(quiet) { shown = false }
      // `closing` stays set until the cover is really gone, so the change of `shown` above
      // is not mistaken for a system dismissal.
      DispatchQueue.main.async {
        closing = false
        if isPresented { present() }
      }
    }
  }
}

/// Presents a sheet bound to an item.
private struct AtelierItemSheetPresenter<Item: Identifiable, Sheet: View>: ViewModifier {
  @Binding var item: Item?
  let onDismiss: (() -> Void)?
  let sheet: (Item) -> Sheet
  /// How many sheets lie under the place this one is shown from; the new sheet is one deeper.
  @Environment(\.atelierDepth) private var depth
  @State private var shown: Item?
  @State private var closing = false

  func body(content: Content) -> some View {
    content
      .fullScreenCover(item: $shown, onDismiss: onDismiss) { value in
        sheet(value)
          .environment(\.atelierDismiss, AtelierDismissAction { item = nil })
          .environment(\.atelierClosing, closing)
          .environment(\.atelierDepth, depth + 1)
          .presentationBackground(.clear)
      }
      .onChange(of: item?.id, initial: true) { _, _ in update() }
      .onChange(of: shown?.id) { _, now in
        if now == nil, !closing, item != nil { item = nil }
      }
  }

  private func update() {
    if let wanted = item {
      if shown == nil { present(wanted) }
      else if shown?.id != wanted.id { fadeOut() }
    } else {
      fadeOut()
    }
  }

  private func present(_ value: Item) {
    guard !closing else { return }
    var quiet = Transaction()
    quiet.disablesAnimations = true
    withTransaction(quiet) { shown = value }
  }

  private func fadeOut() {
    guard shown != nil, !closing else { return }
    closing = true
    DispatchQueue.main.asyncAfter(deadline: .now() + atelierFadeOut) {
      var quiet = Transaction()
      quiet.disablesAnimations = true
      withTransaction(quiet) { shown = nil }
      DispatchQueue.main.async {
        closing = false
        // Another item was asked for while this one was fading: show it now that the cover is gone.
        if let next = item, shown == nil { present(next) }
      }
    }
  }
}

extension View {
  /// Every cushion is shown through here instead of `.sheet`: a full-screen cover with a clear background,
  /// so the screen behind stays visible and alive. Same arguments and the same `onDismiss` timing as `.sheet`.
  func atelierSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Sheet) -> some View {
    modifier(AtelierSheetPresenter(isPresented: isPresented, onDismiss: onDismiss, sheet: content))
  }

  func atelierSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
    modifier(AtelierItemSheetPresenter(item: item, onDismiss: onDismiss, sheet: content))
  }
}

/// Text blocks used inside sheets.
struct SheetLead: View {
  var text: String
  var body: some View {
    Text(text).font(Atelier.ui(16)).lineSpacing(6)
      .foregroundStyle(Atelier.ink.opacity(0.95))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 16)
  }
}

struct SheetNote: View {
  var text: String
  var centered = false
  var body: some View {
    Text(text).font(Atelier.ui(12.5)).lineSpacing(4)
      .foregroundStyle(Atelier.note)
      .multilineTextAlignment(centered ? .center : .leading)
      .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct SheetPoint: View {
  var text: String
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 11) {
      Circle().fill(Atelier.ink).frame(width: 6, height: 6).offset(y: -2).padding(.leading, 5)
      Text(text).font(Atelier.ui(14.5)).lineSpacing(5)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A round mark: empty or filled. Used for "do not show again" and for choosing one of several.
struct RoundMark: View {
  var on: Bool
  var body: some View {
    ZStack {
      Circle().fill(Color(hex: 0x080C19))
        .overlay(Circle().strokeBorder(Color.black.opacity(0.65), lineWidth: 0.5))
      if on { Circle().fill(Atelier.ink).frame(width: 9, height: 9) }
    }
    .frame(width: 24, height: 24)
  }
}

// MARK: - Messages and toasts

/// Short confirmations ("Сон сохранён") that fade away by themselves.
final class ToastCenter: ObservableObject {
  static let shared = ToastCenter()
  @Published private(set) var text: String?
  private var token = 0

  func show(_ message: String) {
    token += 1
    let current = token
    text = message
    UIAccessibility.post(notification: .announcement, argument: message)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
      guard let self, self.token == current else { return }
      self.text = nil
    }
  }
}

struct ToastView: View {
  @ObservedObject var center: ToastCenter
  @Environment(\.accessibilityReduceMotion) private var reduced

  var body: some View {
    ZStack {
      if let text = center.text {
        Text(text).font(Atelier.ui(13)).foregroundStyle(Atelier.ink)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 17).padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
              .fill(LinearGradient(colors: [Color(hex: 0x221F36).opacity(0.96), Color(hex: 0x15172A).opacity(0.96)],
                startPoint: .top, endPoint: .bottom))
              .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(Color(hex: 0xFFE2BA).opacity(0.14), lineWidth: 0.6))
              .shadow(color: .black.opacity(0.65), radius: 13, y: 10)
          )
          .frame(maxWidth: 330)
          .transition(.opacity)
      }
    }
    .animation(reduced ? nil : .easeOut(duration: 0.25), value: center.text)
    .allowsHitTesting(false)
  }
}

/// A message from the app (an error or a note). Shown on a small cushion over whatever is on screen,
/// including an open sheet, so it is never left waiting behind one.
struct LumaMessageCard: View {
  /// 0 on the main screens, 1 in the first sheet and so on. Only the topmost layer shows the card,
  /// because the layers under a sheet now stay visible through it.
  var depth = 0
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var depths = AtelierSheetDepth.shared

  var body: some View {
    ZStack {
      // The note about a test signal is shown by Settings as a countdown, not as a card.
      if depth == depths.top, let message = model.message, L10n.probeNoticeDelay(message) == nil {
        Color.black.opacity(0.5).ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { }
        VStack(alignment: .leading, spacing: 14) {
          Text(L10n.appName).font(Atelier.display(24)).tracking(0.5).foregroundStyle(Atelier.ink)
          Text(L10n.show(message)).font(Atelier.ui(15)).lineSpacing(5)
            .foregroundStyle(Atelier.ink.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
          Button(tr("Понятно")) { model.message = nil }
            .buttonStyle(VelvetButtonStyle())
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 26, leading: 26, bottom: 24, trailing: 26))
        .background(CushionPanel())
        .padding(.horizontal, 22)
        .environment(\.atelierLamp, AtelierLamp())
        .accessibilityAddTraits(.isModal)
      }
    }
    .animation(.easeOut(duration: 0.2), value: model.message)
  }
}

extension View {
  /// Lets the app's messages appear over this view.
  func lumaMessages(depth: Int = 0) -> some View {
    overlay { LumaMessageCard(depth: depth) }
  }
}

// MARK: - Icons drawn in code (the same outlines as in the mock-up)

/// Crescent, open book and gear for the tab bar; alarm clock for the Smart alarm heading.
/// They are thin outlines in a 40 x 40 box, scaled to the frame they are given.
struct MoonIcon: Shape {
  func path(in rect: CGRect) -> Path {
    let s = min(rect.width, rect.height) / 40
    let ox = rect.midX - 20 * s, oy = rect.midY - 20 * s
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
    var path = Path()
    path.move(to: p(40, 25.566))
    path.addCurve(to: p(19.519, 20.481), control1: p(32.758, 27.795), control2: p(24.877, 25.839))
    path.addCurve(to: p(14.434, 0), control1: p(14.161, 15.123), control2: p(12.205, 7.242))
    path.addCurve(to: p(0.102, 21.58), control1: p(5.13, 2.865), control2: p(-0.866, 11.892))
    path.addCurve(to: p(18.42, 39.898), control1: p(1.07, 31.267), control2: p(8.733, 38.93))
    path.addCurve(to: p(40, 25.566), control1: p(28.108, 40.866), control2: p(37.135, 34.87))
    path.closeSubpath()
    return path
  }
}

struct BookIcon: Shape {
  func path(in rect: CGRect) -> Path {
    let s = min(rect.width, rect.height) / 40
    let ox = rect.midX - 20 * s, oy = rect.midY - 20 * s
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
    var path = Path()
    path.move(to: p(20, 4.276)); path.addLine(to: p(20, 40))
    path.move(to: p(0, 2.49))
    path.addCurve(to: p(20, 4.276), control1: p(6.667, -1.083), control2: p(13.333, -1.083))
    path.addCurve(to: p(40, 2.49), control1: p(26.667, -1.083), control2: p(33.333, -1.083))
    path.addLine(to: p(40, 38.214))
    path.addCurve(to: p(20, 40), control1: p(33.333, 34.641), control2: p(26.667, 34.641))
    path.addCurve(to: p(0, 38.214), control1: p(13.333, 34.641), control2: p(6.667, 34.641))
    path.closeSubpath()
    return path
  }
}

/// Eight even teeth, one of them straight up.
struct GearIcon: Shape {
  func path(in rect: CGRect) -> Path {
    let s = min(rect.width, rect.height) / 40
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let outer = 19.4 * s, root = 14.7 * s, hole = 6.3 * s
    var path = Path()
    for tooth in 0..<8 {
      let axis = -90.0 + 45.0 * Double(tooth)
      path.addArc(center: center, radius: outer, startAngle: .degrees(axis - 8),
        endAngle: .degrees(axis + 8), clockwise: false)
      path.addArc(center: center, radius: root, startAngle: .degrees(axis + 13.5),
        endAngle: .degrees(axis + 31.5), clockwise: false)
    }
    path.closeSubpath()
    path.addEllipse(in: CGRect(x: center.x - hole, y: center.y - hole, width: 2 * hole, height: 2 * hole))
    return path
  }
}

struct AlarmClockIcon: Shape {
  func path(in rect: CGRect) -> Path {
    let s = min(rect.width, rect.height) / 47
    let ox = rect.midX - 23.5 * s, oy = rect.midY - 23.5 * s
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
    var path = Path()
    path.addEllipse(in: CGRect(x: ox + 1.25 * s, y: oy + 2.25 * s, width: 43.5 * s, height: 43.5 * s))
    path.move(to: p(22, 8)); path.addLine(to: p(22, 25)); path.addLine(to: p(39, 25))
    return path
  }
}
