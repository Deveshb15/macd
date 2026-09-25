import XCTest
@testable import Macd

@MainActor
final class FormattersTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(Formatters.bytes(Int64(18_000_000_000)), "18 GB")
        XCTAssertEqual(Formatters.bytes(Int64(999_000_000)), "999 MB")
        XCTAssertEqual(Formatters.bytes(Int64(4_200_000_000)), "4.2 GB")
        XCTAssertEqual(Formatters.bytes(Int64(180_300_000_000)), "180.3 GB")
        XCTAssertEqual(Formatters.bytes(Int64(9_960_000_000)), "9.96 GB")
        XCTAssertEqual(Formatters.bytes(Int64(1_008_680_000_000)), "1.01 TB", "doesn't round 1.01 TB down to 1 TB")
        XCTAssertEqual(Formatters.bytes(Int64(512)), "512 bytes")
        XCTAssertEqual(Formatters.bytes(Int64(0)), "0 KB")
        XCTAssertEqual(Formatters.bytes(Int64(-10)), "0 KB")
    }

    func testMemoryUsesBinaryUnits() {
        XCTAssertEqual(Formatters.memory(68_719_476_736), "64 GB", "64 GB of RAM is not 69 GB")
        XCTAssertEqual(Formatters.memory(46_300_000_000), "43.1 GB")
        XCTAssertEqual(Formatters.memory(8_589_934_592), "8 GB")
    }

    func testTemperature() {
        XCTAssertEqual(Formatters.temperature(42.6), "43°")
        XCTAssertEqual(Formatters.temperature(nil), "—°")
    }

    func testPercent() {
        XCTAssertEqual(Formatters.percent(0.614), "61%")
        XCTAssertEqual(Formatters.percent(nil), "—%")
    }

    func testDiskFree() {
        XCTAssertEqual(Formatters.diskFree(DiskUsage(freeBytes: 180_000_000_000, totalBytes: 1_000_000_000_000)), "180 GB")
        XCTAssertEqual(Formatters.diskFree(nil), "— GB")
    }
}
