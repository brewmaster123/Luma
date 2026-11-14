import SwiftUI

/// Measured, composited colours from the 1024 × 1536 reference.
/// Decorative art is bundled separately; every label and control remains native.
enum ReferenceNightStyle {
  static let sky = Color(hex: 0x020A17)
  static let middle = Color(hex: 0x050E1E)
  static let text = Color(hex: 0xF9EBC8)
  static let secondary = Color(hex: 0xB4B1C2)
  static let amber = Color(hex: 0xF9C471)
  static let inactive = Color(hex: 0x7E7D98)
  static let buttonTop = Color(hex: 0x37364F)
  static let buttonMiddle = Color(hex: 0x131D34)
  static let buttonBottom = Color(hex: 0x0C152A)
  static let cardTop = Color(hex: 0x0A1323)
  static let cardBottom = Color(hex: 0x081121)
  static let toggleTrack = Color(hex: 0x282B47)
  static let toggleThumb = Color(hex: 0xF2F0F3)

  // Times New Roman is the closest measured system serif, not an identified source font.
  static func serif(_ size: CGFloat, relativeTo: Font.TextStyle = .body) -> Font {
    .custom("TimesNewRomanPSMT", size: size, relativeTo: relativeTo)
  }

  static func sans(_ size: CGFloat, relativeTo: Font.TextStyle = .body) -> Font {
    .system(size: size, weight: .regular, design: .default)
  }
}

struct ReferenceNightViewport {
  var size: CGSize = CGSize(width: 390, height: 844)
  var topInset: CGFloat = 0
  var bottomInset: CGFloat = 0
  var scaleX: CGFloat { size.width / 1024 }
  var scaleY: CGFloat { size.height / 1536 }
}

private struct ReferenceNightViewportKey: EnvironmentKey {
  static let defaultValue = ReferenceNightViewport()
}

extension EnvironmentValues {
  var referenceNightViewport: ReferenceNightViewport {
    get { self[ReferenceNightViewportKey.self] }
    set { self[ReferenceNightViewportKey.self] = newValue }
  }
}

struct ReferenceRoundButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduced
  var diameter: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: max(44, diameter), height: max(44, diameter))
      .background {
        Circle()
          .fill(LinearGradient(
            colors: [Color(hex: 0x222638), Color(hex: 0x07101F)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
          .overlay(Circle().stroke(
            LinearGradient(
              colors: [ReferenceNightStyle.text.opacity(0.72),
                ReferenceNightStyle.amber.opacity(0.16), .clear],
              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6))
      }
      .opacity(configuration.isPressed ? 0.82 : 1)
      .scaleEffect(configuration.isPressed && !reduced ? 0.97 : 1)
      .animation(reduced ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
  }
}

struct ReferenceAlarmToggleStyle: ToggleStyle {
  @Environment(\.accessibilityReduceMotion) private var reduced
  var scaleX: CGFloat
  var scaleY: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    let width = max(32, 94 * scaleX)
    let height = max(26, min(38, 46 * scaleY))
    Button { configuration.isOn.toggle() } label: {
      Capsule().fill(configuration.isOn
        ? ReferenceNightStyle.toggleTrack : ReferenceNightStyle.cardTop)
        .overlay {
          Capsule().stroke(ReferenceNightStyle.inactive.opacity(0.15), lineWidth: 0.5)
        }
        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
          Circle().fill(configuration.isOn
            ? ReferenceNightStyle.toggleThumb : ReferenceNightStyle.inactive)
            .padding(2)
            .frame(width: height, height: height)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
        .frame(width: width, height: height)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .animation(reduced ? nil : .easeOut(duration: 0.2), value: configuration.isOn)
    .accessibilityRepresentation {
      Toggle(isOn: Binding(get: { configuration.isOn }, set: { configuration.isOn = $0 })) {
        configuration.label
      }.toggleStyle(.switch)
    }
  }
}
