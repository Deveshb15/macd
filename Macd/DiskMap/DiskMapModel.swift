import AppKit
import Foundation
import Observation

/// Drives the disk map: scanning, navigation, modes, selection, marks, review, and removal.
@Observable
final class DiskMapModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case failed(String)
    }

    enum Mode: Equatable, CaseIterable {
        case size, files, age

        var label: String {
            switch self {
            case .size: "Size"
            case .files: "Files"
            case .age: "Age"
            }
        }
    }

    struct Failure: Equatable {
        let path: String
        let reason: String
    }

    struct RemovalReport: Equatable {
        let mode: RemovalMode
        let removedCount: Int
        let markedBytes: UInt64
        let freedBytes: Int64
        let failures: [Failure]
    }

    enum Review: Equatable {
        case hidden
        case reviewing
        case confirmingDelete
        case removing(RemovalMode)
        case finished(RemovalReport)
    }

    enum PanelAction: Equatable {
        case revealInFinder
        case grantFullDiskAccess
    }

    static let depthRange = 1...8
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    // MARK: State

    private(set) var phase: Phase = .idle
    private(set) var tree: DiskTree?
    private(set) var scanRoot: String
    private(set) var viewRoot = DiskTree.root
    private(set) var progress = ScanProgress()
    private(set) var worthALook: [WorthALook.Candidate] = []
    private(set) var marks = MarkSet()
    private(set) var review: Review = .hidden
    var selection: Int?
    var mode: Mode = .size
    var apparentSize = false
    var depth = 4
    var filterText = ""
    /// The last reason a mark was refused, shown briefly in the panel.
    var markMessage: String?

    private(set) var includeHidden = true

    @ObservationIgnored private let scanner: DiskScanning
    @ObservationIgnored private let remover: RemovalPerforming
    @ObservationIgnored private let freeSpace: () -> Int64?
    @ObservationIgnored private let now: () -> Int64
    @ObservationIgnored let home: String
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var cachedFilter: FilterMatch?

    init(
        scanner: DiskScanning = DiskScanner(),
        remover: RemovalPerforming = RemovalExecutor(),
        freeSpace: @escaping () -> Int64? = { DiskReader().diskUsage()?.freeBytes },
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        home: String = NSHomeDirectory()
    ) {
        self.scanner = scanner
        self.remover = remover
        self.freeSpace = freeSpace
        self.now = now
        self.home = (home as NSString).standardizingPath
        scanRoot = self.home
    }

    // MARK: Derived

    var metric: SizeMetric {
        switch mode {
        case .files: .files
        case .size, .age: apparentSize ? .apparent : .allocated
        }
    }

    var planner: RemovalPlanner? {
        tree.map { RemovalPlanner(tree: $0, home: home) }
    }

    /// Nodes from the scan root down to the view root, for the breadcrumb trail.
    var trail: [Int] {
        tree?.chain(to: viewRoot) ?? []
    }

    var markedBytes: UInt64 {
        tree.map { marks.totalBytes(in: $0) } ?? 0
    }

    var freeNow: Int64? { freeSpace() }

    var isWholeDisk: Bool { scanRoot == RemovalPlanner.dataVolume }

    var filter: FilterMatch? {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard let tree, !query.isEmpty else { return nil }
        if let cachedFilter, cachedFilter.query == query { return cachedFilter }
        let match = FilterMatch(query: query, tree: tree, metric: metric)
        cachedFilter = match
        return match
    }

    func tiles(in area: CGRect) -> [Tile] {
        guard let tree, area.width > 0, area.height > 0 else { return [] }
        var options = LayoutOptions()
        options.maxDepth = depth
        return TreemapLayout.layout(tree: tree, root: viewRoot, area: area, metric: metric, options: options, filter: filter)
    }

    func panelAction(for id: Int) -> PanelAction {
        tree?.kind[id] == .unreadable ? .grantFullDiskAccess : .revealInFinder
    }

    // MARK: Scanning

    func startScan(root: String? = nil, select path: String? = nil) {
        scanTask?.cancel()
        let rootPath = root ?? scanRoot
        let options = ScanOptions(includeHidden: includeHidden)
        let progress = ScanProgress()
        self.progress = progress
        scanRoot = rootPath
        phase = .scanning
        let scanner = self.scanner
        let now = self.now()

        scanTask = Task {
            do {
                let (tree, candidates) = try await Task.detached(priority: .userInitiated) {
                    let tree = try await scanner.scan(root: rootPath, options: options, progress: progress)
                    Classifier.classify(tree)
                    return (tree, WorthALook.candidates(in: tree, now: now))
                }.value
                guard !Task.isCancelled else { return }
                install(tree, candidates: candidates, select: path)
            } catch ScanError.cancelled {
                // A newer scan replaced this one.
            } catch is CancellationError {
            } catch ScanError.rootUnreadable(let path) {
                phase = .failed("mac'd can't read \(path).")
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func waitForScan() async {
        await scanTask?.value
    }

    func setIncludeHidden(_ include: Bool) {
        guard include != includeHidden else { return }
        includeHidden = include
        rescan()
    }

    func rescan() {
        startScan(root: scanRoot, select: tree.map { $0.path(of: viewRoot) })
    }

    /// Widens the scan to the whole data volume, keeping the current folder in view.
    func scanWholeDisk() {
        let current = tree.map { $0.path(of: viewRoot) } ?? home
        let onData = current.hasPrefix(RemovalPlanner.dataVolume) ? current : RemovalPlanner.dataVolume + current
        startScan(root: RemovalPlanner.dataVolume, select: onData)
    }

    private func install(_ newTree: DiskTree, candidates: [WorthALook.Candidate], select path: String?) {
        tree = newTree
        worthALook = candidates
        cachedFilter = nil
        marks.removeAll()
        viewRoot = DiskTree.root
        if let path, let node = newTree.node(at: path) {
            viewRoot = newTree.isDirectory(node) ? node : (newTree.parentOf(node) ?? DiskTree.root)
        }
        selection = largestChild(of: viewRoot)
        phase = .ready
    }

    // MARK: Navigation

    func enter(_ id: Int) {
        guard let tree, tree.isDirectory(id), !tree.children(of: id).isEmpty else { return }
        viewRoot = id
        selection = largestChild(of: id)
    }

    func goUp() {
        guard let tree, let up = tree.parentOf(viewRoot) else { return }
        let previous = viewRoot
        viewRoot = up
        selection = previous
    }

    func goTo(trailIndex index: Int) {
        let chain = trail
        guard chain.indices.contains(index) else { return }
        let target = chain[index]
        let child = index + 1 < chain.count ? chain[index + 1] : nil
        viewRoot = target
        selection = child ?? largestChild(of: target)
    }

    /// Selects `id`, bringing its folder into view when it is outside the current one.
    func reveal(_ id: Int) {
        guard let tree else { return }
        if !tree.isAncestor(viewRoot, of: id) || id == viewRoot {
            viewRoot = tree.parentOf(id) ?? DiskTree.root
        }
        selection = id
    }

    /// Moves the selection to the next (or previous) sibling by size.
    func stepSelection(by offset: Int) {
        guard let tree else { return }
        let current = selection ?? largestChild(of: viewRoot)
        guard let current, let up = tree.parentOf(current) else { return }
        let siblings = tree.sortedChildren(of: up, by: metric)
        guard let index = siblings.firstIndex(of: current), !siblings.isEmpty else { return }
        selection = siblings[(index + offset + siblings.count) % siblings.count]
    }

    func setDepth(_ value: Int) {
        depth = min(max(value, Self.depthRange.lowerBound), Self.depthRange.upperBound)
    }

    private func largestChild(of id: Int) -> Int? {
        tree?.sortedChildren(of: id, by: metric).first
    }

    // MARK: Marks

    func toggleMark(_ id: Int? = nil) {
        guard let planner, let target = id ?? selection else { return }
        do {
            try marks.toggle(target, planner: planner)
            markMessage = nil
        } catch {
            switch error {
            case .refused(let reason):
                markMessage = "Can't mark this: \(reason)."
            case .insideMarked(let ancestor):
                markMessage = "Already going with \(planner.tree.names[ancestor]). Unmark it first."
            }
        }
    }

    func unmark(_ id: Int) {
        marks.unmark(id)
    }

    // MARK: Review and removal

    func openReview() {
        guard !marks.isEmpty else { return }
        review = .reviewing
    }

    func closeReview() {
        if case .removing = review { return }
        review = .hidden
    }

    func requestPermanentDelete() {
        guard review == .reviewing, !marks.isEmpty else { return }
        review = .confirmingDelete
    }

    func cancelPermanentDelete() {
        guard review == .confirmingDelete else { return }
        review = .reviewing
    }

    func moveToTrash() async {
        guard review == .reviewing else { return }
        await remove(mode: .trash)
    }

    func confirmPermanentDelete() async {
        guard review == .confirmingDelete else { return }
        await remove(mode: .permanent)
    }

    private func remove(mode: RemovalMode) async {
        guard let tree, !marks.isEmpty else { return }
        let targets = marks.nodes.map { RemovalTarget(tree: tree, node: $0) }
        let markedBytes = marks.totalBytes(in: tree)
        let viewPath = tree.path(of: viewRoot)
        review = .removing(mode)

        let before = freeSpace()
        let outcomes = await remover.remove(targets, mode: mode)
        startScan(root: scanRoot, select: viewPath)
        await waitForScan()
        let after = freeSpace()

        let failures = outcomes.compactMap { outcome in
            outcome.failure.map { Failure(path: outcome.target.path, reason: $0) }
        }
        // Failed items stay marked so the user can see and retry them.
        if let newTree = self.tree, let planner {
            for failure in failures {
                if let node = newTree.node(at: failure.path) { try? marks.mark(node, planner: planner) }
            }
        }
        let freed = (before != nil && after != nil) ? max(0, after! - before!) : 0
        review = .finished(RemovalReport(
            mode: mode, removedCount: outcomes.count - failures.count, markedBytes: markedBytes,
            freedBytes: freed, failures: failures
        ))
    }

    // MARK: Finder and settings

    func revealInFinder(_ id: Int) {
        guard let tree else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tree.path(of: id))])
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(Self.fullDiskAccessURL)
    }
}
