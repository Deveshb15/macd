import XCTest
@testable import Macd

@MainActor
final class FormattersTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(Formatters.bytes(Int64(18_000_000_000)), "18 GB")
        XCTAssertEqual(Formatters.bytes(Int64(999_000_000)), "999 MB")
        XCTAssertEqual(Formatters.bytes(Int64(4_200_000_000)), "4.2 GB")
        XCTAssertEqual(Formatters.bytes(Int64(180_300_000_000)), "180 GB")
        XCTAssertEqual(Formatters.bytes(Int64(9_960_000_000)), "10 GB")
        XCTAssertEqual(Formatters.bytes(Int64(1_500)), "1.5 KB")
        XCTAssertEqual(Formatters.bytes(Int64(512)), "512 B")
        XCTAssertEqual(Formatters.bytes(Int64(0)), "0 B")
        XCTAssertEqual(Formatters.bytes(Int64(-10)), "0 B")
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
