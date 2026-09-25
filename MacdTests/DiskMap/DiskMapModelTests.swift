import XCTest
@testable import Macd

final class FakeScanner: DiskScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [DiskTree]
    private(set) var roots: [String] = []

    init(_ trees: [DiskTree]) { queue = trees }

    var scanCount: Int { lock.withLock { roots.count } }

    func scan(root: String, options: ScanOptions, progress: ScanProgress) async throws -> DiskTree {
        lock.withLock {
            roots.append(root)
            return queue.count > 1 ? queue.removeFirst() : queue[0]
        }
    }
}

final class FakeRemover: RemovalPerforming, @unchecked Sendable {
    private let lock = NSLock()
    var failPaths: Set<String> = []
    private(set) var calls: [(targets: [String], mode: RemovalMode)] = []

    func remove(_ targets: [RemovalTarget], mode: RemovalMode) async -> [RemovalOutcome] {
        lock.withLock { calls.append((targets.map(\.path), mode)) }
        return targets.map { RemovalOutcome(target: $0, failure: failPaths.contains($0.path) ? "locked" : nil) }
    }
}

@MainActor
final class DiskMapModelTests: XCTestCase {
    typealias F = TreeFixture
    private let gb: UInt64 = 1_000_000_000

    private func home(withBig: Bool = true) -> DiskTree {
        var children: [Any] = [
            F.dir("src", [F.dir("app", [F.file("main", 2 * gb)]), F.file("notes", 100)]),
            F.dir("Movies", [F.file("clip", 3 * gb)]),
        ]
        if withBig { children.append(F.dir("big", [F.file("blob", 12 * gb)])) }
        return F.tree(F.dir("me", children), at: "/Users/me")
    }

    private func makeModel(_ trees: [DiskTree], remover: FakeRemover = FakeRemover(), free: @escaping () -> Int64? = { 0 }) -> (DiskMapModel, FakeScanner) {
        let scanner = FakeScanner(trees)
        let model = DiskMapModel(scanner: scanner, remover: remover, freeSpace: free, now: { 0 }, home: "/Users/me")
        return (model, scanner)
    }

    private func scanned(_ model: DiskMapModel) async {
        model.startScan()
        await model.waitForScan()
    }

    func testScanSelectsLargestChild() async {
        let (model, _) = makeModel([home()])
        await scanned(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.viewRoot, DiskTree.root)
        XCTAssertEqual(model.selection.map { model.tree!.names[$0] }, "big")
    }

    func testEnterAndGoUp() async {
        let (model, _) = makeModel([home()])
        await scanned(model)
        let src = model.tree!.node(at: "/Users/me/src")!
        model.enter(src)
        XCTAssertEqual(model.trail.count, 2)
        model.goUp()
        XCTAssertEqual(model.viewRoot, DiskTree.root)
        XCTAssertEqual(model.selection, src)
        model.goUp()
        XCTAssertEqual(model.viewRoot, DiskTree.root, "going up at the root does nothing")
    }

    func testModeChangeDoesNotRescan() async {
        let (model, scanner) = makeModel([home()])
        await scanned(model)
        model.mode = .files
        XCTAssertEqual(model.metric, .files)
        _ = model.tiles(in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(scanner.scanCount, 1)
    }

    // Covers AE7.
    func testTrashRescansAndReportsMeasuredGain() async {
        let remover = FakeRemover()
        // Free space reads: before removal, then after the rescan.
        var readings: [Int64] = [10_000_000_000, 22_000_000_000]
        let (model, scanner) = makeModel([home(), home(withBig: false)], remover: remover, free: { readings.removeFirst() })
        await scanned(model)
        model.toggleMark(model.tree!.node(at: "/Users/me/big")!)
        XCTAssertEqual(model.markedBytes, 12 * gb)

        model.openReview()
        await model.moveToTrash()

        XCTAssertEqual(remover.calls.first?.mode, .trash)
        XCTAssertEqual(remover.calls.first?.targets, ["/Users/me/big"])
        XCTAssertEqual(scanner.scanCount, 2)
        guard case .finished(let report) = model.review else { return XCTFail("\(model.review)") }
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertEqual(report.markedBytes, 12 * gb)
        XCTAssertEqual(report.freedBytes, 12_000_000_000)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertNil(model.tree!.node(at: "/Users/me/big"))
    }

    func testPermanentDeleteNeedsConfirmation() async {
        let remover = FakeRemover()
        let (model, _) = makeModel([home()], remover: remover)
        await scanned(model)
        model.toggleMark(model.tree!.node(at: "/Users/me/Movies")!)
        model.openReview()
        await model.confirmPermanentDelete()
        XCTAssertTrue(remover.calls.isEmpty, "no delete without the confirm step")

        model.requestPermanentDelete()
        model.cancelPermanentDelete()
        XCTAssertEqual(model.review, .reviewing)
        XCTAssertFalse(model.marks.isEmpty)

        model.requestPermanentDelete()
        await model.confirmPermanentDelete()
        XCTAssertEqual(remover.calls.first?.mode, .permanent)
    }

    func testPartialFailureKeepsFailedItemsMarked() async {
        let remover = FakeRemover()
        remover.failPaths = ["/Users/me/Movies"]
        let (model, _) = makeModel([home(), home(withBig: false)], remover: remover)
        await scanned(model)
        model.toggleMark(model.tree!.node(at: "/Users/me/big")!)
        model.toggleMark(model.tree!.node(at: "/Users/me/Movies")!)
        model.openReview()
        await model.moveToTrash()

        guard case .finished(let report) = model.review else { return XCTFail() }
        XCTAssertEqual(report.failures, [DiskMapModel.Failure(path: "/Users/me/Movies", reason: "locked")])
        XCTAssertEqual(model.marks.nodes.map { model.tree!.path(of: $0) }, ["/Users/me/Movies"])
    }

    func testRefusedMarkExplainsWhy() async {
        let (model, _) = makeModel([home()])
        await scanned(model)
        model.toggleMark(DiskTree.root)
        XCTAssertNotNil(model.markMessage)
        XCTAssertTrue(model.marks.isEmpty)
    }

    // Covers AE9.
    func testUnreadableOffersFullDiskAccess() async {
        let mail = ScanDirectory(name: "Mail", device: 1, inode: 3, modified: 0)
        mail.state = .unreadable
        let tree = F.tree(F.dir("me", [F.dir("Library", [mail]), F.file("a", 10)]), at: "/Users/me")
        let (model, _) = makeModel([tree])
        await scanned(model)
        let node = model.tree!.node(at: "/Users/me/Library/Mail")!
        XCTAssertEqual(model.panelAction(for: node), .grantFullDiskAccess)
        XCTAssertEqual(model.panelAction(for: model.tree!.node(at: "/Users/me/a")!), .revealInFinder)
    }

    func testStepSelectionCyclesSiblingsBySize() async {
        let (model, _) = makeModel([home()])
        await scanned(model)
        let names = { model.selection.map { model.tree!.names[$0] } }
        XCTAssertEqual(names(), "big")
        model.stepSelection(by: 1)
        XCTAssertEqual(names(), "Movies")
        model.stepSelection(by: -2)
        XCTAssertEqual(names(), "src")
    }

    func testWholeDiskScanUsesDataVolume() async {
        let (model, scanner) = makeModel([home()])
        await scanned(model)
        model.scanWholeDisk()
        await model.waitForScan()
        XCTAssertEqual(scanner.roots.last, RemovalPlanner.dataVolume)
    }
}
