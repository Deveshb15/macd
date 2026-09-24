import XCTest
@testable import Macd

final class LowSpaceNotifierTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000

    private func run(_ freeGB: [Int64], threshold: Int64? = 20) -> [Int64] {
        var posted: [Int64] = []
        let notifier = LowSpaceNotifier(threshold: { threshold.map { $0 * self.gb } }, post: { posted.append($0 / self.gb) })
        freeGB.forEach { notifier.evaluate(freeBytes: $0 * gb) }
        return posted
    }

    // Covers AE4.
    func testFiresOnceWhenCrossingBelow() {
        XCTAssertEqual(run([25, 18, 17, 16]), [18])
    }

    func testDoesNotRefireInsideMargin() {
        XCTAssertEqual(run([18, 21, 18]), [18])
    }

    func testRefiresAfterRecoveringPastMargin() {
        XCTAssertEqual(run([18, 23, 18]), [18, 18])
    }

    func testOffNeverFires() {
        XCTAssertEqual(run([25, 5, 1], threshold: nil), [])
    }

    func testUnreadableDiskIsIgnored() {
        var posted = 0
        let notifier = LowSpaceNotifier(threshold: { 20 * self.gb }, post: { _ in posted += 1 })
        notifier.evaluate(freeBytes: nil)
        XCTAssertEqual(posted, 0)
        XCTAssertTrue(notifier.isArmed)
    }
}
