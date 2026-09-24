import Foundation

struct CleanItem: Equatable, Sendable {
    let label: String
    /// `nil` when Mole will clean it but did not report a size.
    var bytes: Int64?
    var itemCount: Int?
}

struct CleanCategory: Equatable, Sendable {
    let name: String
    var items: [CleanItem]

    var totalBytes: Int64 { items.reduce(0) { $0 + ($1.bytes ?? 0) } }
}

struct SkippedItem: Equatable, Sendable {
    let label: String
    let reason: String
}

struct CleanPreview: Equatable, Sendable {
    var categories: [CleanCategory]
    var skipped: [SkippedItem]

    var totalBytes: Int64 { categories.reduce(0) { $0 + $1.totalBytes } }
}

enum CleanPreviewError: Error, Equatable {
    case unrecognizedOutput
}

/// Turns `mole clean --dry-run` text output (Mole 1.49.x) into a `CleanPreview`.
///
/// Recognized lines:
/// - `➤ Browsers` starts a category
/// - `→ Chrome cache · 6 items, 744.0MB dry` / `→ Chrome Service Worker, would clean 46.0MB, 0 protected` / `→ npm cache · would clean`
/// - `⊙ Docker unused data · review with docker system df` is skipped, with its reason
/// - `◎ System caches need sudo, …` or `System-level cleanup skipped` is skipped as admin-only
/// - `Skipped while active: Simulator, Xcode` is skipped because those apps are open
/// Everything else is ignored.
nonisolated enum CleanPreviewParser {
    static let adminSkip = SkippedItem(label: "System caches", reason: "Needs an administrator password")

    static func parse(_ lines: [String]) throws -> CleanPreview {
        var categories: [CleanCategory] = []
        var skipped: [SkippedItem] = []
        var sawSection = false

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("➤") {
                sawSection = true
                let name = line.dropFirst().trimmingCharacters(in: .whitespaces)
                categories.append(CleanCategory(name: name, items: []))
            } else if line.hasPrefix("→") {
                guard !categories.isEmpty, let item = parseItem(String(line.dropFirst())) else { continue }
                add(item, to: &categories[categories.count - 1])
            } else if line.hasPrefix("⊙") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                let parts = body.components(separatedBy: " · ")
                skipped.append(SkippedItem(label: parts[0], reason: parts.dropFirst().joined(separator: " · ")))
            } else if line.hasPrefix("Skipped while active:") {
                let apps = line.dropFirst("Skipped while active:".count).trimmingCharacters(in: .whitespaces)
                if !apps.isEmpty { skipped.append(SkippedItem(label: apps, reason: "Open right now. Quit to include them")) }
            } else if line.contains("need sudo") || line.contains("requires sudo") {
                if !skipped.contains(adminSkip) { skipped.append(adminSkip) }
            }
        }

        guard sawSection else { throw CleanPreviewError.unrecognizedOutput }

        let visible = categories
            .map { category in
                var category = category
                category.items = category.items
                    .filter { $0.bytes != 0 }
                    .sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
                return category
            }
            .filter { !$0.items.isEmpty }
            .sorted { $0.totalBytes > $1.totalBytes }
        return CleanPreview(categories: visible, skipped: skipped)
    }

    /// Items with the same label in one category (for example several "Next.js build cache" folders) merge into one row.
    private static func add(_ item: CleanItem, to category: inout CleanCategory) {
        guard let index = category.items.firstIndex(where: { $0.label == item.label }) else {
            category.items.append(item)
            return
        }
        var existing = category.items[index]
        if item.bytes != nil || existing.bytes != nil {
            existing.bytes = (existing.bytes ?? 0) + (item.bytes ?? 0)
        }
        if item.itemCount != nil || existing.itemCount != nil {
            existing.itemCount = (existing.itemCount ?? 1) + (item.itemCount ?? 1)
        }
        category.items[index] = existing
    }

    static func parseItem(_ text: String) -> CleanItem? {
        let body = text.trimmingCharacters(in: .whitespaces)
        let label: String
        let detail: String
        if let range = body.range(of: " · ") {
            label = String(body[..<range.lowerBound])
            detail = String(body[range.upperBound...])
        } else if let range = body.range(of: ", would clean") {
            label = String(body[..<range.lowerBound])
            detail = String(body[range.lowerBound...])
        } else {
            return nil
        }
        guard !label.isEmpty else { return nil }
        return CleanItem(label: label, bytes: parseSize(detail), itemCount: parseCount(detail))
    }

    static func parseSize(_ text: String) -> Int64? {
        let pattern = #/(\d+(?:\.\d+)?)\s*(TB|GB|MB|KB|B)\b/#
        guard let match = text.firstMatch(of: pattern), let value = Double(match.1) else { return nil }
        let scale: Double = switch match.2 {
        case "TB": 1e12
        case "GB": 1e9
        case "MB": 1e6
        case "KB": 1e3
        default: 1
        }
        return Int64((value * scale).rounded())
    }

    static func parseCount(_ text: String) -> Int? {
        guard let match = text.firstMatch(of: #/(\d+) items?\b/#) else { return nil }
        return Int(match.1)
    }
}
