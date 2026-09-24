import Foundation
@testable import Macd

final class StubTemperature: TemperatureSource {
    var value: Double?
    init(_ value: Double?) { self.value = value }
    func cpuTemperature() -> Double? { value }
}

final class StubMemory: MemorySource {
    var value: MemoryUsage?
    init(_ value: MemoryUsage?) { self.value = value }
    func memoryUsage() -> MemoryUsage? { value }
}

final class StubDisk: DiskSource {
    var value: DiskUsage?
    init(_ value: DiskUsage?) { self.value = value }
    func diskUsage() -> DiskUsage? { value }
}
