import XCTest
@testable import Macd

@MainActor
final class ReviewSummaryTests: XCTestCase {
    func testConfirmationNamesItemsAndTotal() {
        let text = RemovalSummary.confirmation([
            ("node_modules", 2_000_000_000), ("Old Movie.mov", 5_000_000_000), ("logs", 100_000_000),
        ])
        XCTAssertEqual(text, "Permanently delete 3 items (7.1 GB): Old Movie.mov, node_modules, logs. This can't be undone.")
    }

    func testConfirmationSummarisesTheRest() {
        let items = (1...5).map { ("item\($0)", UInt64($0) * 1_000_000) }
        let text = RemovalSummary.confirmation(items)
        XCTAssertTrue(text.contains("item5, item4, item3, and 2 more"))
    }
}
