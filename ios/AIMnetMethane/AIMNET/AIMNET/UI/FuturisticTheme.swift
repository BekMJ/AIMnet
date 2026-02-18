import SwiftUI

enum FuturisticPalette {
    static let bgTop = Color(red: 0.03, green: 0.04, blue: 0.12)
    static let bgBottom = Color(red: 0.01, green: 0.02, blue: 0.06)
    static let cyan = Color(red: 0.22, green: 0.95, blue: 1.00)
    static let purple = Color(red: 0.63, green: 0.38, blue: 1.00)
    static let magenta = Color(red: 1.00, green: 0.28, blue: 0.79)
    static let warning = Color(red: 1.00, green: 0.63, blue: 0.20)
    static let success = Color(red: 0.25, green: 0.92, blue: 0.61)
    static let danger = Color(red: 1.00, green: 0.31, blue: 0.43)
}

struct FuturisticBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [FuturisticPalette.bgTop, FuturisticPalette.bgBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    FuturisticPalette.purple.opacity(0.35),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 420
            )

            RadialGradient(
                colors: [
                    FuturisticPalette.cyan.opacity(0.22),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 8,
                endRadius: 360
            )
        }
        .overlay {
            Rectangle()
                .fill(.white.opacity(0.02))
                .mask {
                    VStack(spacing: 10) {
                        ForEach(0..<120, id: \.self) { _ in
                            Rectangle().frame(height: 1)
                        }
                    }
                }
                .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }
}

struct FuturisticPanel<Content: View>: View {
    let title: String
    let icon: String?
    @ViewBuilder let content: Content

    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FuturisticPalette.cyan)
                }
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
            }

            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.12), .white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            FuturisticPalette.cyan.opacity(0.70),
                            FuturisticPalette.purple.opacity(0.60),
                            FuturisticPalette.magenta.opacity(0.55)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: FuturisticPalette.cyan.opacity(0.18), radius: 10, x: 0, y: 6)
    }
}

struct FuturisticMetricTile: View {
    let title: String
    let value: String
    var accent: Color = FuturisticPalette.cyan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.70))

            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(0.6), lineWidth: 1)
        )
    }
}

struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(color.opacity(0.22))
            )
            .overlay(
                Capsule()
                    .stroke(color.opacity(0.85), lineWidth: 1)
            )
    }
}

struct NeonButtonStyle: ButtonStyle {
    var tint: Color = FuturisticPalette.cyan
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1.0 : 0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(isEnabled ? 0.75 : 0.30),
                                FuturisticPalette.purple.opacity(isEnabled ? 0.75 : 0.30)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Capsule()
                    .stroke(tint.opacity(isEnabled ? 0.95 : 0.25), lineWidth: 1)
            )
            .shadow(
                color: tint.opacity(configuration.isPressed ? 0.15 : (isEnabled ? 0.38 : 0.05)),
                radius: configuration.isPressed ? 4 : 10,
                x: 0,
                y: configuration.isPressed ? 2 : 5
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

struct FuturisticToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.58))
            )
            .overlay(
                Capsule()
                    .stroke(FuturisticPalette.cyan.opacity(0.75), lineWidth: 1)
            )
            .shadow(color: FuturisticPalette.cyan.opacity(0.35), radius: 12, x: 0, y: 4)
    }
}
