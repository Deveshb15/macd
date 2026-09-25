import XCTest
@testable import Macd

@MainActor
final class TreemapLayoutTests: XCTestCase {
    typealias F = TreeFixture
    private let area = CGRect(x: 0, y: 0, width: 600, height: 400)

    func testCanonicalSquarifyFillsAreaWithGoodRatios() {
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = TreemapLayout.squarify(values, in: area)
        let totalArea = rects.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(totalArea, 600 * 400, accuracy: 1)
        for (i, a) in rects.enumerated() {
            XCTAssertLessThanOrEqual(max(a.width / a.height, a.height / a.width), 3.01, "rect \(i)")
            for b in rects[(i + 1)...] {
                XCTAssertLessThan(a.intersection(b).width * a.intersection(b).height, 0.01)
            }
            XCTAssertTrue(area.insetBy(dx: -0.01, dy: -0.01).contains(a))
        }
        // Proportional: the first value gets 6/24 of the area.
        XCTAssertEqual(rects[0].width * rects[0].height, 600 * 400 * 6 / 24, accuracy: 1)
    }

    func testDegenerateInput() {
        XCTAssertTrue(TreemapLayout.squarify([], in: area).isEmpty)
        let zeros = TreemapLayout.squarify([0, 0], in: area)
        XCTAssertEqual(zeros, [.zero, .zero])
        XCTAssertTrue(zeros.allSatisfy { !$0.width.isNaN })
    }

    private func sampleTree() -> DiskTree {
        F.tree(F.dir("me", [
            F.dir("a", [F.dir("a1", [F.file("x", 500), F.file("y", 300)]), F.file("a2", 200)]),
            F.dir("b", [F.file("b1", 600), F.file("b2", 400)]),
            F.file("c", 1000),
        ]))
    }

    func testDepthOneDrawsOnlyRootChildren() {
        let tree = sampleTree()
        var options = LayoutOptions()
        options.maxDepth = 1
        let tiles = TreemapLayout.layout(tree: tree, root: DiskTree.root, area: area, metric: .allocated, options: options)
        XCTAssertEqual(Set(tiles.compactMap(\.node).map { tree.names[$0] }), ["a", "b", "c"])
        XCTAssertTrue(tiles.allSatisfy { $0.depth == 0 && $0.header == nil })
    }

    func testDeeperTilesSitInsideParentBelowHeader() {
        let tree = sampleTree()
        var options = LayoutOptions()
        options.maxDepth = 3
        let tiles = TreemapLayout.layout(tree: tree, root: DiskTree.root, area: area, metric: .allocated, options: options)
        let a = tree.node(at: "/home/me/a")!
        let a1 = tree.node(at: "/home/me/a/a1")!
        let x = tree.node(at: "/home/me/a/a1/x")!
        let tileA = tiles.first { $0.node == a }!
        let tileA1 = tiles.first { $0.node == a1 }!
        XCTAssertNotNil(tileA.header)
        XCTAssertTrue(tileA.rect.contains(tileA1.rect))
        XCTAssertGreaterThanOrEqual(tileA1.rect.minY, tileA.header!.maxY)
        XCTAssertNotNil(tiles.first { $0.node == x }, "grandchildren appear at depth 3")
    }

    func testLongChildListMergesTail() {
        let root = F.dir("me", (0..<300).map { F.file("f\($0)", UInt64(1000 - $0)) })
        let tree = F.tree(root)
        let tiles = TreemapLayout.layout(tree: tree, root: DiskTree.root, area: CGRect(x: 0, y: 0, width: 1400, height: 900), metric: .allocated)
        XCTAssertLessThanOrEqual(tiles.count, LayoutOptions().maxChildren + 1)
        XCTAssertTrue(tiles.contains { $0.node == nil && $0.othersCount == 300 - 96 })
    }

    func testHitReturnsDeepestTile() {
        let tree = sampleTree()
        let tiles = TreemapLayout.layout(tree: tree, root: DiskTree.root, area: area, metric: .allocated)
        let x = tree.node(at: "/home/me/a/a1/x")!
        let tileX = tiles.first { $0.node == x }!
        let hit = TreemapLayout.hit(tiles, at: CGPoint(x: tileX.rect.midX, y: tileX.rect.midY))
        XCTAssertEqual(hit?.node, x)
    }

    func testFilterKeepsOnlyMatches() {
        let tree = sampleTree()
        let filter = FilterMatch(query: "b1", tree: tree, metric: .allocated)
        let tiles = TreemapLayout.layout(tree: tree, root: DiskTree.root, area: area, metric: .allocated, filter: filter)
        let names = Set(tiles.compactMap(\.node).map { tree.names[$0] })
        XCTAssertEqual(names, ["b", "b1"])
    }
}
