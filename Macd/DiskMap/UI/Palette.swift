import SwiftUI

/// Muted kind colours, amber for selection and what can be had back, red for what's marked.
enum Palette {
    static let background = Color(red: 0.09, green: 0.10, blue: 0.13)
    static let panel = Color(red: 0.12, green: 0.13, blue: 0.17)
    static let amber = Color(red: 0.95, green: 0.72, blue: 0.30)
    static let danger = Color(red: 0.86, green: 0.30, blue: 0.30)

    static func color(for category: Category) -> Color {
        switch category {
        case .code: Color(red: 0.33, green: 0.45, blue: 0.72)
        case .agentScratch: Color(red: 0.70, green: 0.46, blue: 0.30)
        case .toolchain: Color(red: 0.30, green: 0.58, blue: 0.42)
        case .synced: Color(red: 0.25, green: 0.58, blue: 0.63)
        case .git: Color(red: 0.68, green: 0.30, blue: 0.40)
        case .media: Color(red: 0.52, green: 0.37, blue: 0.68)
        case .documents: Color(red: 0.47, green: 0.49, blue: 0.54)
        case .cache: Color(red: 0.68, green: 0.60, blue: 0.30)
        case .other: Color(red: 0.32, green: 0.35, blue: 0.42)
        }
    }

    /// Age mode: last write from this week (bright) to years ago (dim).
    static func color(forAgeDays days: Int64) -> Color {
        switch days {
        case ..<7: Color(red: 0.95, green: 0.62, blue: 0.30)
        case ..<30: Color(red: 0.80, green: 0.55, blue: 0.35)
        case ..<90: Color(red: 0.55, green: 0.50, blue: 0.45)
        case ..<365: Color(red: 0.38, green: 0.44, blue: 0.55)
        default: Color(red: 0.26, green: 0.32, blue: 0.48)
        }
    }

    static let ageLegend: [(String, Color)] = [
        ("this week", color(forAgeDays: 0)), ("month", color(forAgeDays: 10)), ("quarter", color(forAgeDays: 40)),
        ("year", color(forAgeDays: 100)), ("older", color(forAgeDays: 400)),
    ]
}
