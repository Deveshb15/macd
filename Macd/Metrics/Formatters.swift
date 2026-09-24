import Foundation

/// Display formatting for the menu bar and panel. Sizes are decimal (1 GB = 10⁹ bytes),
/// matching Finder and Mole.
nonisolated enum Formatters {
    static let unavailable = "—"

    static func bytes(_ value: Int64) -> String {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3)]
        let magnitude = Double(max(value, 0))
        for (unit, scale) in units where magnitude >= scale {
            return "\(trimmed(magnitude / scale)) \(unit)"
        }
        return "\(max(value, 0)) B"
    }

    static func bytes(_ value: UInt64) -> String {
        bytes(Int64(clamping: value))
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "\(unavailable)°" }
        return "\(Int(celsius.rounded()))°"
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "\(unavailable)%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func diskFree(_ disk: DiskUsage?) -> String {
        guard let disk else { return "\(unavailable) GB" }
        return bytes(disk.freeBytes)
    }

    /// One decimal below 10 (dropping ".0"), whole numbers from 10 up.
    private static func trimmed(_ value: Double) -> String {
        if value >= 10 {
            return String(Int(value.rounded()))
        }
        let rounded = (value * 10).rounded() / 10
        if rounded >= 10 {
            return String(Int(rounded))
        }
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
