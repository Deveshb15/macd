import XCTest
@testable import Macd

@MainActor
final class MenuBarLabelTests: XCTestCase {
    private let snapshot = MetricsSnapshot(
        cpuTemperature: nil,
        memory: MemoryUsage(usedBytes: 61, totalBytes: 100),
        disk: DiskUsage(freeBytes: 180_000_000_000, totalBytes: 1_000_000_000_000)
    )

    func testOnlyDisk() {
        XCTAssertEqual(MenuBarText.compose(snapshot, showTemperature: false, showMemory: false, showDisk: true), "180 GB")
    }

    func testAllDisabledFallsBackToIcon() {
        XCTAssertNil(MenuBarText.compose(snapshot, showTemperature: false, showMemory: false, showDisk: false))
    }

    func testUnavailableTemperatureWithOthers() {
        XCTAssertEqual(MenuBarText.compose(snapshot, showTemperature: true, showMemory: true, showDisk: true), "—°  61%  180 GB")
    }
}
