import XCTest
@testable import Macd

@MainActor
final class DiskScannerTests: XCTestCase {
    private func makeTree() throws -> TestFileTree {
        let tree = try TestFileTree()
        addTeardownBlock { tree.remove() }
        return tree
    }

    private func scan(_ tree: TestFileTree, _ options: ScanOptions = ScanOptions()) async throws -> DiskTree {
        try await DiskScanner().scan(root: tree.path, options: options, progress: ScanProgress())
    }

    func testTotalMatchesLstatBlocks() async throws {
        let tree = try makeTree()
        for d in 0..<20 {
            for f in 0..<100 {
                try tree.file("d\(d)/sub\(f % 4)/f\(f).bin", bytes: 1 + (f * 37 + d * 11) % 9000)
            }
        }
        let result = try await scan(tree)
        XCTAssertEqual(result.allocated[DiskTree.root], tree.allocatedTotal())
        XCTAssertEqual(result.files[DiskTree.root], 2000)
    }

    func testHardlinkCountsOnceWhenDeduping() async throws {
        let tree = try makeTree()
        try tree.file("a/big.bin", bytes: 2_000_000)
        try tree.folder("b")
        try tree.hardlink("a/big.bin", "b/big.bin")

        let deduped = try await scan(tree)
        let doubled = try await scan(tree, ScanOptions(dedupeHardlinks: false))
        XCTAssertLessThan(deduped.allocated[DiskTree.root], 2_200_000)
        XCTAssertGreaterThan(doubled.allocated[DiskTree.root], 4_000_000)
    }

    func testSymlinkIsNotFollowed() async throws {
        let tree = try makeTree()
        try tree.file("real/big.bin", bytes: 3_000_000)
        try tree.symlink("link", to: tree.url("real").path)
        let result = try await scan(tree)
        let real = result.node(at: tree.path + "/real")!
        XCTAssertLessThan(result.allocated[DiskTree.root] - result.allocated[real], 100_000)
    }

    func testLockedFolderIsUnreadable() async throws {
        let tree = try makeTree()
        try tree.file("open/a.bin", bytes: 1000)
        let locked = try tree.folder("locked")
        try tree.file("locked/secret.bin", bytes: 1000)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

        let progress = ScanProgress()
        let result = try await DiskScanner().scan(root: tree.path, options: ScanOptions(), progress: progress)
        let node = result.node(at: locked.path)!
        XCTAssertEqual(result.kind[node], .unreadable)
        XCTAssertEqual(result.unreadableCount, 1)
        XCTAssertEqual(progress.unreadable.load(ordering: .relaxed), 1)
    }

    func testSmallFilesCollapseAndBigFilesStay() async throws {
        let tree = try makeTree()
        for i in 0..<5 { try tree.file("mix/small\(i).txt", bytes: 10_000) }
        try tree.file("mix/large.bin", bytes: 5_000_000)
        let result = try await scan(tree)
        let mix = result.node(at: tree.path + "/mix")!
        let names = result.children(of: mix).map { result.names[$0] }
        XCTAssertEqual(Set(names), ["large.bin", "5 smaller files"])
        let small = result.children(of: mix).first { result.kind[$0] == .smallFiles }!
        XCTAssertEqual(result.files[small], 5)
    }

    func testHiddenEntriesCanBeExcluded() async throws {
        let tree = try makeTree()
        try tree.file(".cache/blob.bin", bytes: 2_000_000)
        try tree.file("visible.bin", bytes: 2_000_000)
        let withHidden = try await scan(tree)
        let without = try await scan(tree, ScanOptions(includeHidden: false))
        XCTAssertNotNil(withHidden.node(at: tree.path + "/.cache"))
        XCTAssertNil(without.node(at: tree.path + "/.cache"))
        XCTAssertTrue(withHidden.flags[withHidden.node(at: tree.path + "/.cache")!].contains(.hidden))
    }

    func testPackageFlag() async throws {
        let tree = try makeTree()
        try tree.file("Tool.app/Contents/MacOS/tool", bytes: 100)
        let result = try await scan(tree)
        let app = result.node(at: tree.path + "/Tool.app")!
        XCTAssertTrue(result.flags[app].contains(.package))
        XCTAssertTrue(result.isInsidePackage(result.node(at: tree.path + "/Tool.app/Contents")!))
    }

    func testCancelStopsTheScan() async throws {
        let tree = try makeTree()
        for d in 0..<200 { try tree.file("d\(d)/f.bin", bytes: 10) }
        let progress = ScanProgress()
        progress.cancel()
        do {
            _ = try await DiskScanner().scan(root: tree.path, options: ScanOptions(), progress: progress)
            XCTFail("expected cancellation")
        } catch let error as ScanError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testMissingRootFails() async {
        do {
            _ = try await DiskScanner().scan(root: "/nonexistent-\(UUID())", options: ScanOptions(), progress: ScanProgress())
            XCTFail("expected failure")
        } catch let error as ScanError {
            if case .rootUnreadable = error {} else { XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }
}
