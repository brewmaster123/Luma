import SwiftUI

enum LumaStyle {
    static let background = Color(hex: 0x0C1120)
    static let surface = Color(hex: 0x171E30)
    static let inset = Color(hex: 0x111728)
    static let lavender = Color(hex: 0xC6B6F4)
    static let text = Color(hex: 0xF2EFF8)
    static let secondary = Color(hex: 0xB2B8C9)
    static let mint = Color(hex: 0xAAD8C5)
    static let amber = Color(hex: 0xECD19B)
    static let border = Color(hex: 0x30394E)
}
extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct LumaCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(LumaStyle.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(LumaStyle.border.opacity(0.55), lineWidth: 0.7))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 18)
            .foregroundStyle(LumaStyle.background)
            .background(LumaStyle.lavender.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}

struct MoonOrb: View {
    var compact = false
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle().fill(RadialGradient(colors: [LumaStyle.lavender.opacity(0.10), .clear],
                                             center: .center, startRadius: 10, endRadius: size / 2))
                Circle().stroke(LumaStyle.lavender.opacity(0.12), lineWidth: 0.8).padding(size * 0.08)
                Circle().trim(from: 0.05, to: 0.68)
                    .stroke(AngularGradient(colors: [.clear, LumaStyle.lavender.opacity(0.6), .clear], center: .center),
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .padding(size * 0.19).rotationEffect(.degrees(-50))
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(hex: 0xE9DEFF), LumaStyle.lavender, Color(hex: 0x5D5486)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().fill(LumaStyle.background).offset(x: size * 0.09, y: -size * 0.045)
                }.frame(width: size * 0.33, height: size * 0.33).rotationEffect(.degrees(-22))
                Circle().fill(LumaStyle.lavender).frame(width: 4, height: 4).offset(x: size * 0.30, y: -size * 0.18)
                Circle().fill(LumaStyle.lavender.opacity(0.45)).frame(width: 2, height: 2).offset(x: -size * 0.26, y: size * 0.16)
                Image(systemName: "sparkle").font(.system(size: compact ? 10 : 14))
                    .foregroundStyle(LumaStyle.lavender.opacity(0.8)).offset(x: -size * 0.22, y: -size * 0.24)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityHidden(true)
    }
}

struct CountSelector: View {
    let selected: CueCount
    var disabled = false
    let onSelect: (CueCount) -> Void
    var body: some View {
        HStack(spacing: 10) {
            ForEach(CueCount.allCases) { count in
                Button { onSelect(count) } label: {
                    Text("\(count.rawValue)").font(.title3.weight(.medium))
                        .frame(maxWidth: .infinity).frame(minHeight: 50)
                        .foregroundStyle(selected == count ? LumaStyle.background : LumaStyle.text)
                        .background(selected == count ? LumaStyle.lavender : LumaStyle.inset,
                                    in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain).disabled(disabled)
                .accessibilityLabel("\(count.rawValue) коротких сигналов")
                .accessibilityAddTraits(selected == count ? .isSelected : [])
            }
        }
    }
}

struct SmallLabel: View {
    let text: String
    var body: some View { Text(text).font(.caption.weight(.medium)).tracking(1.4).foregroundStyle(LumaStyle.secondary) }
}

extension View {
    func lumaScreen() -> some View {
        self.background(LumaStyle.background).foregroundStyle(LumaStyle.text)
    }
}
