import XCTest
@testable import Macd

@MainActor
final class RemovalPlannerTests: XCTestCase {
    typealias F = TreeFixture

    private func homeTree() -> DiskTree {
        F.tree(F.dir("me", [
            F.dir("Library", [F.dir("Caches", [F.file("c", 5)])]),
            F.dir("src", [F.dir("app", [F.dir("node_modules", [F.file("m", 50)]), F.file("main", 5)])]),
            F.dir("Pictures", [F.dir("Photos Library.photoslibrary", flags: .package, [F.dir("originals", [F.file("p", 9)])])]),
        ]), at: "/Users/me")
    }

    private func planner(_ tree: DiskTree) -> RemovalPlanner {
        RemovalPlanner(tree: tree, home: "/Users/me")
    }

    private func id(_ tree: DiskTree, _ path: String) -> Int { tree.node(at: path)! }

    // Covers AE6.
    func testMarkingFolderAbsorbsInnerMarks() throws {
        let tree = homeTree()
        var marks = MarkSet()
        try marks.mark(id(tree, "/Users/me/src/app/node_modules"), planner: planner(tree))
        try marks.mark(id(tree, "/Users/me/src/app"), planner: planner(tree))
        XCTAssertEqual(marks.nodes, [id(tree, "/Users/me/src/app")])
        XCTAssertEqual(marks.totalBytes(in: tree), 55)
    }

    func testCannotMarkInsideMarkedFolder() throws {
        let tree = homeTree()
        var marks = MarkSet()
        let app = id(tree, "/Users/me/src/app")
        try marks.mark(app, planner: planner(tree))
        XCTAssertThrowsError(try marks.mark(id(tree, "/Users/me/src/app/main"), planner: planner(tree))) { error in
            XCTAssertEqual(error as? MarkSet.MarkError, .insideMarked(ancestor: app))
        }
    }

    func testToggleAndDoubleUnmark() throws {
        let tree = homeTree()
        var marks = MarkSet()
        let src = id(tree, "/Users/me/src")
        XCTAssertTrue(try marks.toggle(src, planner: planner(tree)))
        XCTAssertFalse(try marks.toggle(src, planner: planner(tree)))
        marks.unmark(src)
        XCTAssertTrue(marks.isEmpty)
    }

    func testRefusals() {
        let tree = homeTree()
        let p = planner(tree)
        XCTAssertNotNil(p.refusal(for: DiskTree.root), "scanned root / home")
        XCTAssertNotNil(p.refusal(for: id(tree, "/Users/me/Library")), "~/Library")
        XCTAssertNil(p.refusal(for: id(tree, "/Users/me/Library/Caches")))
        XCTAssertNil(p.refusal(for: id(tree, "/Users/me/src")))
    }

    // Covers AE8.
    func testInsidePackageIsRefusedButPackageIsAllowed() {
        let tree = homeTree()
        let p = planner(tree)
        let reason = p.refusal(for: id(tree, "/Users/me/Pictures/Photos Library.photoslibrary/originals"))
        XCTAssertEqual(reason, "inside Photos Library.photoslibrary: removing parts of it can break it")
        XCTAssertNil(p.refusal(for: id(tree, "/Users/me/Pictures/Photos Library.photoslibrary")))
    }

    func testSmallFilesCannotBeMarked() throws {
        let root = F.dir("me", [F.dir("a")])
        root.addSmall(allocated: 10, apparent: 10, modified: 0)
        let tree = F.tree(root, at: "/Users/me")
        let small = tree.children(of: DiskTree.root).first { tree.kind[$0] == .smallFiles }!
        var marks = MarkSet()
        XCTAssertThrowsError(try marks.mark(small, planner: planner(tree)))
    }

    func testSystemTreesAndRootOnWholeDiskScan() {
        let tree = F.tree(F.dir("Data", [
            F.dir("usr", [F.dir("local", [F.file("x", 1)])]),
            F.dir("private", [F.dir("var", [F.dir("db", [F.file("y", 1)])]), F.dir("tmp", [F.file("t", 1)])]),
            F.dir("Users", [F.dir("me", [F.dir("Library", [F.file("z", 1)]), F.file("doc", 1)])]),
            F.dir("Applications", [F.dir("Old.app", flags: .package, [F.file("bin", 1)])]),
        ]), at: RemovalPlanner.dataVolume)
        let p = RemovalPlanner(tree: tree, home: "/Users/me")
        let data = RemovalPlanner.dataVolume
        XCTAssertNotNil(p.refusal(for: DiskTree.root))
        XCTAssertNotNil(p.refusal(for: id(tree, data + "/usr/local")))
        XCTAssertNotNil(p.refusal(for: id(tree, data + "/private/var/db")))
        XCTAssertNotNil(p.refusal(for: id(tree, data + "/Users/me")), "home")
        XCTAssertNotNil(p.refusal(for: id(tree, data + "/Users/me/Library")))
        XCTAssertNil(p.refusal(for: id(tree, data + "/Users/me/doc")))
        XCTAssertNil(p.refusal(for: id(tree, data + "/private/tmp")))
        XCTAssertNil(p.refusal(for: id(tree, data + "/Applications/Old.app")), "apps can go to the Trash")
    }

    func testMountPointIsRefused() {
        let root = F.dir("me", [])
        let mounted = ScanDirectory(name: "disk", device: 2, inode: 7, modified: 0)
        mounted.state = .read
        root.subdirectories.append(mounted)
        let tree = F.tree(root, at: "/Users/me")
        XCTAssertNotNil(planner(tree).refusal(for: id(tree, "/Users/me/disk")))
    }
}
