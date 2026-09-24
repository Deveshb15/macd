import XCTest
@testable import Macd

final class MetricsMonitorTests: XCTestCase {
    private let memory = MemoryUsage(usedBytes: 40_000_000_000, totalBytes: 64_000_000_000)
    private let disk = DiskUsage(freeBytes: 180_000_000_000, totalBytes: 1_000_000_000_000)

    // Covers AE5.
    func testUnreadableTemperatureIsUnavailable() {
        let monitor = MetricsMonitor(temperature: StubTemperature(nil), memory: StubMemory(memory), disk: StubDisk(disk))
        monitor.refresh()
        XCTAssertNil(monitor.snapshot.cpuTemperature)
        XCTAssertEqual(Formatters.temperature(monitor.snapshot.cpuTemperature), "—°")
    }

    func testMissingTemperatureSourceIsUnavailable() {
        let monitor = MetricsMonitor(temperature: nil, memory: StubMemory(memory), disk: StubDisk(disk))
        monitor.refresh()
        XCTAssertNil(monitor.snapshot.cpuTemperature)
    }

    func testImplausibleTemperaturesAreUnavailable() {
        for bad in [0.0, 200.0, -.infinity, .nan] {
            let monitor = MetricsMonitor(temperature: StubTemperature(bad), memory: StubMemory(memory), disk: StubDisk(disk))
            monitor.refresh()
            XCTAssertNil(monitor.snapshot.cpuTemperature, "\(bad) should be unavailable")
        }
    }

    func testOneFailingReaderDoesNotBlankOthers() {
        let monitor = MetricsMonitor(temperature: StubTemperature(48), memory: StubMemory(nil), disk: StubDisk(disk))
        monitor.refresh()
        XCTAssertEqual(monitor.snapshot.cpuTemperature, 48)
        XCTAssertNil(monitor.snapshot.memory)
        XCTAssertEqual(monitor.snapshot.disk, disk)
    }

    func testCadenceFollowsPanelState() {
        let monitor = MetricsMonitor(temperature: nil, memory: StubMemory(memory), disk: StubDisk(disk))
        XCTAssertEqual(monitor.interval, .seconds(5))
        monitor.setPanelOpen(true)
        XCTAssertEqual(monitor.interval, .seconds(1))
        monitor.setPanelOpen(false)
        XCTAssertEqual(monitor.interval, .seconds(5))
    }

    func testRefreshNotifiesObserver() {
        let monitor = MetricsMonitor(temperature: nil, memory: StubMemory(memory), disk: StubDisk(disk))
        var received: MetricsSnapshot?
        monitor.onRefresh = { received = $0 }
        monitor.refresh()
        XCTAssertEqual(received?.disk, disk)
    }

    func testCPUSensorNames() {
        XCTAssertTrue(TemperatureReader.isCPUSensor("PMU tdie3"))
        XCTAssertTrue(TemperatureReader.isCPUSensor("pACC MTR Temp Sensor2"))
        XCTAssertTrue(TemperatureReader.isCPUSensor("eACC MTR Temp Sensor0"))
        XCTAssertFalse(TemperatureReader.isCPUSensor("PMU tcal"))
        XCTAssertFalse(TemperatureReader.isCPUSensor("NAND CH0 temp"))
        XCTAssertFalse(TemperatureReader.isCPUSensor("gas gauge battery"))
    }
}
