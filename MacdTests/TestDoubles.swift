import Foundation
@testable import Macd

@MainActor
final class StubTemperature: TemperatureSource {
    var value: Double?
    init(_ value: Double?) { self.value = value }
    func cpuTemperature() -> Double? { value }
}

@MainActor
final class StubMemory: MemorySource {
    var value: MemoryUsage?
    init(_ value: MemoryUsage?) { self.value = value }
    func memoryUsage() -> MemoryUsage? { value }
}

@MainActor
final class StubDisk: DiskSource {
    var value: DiskUsage?
    init(_ value: DiskUsage?) { self.value = value }
    func diskUsage() -> DiskUsage? { value }
}
