import EcobeeKit
import SwiftUI

enum Theme {
    static let heat = Color(red: 1.0, green: 0.55, blue: 0.24)
    static let cool = Color(red: 0.33, green: 0.64, blue: 1.0)
    static let idle = Color(white: 0.75)
    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.07)
    static let secondary = Color.white.opacity(0.55)

    static func tint(for field: SetpointField, mode: HVACMode?) -> Color {
        switch (field, mode) {
        case (.heat, _), (.target, .heat): heat
        case (.cool, _), (.target, .cool): cool
        default: idle
        }
    }

    static func tint(for activity: HVACActivity?) -> Color {
        switch activity {
        case .heating: heat
        case .cooling: cool
        default: idle
        }
    }
}

extension HVACMode {
    var symbol: String {
        switch self {
        case .off: "power"
        case .heat: "flame"
        case .cool: "snowflake"
        case .auto: "arrow.up.arrow.down"
        }
    }
}

extension HVACActivity {
    var symbol: String {
        switch self {
        case .idle: "pause.circle"
        case .heating: "flame.fill"
        case .cooling: "snowflake"
        }
    }
}

extension Comfort {
    var symbol: String {
        switch self {
        case .home: "house"
        case .sleep: "moon"
        case .away: "figure.walk"
        case .hold: "hand.raised"
        }
    }
}

/// Rounded translucent card used by tiles and pills.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

extension View {
    func card(radius: CGFloat = 16) -> some View { modifier(CardBackground(radius: radius)) }
}

/// Circular icon button (−, +, power).
struct RoundIconButton: View {
    let symbol: String
    var tint: Color = .white
    var glow = false
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.card))
                .overlay(Circle().strokeBorder(glow ? tint.opacity(0.6) : Theme.cardStroke, lineWidth: glow ? 1.5 : 1))
                .shadow(color: glow ? tint.opacity(0.45) : .clear, radius: 8)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
