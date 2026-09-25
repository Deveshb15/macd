import SwiftUI

/// mac'd's look: Liquid Glass on macOS 26, blur materials on earlier systems, one warm
/// accent for the main action, and gradients that say what each gauge measures.
enum Theme {
    static let accent = Color(red: 1.00, green: 0.66, blue: 0.24)
    static let accentDeep = Color(red: 0.98, green: 0.45, blue: 0.20)

    static let memoryGradient = [Color(red: 0.55, green: 0.42, blue: 1.00), Color(red: 0.93, green: 0.40, blue: 0.85)]
    static let diskGradient = [Color(red: 0.20, green: 0.62, blue: 1.00), Color(red: 0.25, green: 0.88, blue: 0.90)]

    /// Cool teal at idle, amber when warm, red when hot.
    static func temperatureGradient(_ celsius: Double?) -> [Color] {
        switch celsius ?? 0 {
        case ..<55: [Color(red: 0.20, green: 0.85, blue: 0.75), Color(red: 0.35, green: 0.75, blue: 1.00)]
        case ..<75: [Color(red: 1.00, green: 0.78, blue: 0.30), Color(red: 1.00, green: 0.55, blue: 0.25)]
        default: [Color(red: 1.00, green: 0.45, blue: 0.25), Color(red: 0.95, green: 0.20, blue: 0.30)]
        }
    }

    static func temperatureWord(_ celsius: Double?) -> String {
        guard let celsius else { return "no sensor" }
        switch celsius {
        case ..<55: return "cool"
        case ..<75: return "warm"
        default: return "hot"
        }
    }

    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
}

// MARK: Glass

extension View {
    /// Liquid Glass on macOS 26; a blurred material with a hairline edge before that.
    @ViewBuilder
    func macdGlass(in shape: some Shape = .rect(cornerRadius: 16), tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    /// Groups glass shapes so they blend and morph together on macOS 26.
    @ViewBuilder
    func macdGlassGroup(spacing: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// The one prominent action on a screen: warm glass with a soft glow.
struct PrimaryGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 34)
            .padding(.horizontal, 12)
            .background {
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .opacity(isEnabled ? 1 : 0.4)
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
            .shadow(color: Theme.accentDeep.opacity(isEnabled ? 0.45 : 0), radius: configuration.isPressed ? 4 : 10, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Everything that isn't the main action: quiet glass.
struct SecondaryGlassButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 10 : 12)
            .frame(minHeight: compact ? 26 : 34)
            .macdGlass(in: Capsule(), interactive: true)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A round glass icon button for headers and toolbars.
struct GlassIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .primary : .secondary)
        .macdGlass(in: Circle(), interactive: true)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: Gauges

/// A live ring gauge: gradient arc, rolling number, caption beneath.
struct RingGauge: View {
    let fraction: Double?
    let value: String
    let label: String
    let caption: String
    let colors: [Color]

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.08), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, fraction ?? 0)))
                    .stroke(
                        AngularGradient(colors: colors + [colors[0]], center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: colors.last!.opacity(0.45), radius: 5)
                    .animation(Theme.spring, value: fraction)
                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(Theme.spring, value: value)
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
