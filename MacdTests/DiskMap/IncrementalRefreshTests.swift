import XCTest
@testable import Macd

/// Each test scans a real folder, changes it, refreshes only what changed, and checks the
/// result matches a fresh full scan.
@MainActor
final class IncrementalRefreshTests: XCTestCase {
    private func makeTree() throws -> TestFileTree {
        let tree = try TestFileTree()
        addTeardownBlock { tree.remove() }
        return tree
    }

    private func fullScan(_ tree: TestFileTree) throws -> DiskTree {
        try DiskScanner().scanBlocking(root: tree.path, options: ScanOptions(), progress: ScanProgress())
    }

    private func refresh(_ disk: DiskTree, _ changes: [FolderChange]) throws -> DiskTree {
        try IncrementalRefresher.apply(changes, to: disk, options: ScanOptions(), progress: ScanProgress())
    }

    /// Sizes and file counts of every path, for comparing two trees.
    private func summary(_ tree: DiskTree) -> [String: [UInt64]] {
        var result: [String: [UInt64]] = [:]
        for id in 0..<tree.count {
            result[tree.path(of: id)] = [tree.allocated[id], tree.apparent[id], tree.files[id]]
        }
        return result
    }

    private func seed(_ tree: TestFileTree) throws {
        try tree.file("a/one.bin", bytes: 2_000_000)
        try tree.file("a/deep/two.bin", bytes: 3_000_000)
        try tree.file("b/small.txt", bytes: 500)
        try tree.file("c/x/y/z.bin", bytes: 1_500_000)
    }

    func testAddedFileInKnownFolder() throws {
        let tree = try makeTree()
        try seed(tree)
        let before = try fullScan(tree)
        try tree.file("a/new.bin", bytes: 4_000_000)

        let refreshed = try refresh(before, [FolderChange(path: tree.path + "/a")])
        XCTAssertEqual(summary(refreshed), summary(try fullScan(tree)))
    }

    func testRemovedFolderDropsOut() throws {
        let tree = try makeTree()
        try seed(tree)
        let before = try fullScan(tree)
        try FileManager.default.removeItem(at: tree.url("c"))

        let refreshed = try refresh(before, [FolderChange(path: tree.path)])
        XCTAssertNil(refreshed.node(at: tree.path + "/c"))
        XCTAssertEqual(summary(refreshed), summary(try fullScan(tree)))
    }

    func testNewNestedFolderIsScannedFully() throws {
        let tree = try makeTree()
        try seed(tree)
        let before = try fullScan(tree)
        try tree.file("fresh/one/two/three.bin", bytes: 2_500_000)
        try tree.file("fresh/one/other.bin", bytes: 1_200_000)

        // FSEvents may only report the deepest folder; the nearest known ancestor is re-read.
        let refreshed = try refresh(before, [FolderChange(path: tree.path + "/fresh/one/two")])
        XCTAssertEqual(summary(refreshed), summary(try fullScan(tree)))
    }

    func testUnchangedSubfoldersAreKept() throws {
        let tree = try makeTree()
        try seed(tree)
        let before = try fullScan(tree)
        // Change a file below "a/deep" without reporting that folder: a one-level refresh of
        // "a" keeps "a/deep"'s old scan, which proves subfolders aren't re-read.
        try tree.file("a/deep/two.bin", bytes: 6_000_000)

        let refreshed = try refresh(before, [FolderChange(path: tree.path + "/a")])
        let deep = refreshed.node(at: tree.path + "/a/deep")!
        XCTAssertEqual(refreshed.allocated[deep], before.allocated[before.node(at: tree.path + "/a/deep")!])
    }

    func testRecursiveChangeRereadsEverythingBelow() throws {
        let tree = try makeTree()
        try seed(tree)
        let before = try fullScan(tree)
        try tree.file("a/deep/two.bin", bytes: 6_000_000)

        let refreshed = try refresh(before, [FolderChange(path: tree.path + "/a", recursive: true)])
        XCTAssertEqual(summary(refreshed), summary(try fullScan(tree)))
    }

    func testRefresherReusesItsCopyAcrossRefreshes() async throws {
        let tree = try makeTree()
        try seed(tree)
        let first = try fullScan(tree)
        let refresher = IncrementalRefresher()

        try tree.file("a/new.bin", bytes: 4_000_000)
        let second = try await refresher.refresh(first, changes: [FolderChange(path: tree.path + "/a")], options: ScanOptions(), progress: ScanProgress())
        try tree.file("b/more.bin", bytes: 2_000_000)
        try FileManager.default.removeItem(at: tree.url("c"))
        let third = try await refresher.refresh(second, changes: [FolderChange(path: tree.path + "/b"), FolderChange(path: tree.path)], options: ScanOptions(), progress: ScanProgress())

        XCTAssertEqual(summary(third), summary(try fullScan(tree)))
    }

    func testChangesOutsideRootAreIgnored() throws {
        let tree = try makeTree()
        try seed(tree)
        let before = try fullScan(tree)
        let refreshed = try refresh(before, [FolderChange(path: "/somewhere/else")])
        XCTAssertEqual(summary(refreshed), summary(before))
    }

