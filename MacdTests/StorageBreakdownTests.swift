import XCTest
@testable import Macd

@MainActor
final class StorageBreakdownTests: XCTestCase {
    typealias F = TreeFixture
    private let disk = DiskUsage(freeBytes: 400, totalBytes: 1000)

    func testWithoutScanShowsUsedAsOneSegment() {
        let segments = StorageBreakdown.segments(disk: disk, tree: nil)
        XCTAssertEqual(segments.map(\.bytes), [600])
    }

    func testScanSplitsHomeByKindAndAddsSystem() {
        let tree = F.tree(F.dir("me", [
            F.dir("src", [F.file("a", 200)]),
            F.dir(".cache", [F.file("b", 100)]),
            F.dir("stuff", [F.file("c", 50)]),
        ]), at: "/Users/me")
        Classifier.classify(tree)
        let segments = StorageBreakdown.segments(disk: disk, tree: tree)
        XCTAssertEqual(segments.map(\.label), ["Code", "Cache", "Other files", "macOS & apps"])
        XCTAssertEqual(segments.map(\.bytes), [200, 100, 50, 250])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.bytes }, 600, "segments add up to used space")
    }

    func testHomeLargerThanUsedNeverGoesNegative() {
        let tree = F.tree(F.dir("me", [F.dir("src", [F.file("a", 900)])]), at: "/Users/me")
        Classifier.classify(tree)
        let segments = StorageBreakdown.segments(disk: disk, tree: tree)
        XCTAssertTrue(segments.allSatisfy { $0.bytes >= 0 })
    }
}
