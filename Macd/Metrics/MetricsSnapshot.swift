import Foundation

nonisolated struct MemoryUsage: Equatable, Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64

    var fraction: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes)
    }
}

nonisolated struct DiskUsage: Equatable, Sendable {
    let freeBytes: Int64
    let totalBytes: Int64

    var usedFraction: Double {
        totalBytes <= 0 ? 0 : Double(totalBytes - freeBytes) / Double(totalBytes)
    }
}

/// One reading of every metric. A `nil` field means that metric could not be read.
nonisolated struct MetricsSnapshot: Equatable, Sendable {
    var cpuTemperature: Double?
    var memory: MemoryUsage?
    var disk: DiskUsage?

    static let empty = MetricsSnapshot()
}

protocol TemperatureSource {
    /// Average CPU die temperature in °C, or `nil` when no sensor can be read.
    func cpuTemperature() -> Double?
}

protocol MemorySource {
    func memoryUsage() -> MemoryUsage?
}

protocol DiskSource {
    func diskUsage() -> DiskUsage?
}