    func testNormalizeDropsWhatARecursiveChangeCovers() {
        let changes = IncrementalRefresher.normalized([
            FolderChange(path: "/r/a/b/"),
            FolderChange(path: "/r/a", recursive: true),
            FolderChange(path: "/r/c"),
            FolderChange(path: "/r/c"),
            FolderChange(path: "/other"),
        ], root: "/r")
        XCTAssertEqual(changes, [FolderChange(path: "/r/a", recursive: true), FolderChange(path: "/r/c")])
    }
}

@MainActor
final class ScanCacheTests: XCTestCase {
    typealias F = TreeFixture

    private func sample() -> DiskTree {
        let root = F.dir("me", [
            F.dir("src", [F.dir("app", [F.file("main", 2_000_000)]), F.file("notes", 1_500_000)]),
            F.dir("Movies", [F.file("clip.mov", 9_000_000, modified: 42)]),
            F.dir("Photos Library.photoslibrary", flags: .package, [F.file("db", 1_000_000)]),
        ])
        root.addSmall(allocated: 300, apparent: 250, modified: 7)
        let locked = ScanDirectory(name: "Mail", device: 1, inode: 9, modified: 0)
        locked.state = .unreadable
        root.subdirectories.append(locked)
        return F.tree(root, at: "/Users/me")
    }

    private func scan(_ tree: DiskTree, options: ScanOptions = ScanOptions()) -> CachedScan {
        CachedScan(tree: tree, options: options, eventId: 12345, volumeUUID: "UUID", savedAt: Date(timeIntervalSince1970: 99))
    }

    func testCodecRoundTrip() throws {
        let tree = sample()
        let decoded = try ScanCodec.decode(try ScanCodec.encode(scan(tree)))
        XCTAssertEqual(decoded.tree.columns, tree.columns)
        XCTAssertEqual(decoded.tree.rootPath, "/Users/me")
        XCTAssertEqual(decoded.eventId, 12345)
        XCTAssertEqual(decoded.volumeUUID, "UUID")
        XCTAssertEqual(decoded.savedAt, Date(timeIntervalSince1970: 99))
        XCTAssertEqual(decoded.tree.unreadableCount, 1)
        XCTAssertNotNil(decoded.tree.node(at: "/Users/me/src/app/main"))
    }

    func testMirrorRebuildsTheSameTree() {
        let tree = sample()
        let rebuilt = DiskTree(rootPath: tree.rootPath, root: tree.makeMirror())
        XCTAssertEqual(rebuilt.columns, tree.columns)
    }

    func testCorruptDataIsRejected() {
        XCTAssertThrowsError(try ScanCodec.decode(Data("nonsense".utf8)))
        var data = try! ScanCodec.encode(scan(sample()))
        data.removeLast(40)
        XCTAssertThrowsError(try ScanCodec.decode(data))
    }

    func testDiskCacheKeysByRootAndOptions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macd-cache-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = DiskScanCache(directory: directory)
        cache.save(scan(sample()))

        XCTAssertNotNil(cache.load(root: "/Users/me", options: ScanOptions()))
        XCTAssertNil(cache.load(root: "/Users/me", options: ScanOptions(includeHidden: false)))
        XCTAssertNil(cache.load(root: "/Users/other", options: ScanOptions()))
    }
}

@MainActor
final class ChangeTrackerTests: XCTestCase {
    private func event(_ path: String, _ flags: Int, id: UInt64 = 1) -> EventStream.Event {
        EventStream.Event(path: path, flags: UInt32(flags), id: id)
    }

    func testEventsBecomeFolderChanges() {
        let (set, latest) = FSEventsChangeTracker.changeSet(from: [
            event("/Users/me/a/", 0, id: 5),
            event("/Users/me/b", kFSEventStreamEventFlagMustScanSubDirs, id: 9),
            event("/Users/me/Library/Caches/com.devesh.macd/DiskMap", 0, id: 7),
            event("", kFSEventStreamEventFlagHistoryDone, id: 10),
        ], ignoring: ["/Users/me/Library/Caches/com.devesh.macd/DiskMap"])
        XCTAssertEqual(set, .folders([FolderChange(path: "/Users/me/a"), FolderChange(path: "/Users/me/b", recursive: true)]))
        XCTAssertEqual(latest, 10)
    }

    func testDroppedEventsNeedAFullScan() {
        for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped] {
            let (set, _) = FSEventsChangeTracker.changeSet(from: [event("/x", flag)], ignoring: [])
            XCTAssertEqual(set, .needsFullScan)
        }
    }

    func testJournalFromTheFutureNeedsAFullScan() async {
        let tracker = FSEventsChangeTracker()
        let (set, _) = await tracker.changes(under: NSTemporaryDirectory(), since: UInt64.max - 1)
        XCTAssertEqual(set, .needsFullScan)
    }

    func testRealJournalReportsAChangedFolder() async throws {
        let tree = try TestFileTree()
        addTeardownBlock { tree.remove() }
        try tree.folder("watched")
        let tracker = FSEventsChangeTracker(ignoredPrefixes: [])
        let since = tracker.currentEventId()
        try tree.file("watched/new.bin", bytes: 1000)

        var found = false
        for _ in 0..<20 where !found {
            let (set, _) = await tracker.changes(under: tree.path, since: since)
            if case .folders(let folders) = set, folders.contains(where: { $0.path.hasSuffix("/watched") }) {
                found = true
            } else {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        XCTAssertTrue(found, "FSEvents history should report the folder that changed")
    }
}
