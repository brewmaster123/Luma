import SwiftUI

enum LumaStyle {
  static let background = Color(hex: 0x0B0F1C), surface = Color(hex: 0x171C2F),
    inset = Color(hex: 0x101525)
  static let lavender = Color(hex: 0xCCBDF7), text = Color(hex: 0xF0EDF8),
    secondary = Color(hex: 0xA6ABC2)
  static let mint = Color(hex: 0xA8D7CB), amber = Color(hex: 0xE0C59C),
    border = Color(hex: 0x34394F)
  static func font(
    _ size: CGFloat, _ weight: String = "Regular", relativeTo: Font.TextStyle = .body
  ) -> Font {
    .custom("Manrope-\(weight)", size: size, relativeTo: relativeTo)
  }
}
extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255)
  }
}
struct LumaCard<Content: View>: View {
  let content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .background(
        LinearGradient(
          colors: [LumaStyle.surface, LumaStyle.inset], startPoint: .topLeading,
          endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 25)
      )
      .overlay(RoundedRectangle(cornerRadius: 25).stroke(.white.opacity(0.09), lineWidth: 0.7))
      .shadow(color: .black.opacity(0.13), radius: 12, y: 8)
  }
}
struct PrimaryButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduced
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(LumaStyle.font(16, "SemiBold")).frame(maxWidth: .infinity).padding(
      .vertical, 17
    )
    .foregroundStyle(LumaStyle.background).background(LumaStyle.lavender, in: Capsule())
    .opacity(configuration.isPressed ? 0.8 : 1).scaleEffect(
      configuration.isPressed && !reduced ? 0.98 : 1)
  }
}
struct MoonOrb: View {
  var compact = false
  @Environment(\.accessibilityReduceMotion) private var reduced
  @Environment(\.scenePhase) private var phase
  @State private var moving = false
  @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
  var body: some View {
    GeometryReader { geometry in
      let size = min(geometry.size.width, geometry.size.height)
      ZStack {
        Circle().fill(
          RadialGradient(
            colors: [LumaStyle.lavender.opacity(0.13), .clear], center: .center, startRadius: 0,
            endRadius: size / 2))
        Circle().stroke(LumaStyle.lavender.opacity(0.12), lineWidth: 0.7).padding(size * 0.06)
        Circle().trim(from: 0.05, to: 0.67).stroke(
          AngularGradient(
            colors: [.clear, LumaStyle.lavender.opacity(0.55), .clear], center: .center),
          lineWidth: 1
        ).padding(size * 0.18).rotationEffect(.degrees(moving ? -28 : -48))
        ZStack {
          Circle().fill(
            LinearGradient(
              colors: [Color(hex: 0xF4ECFF), LumaStyle.lavender, Color(hex: 0x655587)],
              startPoint: .topLeading, endPoint: .bottomTrailing))
          Circle().fill(LumaStyle.background).offset(x: size * 0.085, y: -size * 0.04)
        }.frame(width: size * 0.33, height: size * 0.33).rotationEffect(.degrees(-22)).offset(
          y: moving ? -4 : 3)
        Image(systemName: "sparkle").font(.system(size: compact ? 10 : 14)).foregroundStyle(
          LumaStyle.lavender
        ).offset(x: -size * 0.24, y: -size * 0.24)
        Circle().fill(LumaStyle.lavender).frame(width: 4, height: 4).offset(
          x: size * 0.30, y: -size * 0.16)
        Circle().fill(LumaStyle.lavender.opacity(0.4)).frame(width: 2, height: 2).offset(
          x: -size * 0.3, y: size * 0.2)
      }.frame(width: geometry.size.width, height: geometry.size.height)
    }.accessibilityHidden(true)
      .onAppear { animate() }.onDisappear { moving = false }
      .onChange(of: reduced) { _, _ in animate() }.onChange(of: phase) { _, _ in animate() }
      .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) {
        _ in
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        animate()
      }
  }
  private func animate() {
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t) { moving = false }
    if !reduced && !lowPower && phase == .active {
      withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) { moving = true }
    }
  }
}
struct CountSelector: View {
  let selected: CueCount
  var disabled = false
  let onSelect: (CueCount) -> Void
  var body: some View {
    HStack(spacing: 10) {
      ForEach(CueCount.allCases) { n in
        Button {
          onSelect(n)
        } label: {
          Text("\(n.rawValue)").font(LumaStyle.font(18, "Medium")).frame(
            maxWidth: .infinity, minHeight: 48
          ).foregroundStyle(selected == n ? LumaStyle.background : LumaStyle.text).background(
            selected == n ? LumaStyle.lavender : LumaStyle.inset,
            in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(disabled).accessibilityLabel(
          "\(n.rawValue) коротких сигналов"
        ).accessibilityAddTraits(selected == n ? .isSelected : [])
      }
    }
  }
}
struct SmallLabel: View {
  let text: String
  var body: some View {
    Text(text).font(LumaStyle.font(11, "SemiBold", relativeTo: .caption)).tracking(1.6)
      .foregroundStyle(LumaStyle.secondary)
  }
}
extension View {
  func lumaScreen() -> some View {
    self.background(LumaStyle.background).foregroundStyle(LumaStyle.text).font(LumaStyle.font(15))
  }
}
