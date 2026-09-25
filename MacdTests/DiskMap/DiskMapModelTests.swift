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

final class FakeRefresher: DiskRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [DiskTree]
    private(set) var calls: [[FolderChange]] = []
    var fails = false

    init(_ trees: [DiskTree]) { queue = trees }

    func refresh(_ tree: DiskTree, changes: [FolderChange], options: ScanOptions, progress: ScanProgress) async throws -> DiskTree {
        try lock.withLock {
            calls.append(changes)
            if fails { throw ScanError.cancelled }
            return queue.isEmpty ? tree : queue.removeFirst()
        }
    }
}

final class FakeCache: ScanCaching, @unchecked Sendable {
    private let lock = NSLock()
    var stored: CachedScan?
    private(set) var saves = 0

    func load(root: String, options: ScanOptions) -> CachedScan? {
        lock.withLock { stored.flatMap { $0.tree.rootPath == root && $0.options == options ? $0 : nil } }
    }

    func save(_ scan: CachedScan) {
        lock.withLock {
            stored = scan
            saves += 1
        }
    }
}

final class FakeChanges: ChangeTracking, @unchecked Sendable {
    var current: UInt64 = 100
    var uuid: String? = "VOLUME"
    var result: ChangeSet = .folders([])
    private(set) var askedSince: [UInt64] = []

    func currentEventId() -> UInt64 { current }
    func volumeUUID(for path: String) -> String? { uuid }
    func changes(under root: String, since eventId: UInt64) async -> (ChangeSet, UInt64) {
        askedSince.append(eventId)
        return (result, current)
    }
    func watch(root: String, since eventId: UInt64, onChange: @escaping @Sendable (ChangeSet, UInt64) -> Void) -> ChangeWatch? { nil }
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

    private func makeModel(
        _ trees: [DiskTree], remover: FakeRemover = FakeRemover(), refresher: FakeRefresher = FakeRefresher([]),
        cache: ScanCaching = NoScanCache(), changes: ChangeTracking = NoChangeTracking(),
        free: @escaping () -> Int64? = { 0 }
    ) -> (DiskMapModel, FakeScanner) {
        let scanner = FakeScanner(trees)
        let model = DiskMapModel(
            scanner: scanner, refresher: refresher, cache: cache, changes: changes, remover: remover,
            freeSpace: free, now: { 0 }, home: "/Users/me"
        )
        return (model, scanner)
    }

    private func scanned(_ model: DiskMapModel) async {
        model.startScan()
        await model.waitForScan()
    }

