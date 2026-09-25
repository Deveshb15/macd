import XCTest
@testable import Macd

@MainActor
final class RemovalExecutorTests: XCTestCase {
    private func makeTree() throws -> TestFileTree {
        let tree = try TestFileTree()
        addTeardownBlock { tree.remove() }
        return tree
    }

    private func target(_ url: URL) -> RemovalTarget {
        var info = stat()
        lstat(url.path, &info)
        return RemovalTarget(path: url.path, device: info.st_dev, inode: UInt64(info.st_ino), bytes: 0,
                             isSymlink: (info.st_mode & S_IFMT) == S_IFLNK)
    }

    func testPermanentDeleteRemovesFolderAndKeepsSibling() async throws {
        let tree = try makeTree()
        let doomed = try tree.folder("doomed")
        try tree.file("doomed/inner/a.bin", bytes: 100)
        try tree.file("keep/b.bin", bytes: 100)
        let outcomes = await RemovalExecutor().remove([target(doomed)], mode: .permanent)
        XCTAssertNil(outcomes[0].failure)
        XCTAssertFalse(tree.exists("doomed"))
        XCTAssertTrue(tree.exists("keep/b.bin"))
    }

    func testTrashMovesItemToTrash() async throws {
        let tree = try makeTree()
        let item = try tree.file("to-trash-\(UUID().uuidString).txt", bytes: 10)
        let outcomes = await RemovalExecutor().remove([target(item)], mode: .trash)
        XCTAssertNil(outcomes[0].failure)
        XCTAssertFalse(tree.exists(item.lastPathComponent))
        // Clean up the Trash copy this test made.
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(item.lastPathComponent)")
        try? FileManager.default.removeItem(at: trashed)
    }

    func testSymlinkIsRemovedNotFollowed() async throws {
        let tree = try makeTree()
        let outside = try TestFileTree()
        addTeardownBlock { outside.remove() }
        try outside.file("precious/data.bin", bytes: 100)
        try tree.symlink("link", to: outside.url("precious").path)
        let outcomes = await RemovalExecutor().remove([target(tree.url("link"))], mode: .permanent)
        XCTAssertNil(outcomes[0].failure)
        XCTAssertFalse(tree.exists("link"))
        XCTAssertTrue(outside.exists("precious/data.bin"))
    }

    func testChangedSinceScanIsSkipped() async throws {
        let tree = try makeTree()
        let file = try tree.file("swap.bin", bytes: 10)
        let stale = target(file)
        try FileManager.default.removeItem(at: file)
        try tree.file("swap.bin", bytes: 10)
        let outcomes = await RemovalExecutor().remove([stale], mode: .permanent)
        XCTAssertEqual(outcomes[0].failure, "changed since the scan; rescan and try again")
        XCTAssertTrue(tree.exists("swap.bin"))
    }

    func testOneFailureDoesNotStopOthers() async throws {
        let tree = try makeTree()
        let lockedParent = try tree.folder("locked")
        let stuck = try tree.file("locked/stuck.bin", bytes: 10)
        let free = try tree.file("free.bin", bytes: 10)
        let stuckTarget = target(stuck)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedParent.path)
        let outcomes = await RemovalExecutor().remove([stuckTarget, target(free)], mode: .permanent)
        XCTAssertNotNil(outcomes[0].failure)
        XCTAssertNil(outcomes[1].failure)
        XCTAssertFalse(tree.exists("free.bin"))
    }

    func testDashNamedFileIsJustAFile() async throws {
        let tree = try makeTree()
        let odd = try tree.file("-rf", bytes: 10)
        try tree.file("sibling.bin", bytes: 10)
        let outcomes = await RemovalExecutor().remove([target(odd)], mode: .permanent)
        XCTAssertNil(outcomes[0].failure)
        XCTAssertFalse(tree.exists("-rf"))
        XCTAssertTrue(tree.exists("sibling.bin"))
    }
}
