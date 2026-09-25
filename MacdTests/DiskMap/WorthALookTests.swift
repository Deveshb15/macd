import XCTest
@testable import Macd

@MainActor
final class WorthALookTests: XCTestCase {
    typealias F = TreeFixture
    private let gb: UInt64 = 1_000_000_000
    private let now: Int64 = 1_800_000_000

    private func classified(_ root: ScanDirectory) -> DiskTree {
        let tree = F.tree(root)
        Classifier.classify(tree)
        return tree
    }

    func testSmallFindingsAreDropped() {
        let tree = classified(F.dir("me", [
            F.dir("big", [F.dir(".cache", [F.file("a", 2 * gb)])]),
            F.dir("small", [F.dir(".cache", [F.file("b", 30_000_000)])]),
        ]))
        let found = WorthALook.candidates(in: tree, now: now)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(tree.path(of: found[0].node), "/home/me/big/.cache")
        XCTAssertEqual(found[0].finding, .reclaimable(.regenerable))
    }

    func testNestedReclaimableListedOnceAsOuter() {
        let tree = classified(F.dir("me", [F.dir(".cache", [F.dir("pip", [F.dir("cache", [F.file("w", gb)])])])]))
        let found = WorthALook.candidates(in: tree, now: now)
        XCTAssertEqual(found.map { tree.names[$0.node] }, [".cache"])
    }

    func testStaleExperimentsCountOnlyStaleOnes() {
        let old = now - 45 * WorthALook.day
        let fresh = now - 2 * WorthALook.day
        let tree = classified(F.dir("me", [F.dir("src", [F.dir("tries", [
            F.dir("a", modified: old, [F.file("x", gb, modified: old)]),
            F.dir("b", modified: old, [F.file("y", gb, modified: old)]),
            F.dir("c", modified: fresh, [F.file("z", gb, modified: fresh)]),
        ])])]))
        let found = WorthALook.candidates(in: tree, now: now)
        XCTAssertEqual(found.first?.finding, .staleExperiments(count: 2))
        XCTAssertEqual(found.first?.bytes, 2 * gb)
    }

    func testWorktrees() {
        let old = now - 10 * WorthALook.day
        let tree = classified(F.dir("me", [F.dir(".codex", [F.dir("worktrees", [
            F.dir("w1", modified: old, [F.file("x", gb, modified: old)]),
            F.dir("w2", modified: now, [F.file("y", gb, modified: now)]),
        ])])]))
        let found = WorthALook.candidates(in: tree, now: now)
        XCTAssertEqual(found.first?.finding, .worktrees(count: 2, oldestDays: 10))
    }
}
