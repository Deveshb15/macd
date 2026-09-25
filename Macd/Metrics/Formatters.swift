import Foundation

/// Display formatting for the menu bar and panel. Storage uses the system's file-size
/// style (decimal, as Finder shows it); memory uses binary units, as Activity Monitor does.
nonisolated enum Formatters {
    static let unavailable = "—"

    static func bytes(_ value: Int64) -> String {
        let clamped = max(value, 0)
        guard clamped > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: clamped, countStyle: .file)
    }

    static func bytes(_ value: UInt64) -> String {
        bytes(Int64(clamping: value))
    }

    /// RAM in binary gigabytes with at most one decimal: "43.1 GB", "64 GB".
    static func memory(_ value: UInt64) -> String {
        let gigabytes = Double(value) / 1_073_741_824
        if gigabytes >= 100 || gigabytes == gigabytes.rounded() {
            return "\(Int(gigabytes.rounded())) GB"
        }
        let rounded = (gigabytes * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) GB" : String(format: "%.1f GB", rounded)
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
}
