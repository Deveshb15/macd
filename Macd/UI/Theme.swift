import SwiftUI

/// mac'd stays close to native macOS: system materials and buttons, monospaced numbers,
/// and colour only as a signal when something needs attention.
enum Signal {
    case normal, warning, critical

    var color: Color {
        switch self {
        case .normal: .primary
        case .warning: .orange
        case .critical: .red
        }
    }

    static func temperature(_ celsius: Double?) -> Signal {
        switch celsius ?? 0 {
        case 90...: .critical
        case 80...: .warning
        default: .normal
        }
    }

    static func memory(_ fraction: Double?) -> Signal {
        (fraction ?? 0) >= 0.9 ? .warning : .normal
    }

    static func disk(free: Int64?, threshold: Int64?) -> Signal {
        guard let free, let threshold else { return .normal }
        return free < threshold ? .warning : .normal
    }
}

/// A thin proportion bar. Neutral unless it signals a problem.
///
/// Uses concrete label colours rather than `.primary`: on the menu bar panel's vibrant
/// material, hierarchical styles blend into each other and the fill disappears.
struct Meter: View {
    let fraction: Double
    var signal: Signal = .normal

    private static let label = Color(nsColor: .labelColor)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Self.label.opacity(0.14))
                Capsule()
                    .fill(signal == .normal ? Self.label.opacity(0.85) : signal.color)
                    .frame(width: max(4, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// A full-width row that highlights on hover, like a native menu item.
struct MenuRow: View {
    let title: String
    var trailing: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let trailing {
                    Text(trailing).foregroundStyle(hovering ? .white.opacity(0.8) : .secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .contentShape(Rectangle())
            .foregroundStyle(hovering ? .white : .primary)
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
