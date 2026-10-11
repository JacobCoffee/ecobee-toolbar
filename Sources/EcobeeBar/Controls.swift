import SwiftUI

/// Wide capsule slider with a warm/cool filled portion and a white handle.
struct SetpointSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let tint: Color
    let isEnabled: Bool
    let onChange: (Double) -> Void
    let onCommit: () -> Void

    private let height: CGFloat = 46
    private let thumbWidth: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - thumbWidth - 8
            let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = 4 + usable * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.35))
                    .overlay(Capsule().strokeBorder(Theme.cardStroke))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.08), tint.opacity(isEnabled ? 0.55 : 0.15)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: x + thumbWidth + 4)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(white: isEnabled ? 0.93 : 0.5))
                    .frame(width: thumbWidth, height: height - 10)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                    .offset(x: x)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard isEnabled else { return }
                        let f = min(max((g.location.x - 4 - thumbWidth / 2) / usable, 0), 1)
                        onChange(range.lowerBound + f * (range.upperBound - range.lowerBound))
                    }
                    .onEnded { _ in if isEnabled { onCommit() } }
            )
        }
        .frame(height: height)
        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: value)
    }
}

/// Card with icon, label and value; opens a dropdown menu when it has one.
struct Tile<MenuContent: View>: View {
    let symbol: String
    let label: String
    let value: String
    var tint: Color = .white
    @ViewBuilder let menu: () -> MenuContent

    private var hasMenu: Bool { MenuContent.self != EmptyView.self }

    var body: some View {
        if hasMenu {
            Menu {
                menu()
            } label: {
                content
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(tint)
                    .frame(height: 26)
                Spacer(minLength: 0)
                if hasMenu {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .card()
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

extension Tile where MenuContent == EmptyView {
    /// Read-only tile.
    init(symbol: String, label: String, value: String, tint: Color = .white) {
        self.init(symbol: symbol, label: label, value: value, tint: tint) { EmptyView() }
    }
}
