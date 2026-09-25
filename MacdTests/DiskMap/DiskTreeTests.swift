import XCTest
@testable import Macd

/// Builds `ScanDirectory` trees in tests without touching the disk.
enum TreeFixture {
    static func dir(_ name: String, modified: Int64 = 0, flags: NodeFlags = [], _ children: [Any] = []) -> ScanDirectory {
        let directory = ScanDirectory(name: name, device: 1, inode: UInt64(abs(name.hashValue % 1_000_000)), modified: modified, flags: flags)
        directory.state = .read
        for child in children {
            if let sub = child as? ScanDirectory {
                directory.subdirectories.append(sub)
            } else if let file = child as? ScanFile {
                directory.files.append(file)
            }
        }
        return directory
    }

    static func file(_ name: String, _ bytes: UInt64, apparent: UInt64? = nil, modified: Int64 = 0) -> ScanFile {
        ScanFile(name: name, allocated: bytes, apparent: apparent ?? bytes, modified: modified, device: 1, inode: 0, flags: [])
    }

    static func tree(_ root: ScanDirectory, at path: String = "/home/me") -> DiskTree {
        DiskTree(rootPath: path, root: root)
    }
}

@MainActor
final class DiskTreeTests: XCTestCase {
    typealias F = TreeFixture

    func testAggregatesFilesIntoFolder() {
        let tree = F.tree(F.dir("me", [F.file("a", 10, modified: 5), F.file("b", 20, modified: 9), F.file("c", 30, modified: 7)]))
        XCTAssertEqual(tree.allocated[DiskTree.root], 60)
        XCTAssertEqual(tree.files[DiskTree.root], 3)
        XCTAssertEqual(tree.newest[DiskTree.root], 9)
    }

    func testNestedAggregationAtEveryLevel() {
        let tree = F.tree(F.dir("me", [
            F.dir("src", [F.dir("app", [F.file("x", 100)]), F.file("y", 5)]),
            F.dir("docs", [F.file("z", 7)]),
        ]))
        let src = tree.node(at: "/home/me/src")!
        let app = tree.node(at: "/home/me/src/app")!
        XCTAssertEqual(tree.allocated[app], 100)
        XCTAssertEqual(tree.allocated[src], 105)
        XCTAssertEqual(tree.allocated[DiskTree.root], 112)
    }

    func testMetricChangesChildOrder() {
        let many = (0..<10).map { F.file("f\($0)", 1) }
        let tree = F.tree(F.dir("me", [F.dir("few", [F.file("big", 1000)]), F.dir("many", many)]))
        let bySize = tree.sortedChildren(of: DiskTree.root, by: .allocated).map { tree.names[$0] }
        let byCount = tree.sortedChildren(of: DiskTree.root, by: .files).map { tree.names[$0] }
        XCTAssertEqual(bySize, ["few", "many"])
        XCTAssertEqual(byCount, ["many", "few"])
    }

    func testApparentSizeIsTrackedSeparately() {
        let tree = F.tree(F.dir("me", [F.file("sparse", 4096, apparent: 1_000_000)]))
        XCTAssertEqual(tree.allocated[DiskTree.root], 4096)
        XCTAssertEqual(tree.apparent[DiskTree.root], 1_000_000)
    }

    func testPathRoundTrip() {
        let tree = F.tree(F.dir("me", [F.dir("a", [F.dir("b", [F.dir("c", [F.file("deep", 1)])])])]))
        let deep = tree.node(at: "/home/me/a/b/c/deep")!
        XCTAssertEqual(tree.path(of: deep), "/home/me/a/b/c/deep")
        XCTAssertEqual(tree.node(at: tree.path(of: deep)), deep)
        XCTAssertEqual(tree.path(of: DiskTree.root), "/home/me")
        XCTAssertNil(tree.node(at: "/home/other"))
        XCTAssertNil(tree.node(at: "/home/me/missing"))
    }

    func testUnreadableChildIsListedWithZeroSize() {
        let locked = ScanDirectory(name: "Mail", device: 1, inode: 9, modified: 0)
        locked.state = .unreadable
        let tree = F.tree(F.dir("me", [locked, F.file("a", 10)]))
        let mail = tree.node(at: "/home/me/Mail")!
        XCTAssertEqual(tree.kind[mail], .unreadable)
        XCTAssertEqual(tree.allocated[mail], 0)
        XCTAssertEqual(tree.unreadableCount, 1)
        XCTAssertEqual(tree.allocated[DiskTree.root], 10)
    }

    func testSmallFilesBecomeOneNode() {
        let root = F.dir("me")
        root.addSmall(allocated: 100, apparent: 90, modified: 3)
        root.addSmall(allocated: 200, apparent: 180, modified: 8)
        let tree = F.tree(root)
        let small = tree.children(of: DiskTree.root).first!
        XCTAssertEqual(tree.kind[small], .smallFiles)
        XCTAssertEqual(tree.names[small], "2 smaller files")
        XCTAssertEqual(tree.allocated[small], 300)
        XCTAssertEqual(tree.files[small], 2)
    }

    func testEmptyFolder() {
        let tree = F.tree(F.dir("me", [F.dir("empty")]))
        let empty = tree.node(at: "/home/me/empty")!
        XCTAssertEqual(tree.allocated[empty], 0)
        XCTAssertTrue(tree.children(of: empty).isEmpty)
    }

    func testInsidePackage() {
        let tree = F.tree(F.dir("me", [F.dir("Photos Library.photoslibrary", flags: .package, [F.dir("originals", [F.file("p", 1)])])]))
        let library = tree.node(at: "/home/me/Photos Library.photoslibrary")!
        let originals = tree.node(at: "/home/me/Photos Library.photoslibrary/originals")!
        XCTAssertFalse(tree.isInsidePackage(library))
        XCTAssertTrue(tree.isInsidePackage(originals))
    }

    func testMillionNodesBuildQuickly() {
        let root = F.dir("me")
        for d in 0..<1000 {
            root.subdirectories.append(F.dir("d\(d)", (0..<999).map { F.file("f\($0)", UInt64($0)) }))
        }
        let start = Date()
        let tree = F.tree(root)
        XCTAssertEqual(tree.count, 1 + 1000 + 999_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
