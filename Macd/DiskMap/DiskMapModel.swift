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
    /// The tile under the pointer. Node numbers change when the tree is replaced, so every
    /// swap clears this before the old number could point at a different item.
    var hovered: Int?
    var mode: Mode = .size
    var apparentSize = false
    var depth = 4
    var filterText = ""
    /// The last reason a mark was refused, shown briefly in the panel.
    var markMessage: String?

    private(set) var includeHidden = true
    /// When the tree on screen was last brought up to date with the disk.
    private(set) var updatedAt: Date?
    /// Catching up on changes in the background while the current tree stays on screen.
    private(set) var isRefreshing = false

    /// How long live changes collect before they're applied, so a burst of writes
    /// (a build, a download) causes one refresh, not dozens.
    static let liveApplyDelay: Duration = .seconds(30)

    @ObservationIgnored private let scanner: DiskScanning
    @ObservationIgnored private let refresher: DiskRefreshing
    @ObservationIgnored private let cache: ScanCaching
    @ObservationIgnored private let changes: ChangeTracking
    @ObservationIgnored private let remover: RemovalPerforming
    @ObservationIgnored private let freeSpace: () -> Int64?
    @ObservationIgnored private let now: () -> Int64
    @ObservationIgnored let home: String
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var cachedFilter: FilterMatch?
    /// The change-journal position the tree on screen is up to date with.
    @ObservationIgnored private var eventId: UInt64 = 0
    @ObservationIgnored private var volumeUUID: String?
    /// The tree differs from what's saved in the cache.
    @ObservationIgnored private var unsaved = false
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var watch: ChangeWatch?
    @ObservationIgnored private var pending: [FolderChange] = []
    @ObservationIgnored private var pendingNeedsFullScan = false
    @ObservationIgnored private var pendingUpTo: UInt64 = 0
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        scanner: DiskScanning = DiskScanner(),
        refresher: DiskRefreshing = IncrementalRefresher(),
        cache: ScanCaching = NoScanCache(),
        changes: ChangeTracking = NoChangeTracking(),
        remover: RemovalPerforming = RemovalExecutor(),
        freeSpace: @escaping () -> Int64? = { DiskReader().diskUsage()?.freeBytes },
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        home: String = NSHomeDirectory()
    ) {
        self.scanner = scanner
        self.refresher = refresher
        self.cache = cache
        self.changes = changes
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

    // MARK: Opening, caching, and staying up to date

    private var scanOptions: ScanOptions { ScanOptions(includeHidden: includeHidden) }

    /// Called when the window appears. Shows the saved scan right away when there is
    /// one, then catches up on what changed since in the background.
    func open() {
        isOpen = true
        if tree != nil {
            catchUp()
            return
        }
        guard phase != .scanning else { return }
        let root = scanRoot
        let options = scanOptions
        let cache = self.cache
        let expectedUUID = changes.volumeUUID(for: root)
        let now = self.now()
        phase = .scanning
        refreshTask = Task {
            // Decoding a large saved scan takes a moment; keep it off the main thread.
            let loaded = await Task.detached(priority: .userInitiated) { () -> (CachedScan, [WorthALook.Candidate])? in
                guard let cached = cache.load(root: root, options: options),
                      cached.volumeUUID == nil || cached.volumeUUID == expectedUUID
                else { return nil }
                Classifier.classify(cached.tree)
                return (cached, WorthALook.candidates(in: cached.tree, now: now))
            }.value
            refreshTask = nil
            guard tree == nil, scanRoot == root else { return }
            guard let loaded else {
                startScan()
                return
            }
            let (cached, candidates) = loaded
            eventId = cached.eventId
            volumeUUID = cached.volumeUUID
            install(cached.tree, candidates: candidates, select: nil)
            updatedAt = cached.savedAt
            catchUp()
        }
    }

    /// Called when the window closes: stop watching, and save what's on screen.
    func close() {
        isOpen = false
        stopWatching()
        saveIfNeeded()
    }

    /// Replays the change journal since the tree on screen, re-reading only the folders
    /// that changed. Falls back to a full scan when the journal can't say.
    private func catchUp() {
        guard tree != nil, phase == .ready, !isRefreshing else {
            startWatching()
            return
        }
        isRefreshing = true
        let root = scanRoot
        let since = eventId
        let changes = self.changes
        refreshTask = Task {
            let (set, upTo) = await changes.changes(under: root, since: since)
            guard scanRoot == root else { return }
            switch set {
            case .needsFullScan:
                isRefreshing = false
                startScan(root: root, select: tree.map { $0.path(of: viewRoot) })
            case .folders(let folders):
                if folders.isEmpty {
                    eventId = max(eventId, upTo)
                    updatedAt = Date()
                    unsaved = true
                } else {
                    await applyChanges(folders, upTo: upTo)
                }
                isRefreshing = false
                saveIfNeeded()
                startWatching()
            }
        }
    }

    /// Re-reads the given folders and swaps in the updated tree, keeping the view,
    /// marks, and selection by path. Falls back to a full scan if the refresh fails.
    private func applyChanges(_ folders: [FolderChange], upTo: UInt64) async {
        guard let current = tree else { return }
        let refresher = self.refresher
        let options = scanOptions
        let progress = ScanProgress()
        let now = self.now()
        do {
            let (newTree, candidates) = try await Task.detached(priority: .utility) {
                let tree = try await refresher.refresh(current, changes: folders, options: options, progress: progress)
                Classifier.classify(tree)
                return (tree, WorthALook.candidates(in: tree, now: now))
            }.value
            // A full scan may have replaced the tree meanwhile; it wins.
            guard tree === current else { return }
            install(newTree, candidates: candidates, select: nil)
            eventId = max(eventId, upTo)
            updatedAt = Date()
            unsaved = true
        } catch {
            guard tree === current else { return }
            startScan(root: scanRoot, select: tree.map { $0.path(of: viewRoot) })
            await waitForScan()
        }
    }

    private func startWatching() {
        guard isOpen, watch == nil, tree != nil else { return }
        watch = changes.watch(root: scanRoot, since: eventId) { [weak self] set, latest in
            Task { @MainActor in self?.enqueue(set, upTo: latest) }
        }
    }

    private func stopWatching() {
        watch?.stop()
        watch = nil
        applyTask?.cancel()
        applyTask = nil
    }

    private func enqueue(_ set: ChangeSet, upTo latest: UInt64) {
        switch set {
        case .needsFullScan: pendingNeedsFullScan = true
        case .folders(let folders): pending += folders
        }
        pendingUpTo = max(pendingUpTo, latest)
        guard applyTask == nil else { return }
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.liveApplyDelay)
            guard !Task.isCancelled else { return }
            await self?.applyPending()
        }
    }

    private func applyPending() async {
        applyTask = nil
        // Never swap the tree under an open review, a removal, or another refresh.
        guard review == .hidden, phase == .ready, !isRefreshing else {
            if !pending.isEmpty || pendingNeedsFullScan { enqueue(.folders([]), upTo: pendingUpTo) }
            return
        }
        let folders = pending
        let needsFullScan = pendingNeedsFullScan
        let upTo = pendingUpTo
        pending = []
        pendingNeedsFullScan = false
        if needsFullScan {
            rescan()
            return
        }
        guard !folders.isEmpty else { return }
        isRefreshing = true
        await applyChanges(folders, upTo: upTo)
        isRefreshing = false
    }

    private func saveIfNeeded() {
        guard unsaved, let tree else { return }
        unsaved = false
        let scan = CachedScan(tree: tree, options: scanOptions, eventId: eventId, volumeUUID: volumeUUID, savedAt: updatedAt ?? Date())
        let cache = self.cache
        Task.detached(priority: .utility) { cache.save(scan) }
    }

    // MARK: Full scans

    func startScan(root: String? = nil, select path: String? = nil) {
        scanTask?.cancel()
        refreshTask?.cancel()
        isRefreshing = false
        let rootPath = root ?? scanRoot
        let options = scanOptions
        let progress = ScanProgress()
        self.progress = progress
        if rootPath != scanRoot { stopWatching() }
        scanRoot = rootPath
        phase = .scanning
        let scanner = self.scanner
        let now = self.now()
        // Taken before the scan, so replaying from here covers changes made during it.
        let startEventId = changes.currentEventId()
        let uuid = changes.volumeUUID(for: rootPath)

        scanTask = Task {
            do {
                let (tree, candidates) = try await Task.detached(priority: .userInitiated) {
                    let tree = try await scanner.scan(root: rootPath, options: options, progress: progress)
                    Classifier.classify(tree)
                    return (tree, WorthALook.candidates(in: tree, now: now))
                }.value
                guard !Task.isCancelled else { return }
                install(tree, candidates: candidates, select: path)
                eventId = startEventId
                volumeUUID = uuid
                updatedAt = Date()
                unsaved = true
                saveIfNeeded()
                startWatching()
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

    /// Waits for any background catch-up or live refresh in flight.
    func waitForRefresh() async {
        await refreshTask?.value
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

    /// Swaps in a new tree, carrying the open folder, marks, and keyboard selection
    /// across by path. `path` overrides which folder is open.
    private func install(_ newTree: DiskTree, candidates: [WorthALook.Candidate], select path: String?) {
        let old = tree
        let viewPath = path ?? old.map { $0.path(of: viewRoot) }
        let markedPaths = old.map { tree in marks.nodes.map { tree.path(of: $0) } } ?? []
        let selectedPath = old.flatMap { tree in selection.map { tree.path(of: $0) } }

        hovered = nil
        tree = newTree
        worthALook = candidates
        cachedFilter = nil
        marks.removeAll()
        viewRoot = DiskTree.root
        if let viewPath, let node = newTree.node(at: viewPath) {
            viewRoot = newTree.isDirectory(node) ? node : (newTree.parentOf(node) ?? DiskTree.root)
        }
        let planner = RemovalPlanner(tree: newTree, home: home)
        for markedPath in markedPaths {
            if let node = newTree.node(at: markedPath) { try? marks.mark(node, planner: planner) }
        }
        selection = selectedPath.flatMap { newTree.node(at: $0) }
        phase = .ready
    }

    // MARK: Navigation

    func enter(_ id: Int) {
        guard let tree, tree.isDirectory(id), !tree.children(of: id).isEmpty else { return }
        viewRoot = id
        selection = nil
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
        selection = child
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
        guard let current = selection else {
            // Nothing selected yet: the first step lands on the largest tile.
            selection = largestChild(of: viewRoot)
            return
        }
        guard let up = tree.parentOf(current) else { return }
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
        // Only the folders that held removed items changed: re-read those, not the disk.
        let parents = Set(targets.map { ($0.path as NSString).deletingLastPathComponent })
        await refreshTask?.value
        await applyChanges(parents.sorted().map { FolderChange(path: $0) }, upTo: eventId)
        if let current = self.tree, let node = current.node(at: viewPath), current.isDirectory(node) {
            viewRoot = node
        }
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