    func testScanSelectsNothingUntilHoverOrKeyboard() async {
        let (model, _) = makeModel([home()])
        await scanned(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.viewRoot, DiskTree.root)
        XCTAssertNil(model.selection, "no tile is outlined until the pointer or keyboard picks one")
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
    func testTrashRefreshesParentFoldersAndReportsMeasuredGain() async {
        let remover = FakeRemover()
        let refresher = FakeRefresher([home(withBig: false)])
        // Free space reads: before removal, then after the refresh.
        var readings: [Int64] = [10_000_000_000, 22_000_000_000]
        let (model, scanner) = makeModel([home()], remover: remover, refresher: refresher, free: { readings.removeFirst() })
        await scanned(model)
        model.toggleMark(model.tree!.node(at: "/Users/me/big")!)
        XCTAssertEqual(model.markedBytes, 12 * gb)

        model.openReview()
        await model.moveToTrash()

        XCTAssertEqual(remover.calls.first?.mode, .trash)
        XCTAssertEqual(remover.calls.first?.targets, ["/Users/me/big"])
        XCTAssertEqual(scanner.scanCount, 1, "no full rescan after a removal")
        XCTAssertEqual(refresher.calls, [[FolderChange(path: "/Users/me")]], "only the removed item's folder is re-read")
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
        let (model, _) = makeModel([home()], remover: remover, refresher: FakeRefresher([home(withBig: false)]))
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
        XCTAssertNil(names())
        model.stepSelection(by: 1)
        XCTAssertEqual(names(), "big", "the first step lands on the largest tile")
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

    // MARK: Cache and catching up

    private func cached(_ tree: DiskTree, eventId: UInt64 = 50, uuid: String? = "VOLUME") -> CachedScan {
        CachedScan(tree: tree, options: ScanOptions(), eventId: eventId, volumeUUID: uuid, savedAt: Date(timeIntervalSince1970: 1000))
    }

    private func waitForOpen(_ model: DiskMapModel) async {
        for _ in 0..<500 where model.phase != .ready || model.isRefreshing {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await model.waitForRefresh()
    }

    func testOpenShowsCachedScanWithoutFullScan() async {
        let cache = FakeCache()
        cache.stored = cached(home())
        let changes = FakeChanges()
        let (model, scanner) = makeModel([home()], cache: cache, changes: changes)

        model.open()
        await waitForOpen(model)

        XCTAssertEqual(scanner.scanCount, 0, "the saved scan is shown instead of scanning")
        XCTAssertNotNil(model.tree?.node(at: "/Users/me/big"))
        XCTAssertEqual(changes.askedSince, [50], "catches up from where the saved scan left off")
    }

    func testOpenAppliesOnlyChangedFolders() async {
        let cache = FakeCache()
        cache.stored = cached(home())
        let changes = FakeChanges()
        changes.result = .folders([FolderChange(path: "/Users/me/big")])
        let refresher = FakeRefresher([home(withBig: false)])
        let (model, scanner) = makeModel([home()], refresher: refresher, cache: cache, changes: changes)

        model.open()
        await waitForOpen(model)

        XCTAssertEqual(scanner.scanCount, 0)
        XCTAssertEqual(refresher.calls, [[FolderChange(path: "/Users/me/big")]])
        XCTAssertNil(model.tree?.node(at: "/Users/me/big"))
        XCTAssertEqual(cache.saves, 1, "the caught-up tree is saved for next time")
        XCTAssertEqual(cache.stored?.eventId, 100)
    }

    func testJournalThatCantVouchTriggersFullScan() async {
        let cache = FakeCache()
        cache.stored = cached(home())
        let changes = FakeChanges()
        changes.result = .needsFullScan
        let (model, scanner) = makeModel([home()], cache: cache, changes: changes)

        model.open()
        await waitForOpen(model)
        await model.waitForScan()

        XCTAssertEqual(scanner.scanCount, 1)
    }

    func testCacheFromAnotherVolumeIsIgnored() async {
        let cache = FakeCache()
        cache.stored = cached(home(), uuid: "OLD-VOLUME")
        let (model, scanner) = makeModel([home()], cache: cache, changes: FakeChanges())

        model.open()
        await waitForOpen(model)
        await model.waitForScan()

        XCTAssertEqual(scanner.scanCount, 1, "a reset journal means the saved scan can't be trusted")
    }

    func testFullScanIsSavedWithJournalPositionFromBeforeScanning() async {
        let cache = FakeCache()
        let changes = FakeChanges()
        changes.current = 777
        let (model, _) = makeModel([home()], cache: cache, changes: changes)

        model.open()
        await model.waitForScan()
        for _ in 0..<200 where cache.saves == 0 { try? await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(cache.stored?.eventId, 777)
        XCTAssertEqual(cache.stored?.volumeUUID, "VOLUME")
    }

    func testTreeSwapClearsHover() async {
        let cache = FakeCache()
        cache.stored = cached(home())
        let changes = FakeChanges()
        let (model, _) = makeModel([home()], refresher: FakeRefresher([home(withBig: false)]), cache: cache, changes: changes)
        model.open()
        await waitForOpen(model)

        model.hovered = model.tree!.node(at: "/Users/me/big")
        changes.result = .folders([FolderChange(path: "/Users/me")])
        model.close()
        model.open()
        await waitForOpen(model)

        XCTAssertNil(model.hovered, "a stale node number must not point into the new tree")
    }

    func testRefreshKeepsOpenFolderAndMarksByPath() async {
        let cache = FakeCache()
        cache.stored = cached(home())
        let changes = FakeChanges()
        let refresher = FakeRefresher([home()])
        let (model, _) = makeModel([home()], refresher: refresher, cache: cache, changes: changes)
        model.open()
        await waitForOpen(model)

        model.enter(model.tree!.node(at: "/Users/me/src")!)
        model.toggleMark(model.tree!.node(at: "/Users/me/src/app")!)
        changes.result = .folders([FolderChange(path: "/Users/me/Movies")])
        model.close()
        model.open()
        await waitForOpen(model)

        XCTAssertEqual(refresher.calls.count, 1)
        XCTAssertEqual(model.tree.map { $0.path(of: model.viewRoot) }, "/Users/me/src")
        XCTAssertEqual(model.marks.nodes.map { model.tree!.path(of: $0) }, ["/Users/me/src/app"])
    }
}
