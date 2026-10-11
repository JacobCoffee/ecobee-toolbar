import EcobeeKit
import SwiftUI

/// A drawn ecobee: glossy black squircle with its display showing the room
/// temperature, floating over a glow tinted by what the HVAC is doing.
struct ThermostatIllustration: View {
    let temperature: String
    let activity: HVACActivity?
    let isOn: Bool

    private let side: CGFloat = 104

    var body: some View {
        let tint = Theme.tint(for: activity)
        let active = activity == .heating || activity == .cooling
        ZStack {
            Ellipse()
                .fill(tint.opacity(active ? 0.55 : 0.18))
                .frame(width: side * 1.5, height: 22)
                .blur(radius: 18)
                .offset(y: side * 0.62)

            RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.04)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    // Glass reflection across the top-left of the face.
                    RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .center))
                }
                .overlay {
                    VStack(spacing: 2) {
                        Text(temperature)
                            .font(.system(size: 34, weight: .light))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(isOn ? 0.95 : 0.55))
                        Image(systemName: activity?.symbol ?? "pause.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(active ? tint : .white.opacity(0.35))
                    }
                    .offset(y: 2)
                }
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.6), radius: 12, y: 8)
        }
        .frame(height: side + 28)
        .animation(.easeInOut(duration: 0.6), value: activity)
        .accessibilityElement()
        .accessibilityLabel("Thermostat reading \(temperature), \(activity?.title ?? "idle")")
    }
}
