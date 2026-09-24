import Foundation

/// Reads free space on the home volume. "Important usage" capacity counts purgeable
/// space, which matches the number Finder shows.
struct DiskReader: DiskSource {
    var volumeURL: URL = FileManager.default.homeDirectoryForCurrentUser

    func diskUsage() -> DiskUsage? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]
        guard
            let values = try? volumeURL.resourceValues(forKeys: keys),
            let free = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity,
            total > 0
        else { return nil }
        return DiskUsage(freeBytes: free, totalBytes: Int64(total))
    }
}
