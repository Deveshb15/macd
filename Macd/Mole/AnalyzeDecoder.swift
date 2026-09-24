import Foundation

nonisolated struct DiskEntry: Equatable, Sendable, Identifiable {
    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool

    var id: String { path }
}

nonisolated struct DiskListing: Equatable, Sendable {
    let path: String
    let totalSize: Int64
    /// Largest first; equal sizes sort by name.
    let entries: [DiskEntry]
}

/// Decodes `mole analyze -json <path>`, which describes one folder level per call.
nonisolated enum AnalyzeDecoder {
    private struct Payload: Decodable {
        struct Entry: Decodable {
            let name: String
            let path: String
            let size: Int64
            let is_dir: Bool
        }

        let path: String
        let entries: [Entry]?
        let total_size: Int64?
    }

    static func decode(_ data: Data) throws -> DiskListing {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let entries = (payload.entries ?? [])
            .map { DiskEntry(name: $0.name, path: $0.path, size: $0.size, isDirectory: $0.is_dir) }
            .sorted { lhs, rhs in
                lhs.size != rhs.size
                    ? lhs.size > rhs.size
                    : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        let total = payload.total_size ?? entries.reduce(0) { $0 + $1.size }
        return DiskListing(path: payload.path, totalSize: total, entries: entries)
    }

    /// Mole prints the JSON document to stdout; anything before the first "{" is ignored.
    static func decode(lines: [String]) throws -> DiskListing {
        let text = lines.joined(separator: "\n")
        guard let start = text.firstIndex(of: "{") else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No JSON in analyze output"))
        }
        return try decode(Data(text[start...].utf8))
    }
}
