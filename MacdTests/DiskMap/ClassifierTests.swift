import XCTest
@testable import Macd

@MainActor
final class ClassifierTests: XCTestCase {
    typealias F = TreeFixture

    private func classified(_ root: ScanDirectory) -> DiskTree {
        let tree = F.tree(root)
        Classifier.classify(tree)
        return tree
    }

    private func node(_ tree: DiskTree, _ relative: String) -> Int {
        tree.node(at: "/home/me/" + relative)!
    }

    func testLibraryCachesIsRegenerableAndInherits() {
        let tree = classified(F.dir("me", [F.dir("Library", [F.dir("Caches", [F.dir("com.app", [F.file("blob", 5)])])])]))
        let caches = node(tree, "Library/Caches")
        let inner = node(tree, "Library/Caches/com.app")
        XCTAssertEqual(tree.category[caches], .cache)
        XCTAssertEqual(tree.reclaim[caches], .regenerable)
        XCTAssertEqual(tree.reclaim[inner], .regenerable)
        XCTAssertEqual(tree.category[inner], .cache)
    }

    func testTargetNeedsCargoToml() {
        let tree = classified(F.dir("me", [
            F.dir("rust", [F.file("Cargo.toml", 1), F.dir("target", [F.file("bin", 9)])]),
            F.dir("other", [F.dir("target", [F.file("x", 1)])]),
        ]))
        XCTAssertEqual(tree.reclaim[node(tree, "rust/target")], .buildOutput)
        XCTAssertNil(tree.reclaim[node(tree, "other/target")])
    }

    func testNodeModulesBesidePackageJsonIsReinstallable() {
        let tree = classified(F.dir("me", [F.dir("web", [F.file("package.json", 1), F.dir("node_modules", [F.file("m", 1)])])]))
        XCTAssertEqual(tree.reclaim[node(tree, "web/node_modules")], .reinstallable)
    }

    func testUnknownTopLevelThatIsMostlyGitBecomesGit() {
        let git = F.dir(".git", [F.dir("objects", [F.file("pack", 900)]), F.dir("refs"), F.file("HEAD", 1)])
        let tree = classified(F.dir("me", [F.dir("world", [git, F.file("README", 1)])]))
        XCTAssertEqual(tree.category[node(tree, "world")], .git)
    }

    func testBareRepositoryShapeIsGit() {
        let bare = F.dir("mirror", [F.dir("objects"), F.dir("refs"), F.file("HEAD", 1)])
        let tree = classified(F.dir("me", [F.dir("code", [bare])]))
        XCTAssertEqual(tree.category[node(tree, "code/mirror")], .git)
    }

    func testXcodeLocations() {
        let tree = classified(F.dir("me", [F.dir("Library", [F.dir("Developer", [
            F.dir("Xcode", [F.dir("DerivedData", [F.file("d", 1)]), F.dir("iOS DeviceSupport", [F.file("s", 1)])]),
            F.dir("CoreSimulator", [F.file("sim", 1)]),
        ])])]))
        XCTAssertEqual(tree.reclaim[node(tree, "Library/Developer/Xcode/DerivedData")], .buildOutput)
        XCTAssertEqual(tree.reclaim[node(tree, "Library/Developer/Xcode/iOS DeviceSupport")], .regenerable)
        XCTAssertEqual(tree.category[node(tree, "Library/Developer/CoreSimulator")], .toolchain)
        XCTAssertNil(tree.reclaim[node(tree, "Library/Developer/CoreSimulator")])
    }

    func testICloudAndTrash() {
        let tree = classified(F.dir("me", [
            F.dir("Library", [F.dir("Mobile Documents", [F.file("doc", 1)])]),
            F.dir(".Trash", [F.file("old", 1)]),
        ]))
        XCTAssertEqual(tree.category[node(tree, "Library/Mobile Documents")], .synced)
        XCTAssertEqual(tree.reclaim[node(tree, ".Trash")], .trash)
    }

    func testFilesInheritTheirFoldersKind() {
        let tree = classified(F.dir("me", [F.dir("Movies", [F.file("clip.mov", 9_000_000)])]))
        XCTAssertEqual(tree.category[node(tree, "Movies/clip.mov")], .media)
    }
}
