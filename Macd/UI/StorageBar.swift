import SwiftUI

struct StorageSegment: Identifiable, Equatable {
    let id: String
    let label: String
    let bytes: Int64
    let color: Color
}

/// What fills the disk, for the panel's storage bar. With a disk map scan it splits the
/// home folder by kind of data; without one it shows used space as one segment.
enum StorageBreakdown {
    static let maxCategories = 4

    static func segments(disk: DiskUsage, tree: DiskTree?) -> [StorageSegment] {
        let used = max(0, disk.totalBytes - disk.freeBytes)
        guard let tree else {
            return [StorageSegment(id: "used", label: "Used", bytes: used, color: Theme.diskGradient[0])]
        }
        var byCategory: [Category: Int64] = [:]
        for child in tree.children(of: DiskTree.root) {
            byCategory[tree.category[child], default: 0] += Int64(clamping: tree.allocated[child])
        }
        let ranked = byCategory
            .filter { $0.key != .other && $0.value > 0 }
            .sorted { $0.value > $1.value }
        var segments = ranked.prefix(maxCategories).map {
            StorageSegment(id: $0.key.label, label: $0.key.label, bytes: $0.value, color: Palette.color(for: $0.key))
        }
        let homeTotal = Int64(clamping: tree.allocated[DiskTree.root])
        let shown = segments.reduce(0) { $0 + $1.bytes }
        let otherHome = max(0, min(homeTotal, used) - shown)
        if otherHome > 0 {
            segments.append(StorageSegment(id: "other", label: "Other files", bytes: otherHome, color: Palette.color(for: .other)))
        }
        let system = max(0, used - shown - otherHome)
        if system > 0 {
            segments.append(StorageSegment(id: "system", label: "macOS & apps", bytes: system, color: .gray.opacity(0.55)))
        }
        return segments
    }
}

/// A segmented capsule: coloured used space, empty track for what's free.
struct StorageBar: View {
    let disk: DiskUsage
    let segments: [StorageSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let total = max(1, Double(disk.totalBytes))
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        let width = geometry.size.width * Double(segment.bytes) / total
                        if width >= 2 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(segment.color.gradient)
                                .frame(width: width - 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .background(Capsule().fill(.primary.opacity(0.08)))
                .clipShape(Capsule())
            }
            .frame(height: 10)
            .animation(Theme.spring, value: segments)

            HStack(spacing: 10) {
                ForEach(segments.prefix(3)) { segment in
                    HStack(spacing: 4) {
                        Circle().fill(segment.color).frame(width: 6, height: 6)
                        Text(segment.label).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text("\(Formatters.bytes(disk.freeBytes)) free")
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}
