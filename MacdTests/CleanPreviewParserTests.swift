import XCTest
@testable import Macd

@MainActor
final class CleanPreviewParserTests: XCTestCase {
    private func fixture() throws -> [String] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mole-clean-dry-run-1.49.2", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").map(TerminalText.clean)
    }

    // Covers AE1.
    func testRealFixtureParsesIntoCategoriesWithTotal() throws {
        let preview = try CleanPreviewParser.parse(fixture())
        let names = Set(preview.categories.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["User essentials", "App caches", "Browsers", "Developer tools"]))
        XCTAssertEqual(preview.totalBytes, preview.categories.reduce(0) { $0 + $1.items.reduce(0) { $0 + ($1.bytes ?? 0) } })
        XCTAssertGreaterThan(preview.totalBytes, 1_000_000_000)
    }

    func testRealFixtureTotalMatchesMolesOwnEstimate() throws {
        // The fixture's summary says "Potential space: 47.11GB".
        let preview = try CleanPreviewParser.parse(fixture())
        XCTAssertEqual(Double(preview.totalBytes), 47_110_000_000, accuracy: 47_110_000_000 * 0.02)
    }

    func testRealFixtureSkipsAdminAndOpenApps() throws {
        let preview = try CleanPreviewParser.parse(fixture())
        XCTAssertTrue(preview.skipped.contains(CleanPreviewParser.adminSkip))
        XCTAssertTrue(preview.skipped.contains { $0.label == "Simulator, Xcode, Codex" })
        XCTAssertTrue(preview.skipped.contains { $0.label == "Docker unused data" })
    }

    func testCategoriesAndItemsSortLargestFirst() throws {
        let preview = try CleanPreviewParser.parse(fixture())
        XCTAssertEqual(preview.categories.map(\.totalBytes), preview.categories.map(\.totalBytes).sorted(by: >))
        for category in preview.categories {
            let sizes = category.items.map { $0.bytes ?? -1 }
            XCTAssertEqual(sizes, sizes.sorted(by: >), category.name)
        }
    }

    func testItemLineShapes() {
        XCTAssertEqual(
            CleanPreviewParser.parseItem("User app cache · 82 items, 14.90GB dry"),
            CleanItem(label: "User app cache", bytes: 14_900_000_000, itemCount: 82)
        )
        XCTAssertEqual(
            CleanPreviewParser.parseItem("Wallpaper agent cache · 139.4MB dry"),
            CleanItem(label: "Wallpaper agent cache", bytes: 139_400_000, itemCount: nil)
        )
        XCTAssertEqual(
            CleanPreviewParser.parseItem("Chrome Service Worker, would clean 46.0MB, 0 protected"),
            CleanItem(label: "Chrome Service Worker", bytes: 46_000_000, itemCount: nil)
        )
        XCTAssertEqual(
            CleanPreviewParser.parseItem("npm cache · would clean"),
            CleanItem(label: "npm cache", bytes: nil, itemCount: nil)
        )
        XCTAssertNil(CleanPreviewParser.parseItem("something unexpected"))
    }

    func testSizeUnits() {
        XCTAssertEqual(CleanPreviewParser.parseSize("193KB dry"), 193_000)
        XCTAssertEqual(CleanPreviewParser.parseSize("2.2MB dry"), 2_200_000)
        XCTAssertEqual(CleanPreviewParser.parseSize("1.5TB"), 1_500_000_000_000)
        XCTAssertEqual(CleanPreviewParser.parseSize("0B dry"), 0)
        XCTAssertNil(CleanPreviewParser.parseSize("would clean"))
    }

    func testZeroSizedItemsAreHiddenAndDuplicatesMerge() throws {
        let preview = try CleanPreviewParser.parse([
            "➤ App caches",
            "  → Wallpaper aerials temp files · 0B dry",
            "  → Next.js build cache · 3 items, 220.4MB dry",
            "  → Next.js build cache · 288.4MB dry",
        ])
        XCTAssertEqual(preview.categories.count, 1)
        XCTAssertEqual(preview.categories[0].items, [
            CleanItem(label: "Next.js build cache", bytes: 508_800_000, itemCount: 4),
        ])
    }

    // Covers AE3.
    func testAdminAndReviewItemsAreSkippedWithReasons() throws {
        let preview = try CleanPreviewParser.parse([
            "◎ System caches need sudo, run sudo -v && mo clean --dry-run for full preview",
            "➤ Developer tools",
            "  → Rust cargo cache · 93.0MB dry",
            "  ⊙ Docker unused data · review with docker system df",
        ])
        XCTAssertEqual(preview.skipped, [
            CleanPreviewParser.adminSkip,
            SkippedItem(label: "Docker unused data", reason: "review with docker system df"),
        ])
    }

    func testUnknownLinesAreIgnored() throws {
        let preview = try CleanPreviewParser.parse([
            "Clean Your Mac",
            "✓ Whitelist: 21 core patterns active",
            "  ↳ /Users/me/.gradle/caches/*",
            "➤ Browsers",
            "  → Chrome cache · 744.0MB dry",
            "  ✓ Nothing to clean",
            "some brand new line format",
        ])
        XCTAssertEqual(preview.totalBytes, 744_000_000)
    }

    func testOutputWithoutSectionsIsAFailure() {
        XCTAssertThrowsError(try CleanPreviewParser.parse(["bash: mole: command not found"])) { error in
            XCTAssertEqual(error as? CleanPreviewError, .unrecognizedOutput)
        }
    }
}
