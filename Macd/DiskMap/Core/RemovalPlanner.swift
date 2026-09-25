import Foundation

/// Why a node must not be removed, if it must not. Ported from disktree's `removal.rs`
/// with macOS system trees. Every rule has a test.
nonisolated struct RemovalPlanner: Sendable {
    /// The data volume mounts at this path, and system paths appear beneath it too.
    static let dataVolume = "/System/Volumes/Data"

    /// Trees the operating system owns: refused even where permissions would allow it.
    static let systemTrees = [
        "/System", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db", "/private/var/vm",
        "/Library/Apple", "/cores", "/dev", "/opt/homebrew/Cellar",
    ]

    let tree: DiskTree
    let home: String

    init(tree: DiskTree, home: String = NSHomeDirectory()) {
        self.tree = tree
        self.home = (home as NSString).standardizingPath
    }

    /// A path as the user knows it: data-volume paths lose their `/System/Volumes/Data` prefix.
    static func effectivePath(_ path: String) -> String {
        guard path.hasPrefix(dataVolume + "/") else { return path == dataVolume ? "/" : path }
        return String(path.dropFirst(dataVolume.count))
    }

    func refusal(for id: Int) -> String? {
        switch tree.kind[id] {
        case .smallFiles: return "a group of small files, not one item: open the folder to remove it"
        case .unreadable: return "mac'd isn't allowed to read this folder"
        case .otherVolume: return "on another volume: removing it would reach into another disk"
        case .directory, .file: break
        }
        let path = Self.effectivePath(tree.path(of: id))
        if path == "/" { return "the root of the disk can't be removed" }
        if id == DiskTree.root { return "the scanned folder itself can't be removed" }
        if path == home { return "your home folder can't be removed" }
        if path == home + "/Library" { return "~/Library holds every app's data and settings" }
        if !path.hasPrefix(home + "/"), let system = Self.systemTrees.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "part of macOS under \(system)"
        }
        if let up = tree.parentOf(id), tree.device[id] != tree.device[up], tree.isDirectory(id) {
            return "a mount point: removing it would reach into another filesystem"
        }
        if tree.isInsidePackage(id) {
            let package = tree.chain(to: id).dropLast().last { tree.flags[$0].contains(.package) }
            let name = package.map { tree.names[$0] } ?? "a package"
            return "inside \(name): removing parts of it can break it"
        }
        return nil
    }
}

/// What the user has marked. Marking a folder absorbs marks inside it, and nothing
/// inside a marked folder can be marked on its own, so the total never double-counts.
nonisolated struct MarkSet: Sendable, Equatable {
    enum MarkError: Error, Equatable {
        case refused(String)
        case insideMarked(ancestor: Int)
    }

    private(set) var nodes: [Int] = []

    var isEmpty: Bool { nodes.isEmpty }

    func isMarked(_ id: Int) -> Bool { nodes.contains(id) }

    /// The marked node that is `id` or contains it.
    func markedAncestor(of id: Int, in tree: DiskTree) -> Int? {
        nodes.first { tree.isAncestor($0, of: id) }
    }

    mutating func mark(_ id: Int, planner: RemovalPlanner) throws(MarkError) {
        let tree = planner.tree
        if let ancestor = markedAncestor(of: id, in: tree) {
            if ancestor == id { return }
            throw .insideMarked(ancestor: ancestor)
        }
        if let reason = planner.refusal(for: id) { throw .refused(reason) }
        nodes.removeAll { tree.isAncestor(id, of: $0) }
        nodes.append(id)
    }

    mutating func unmark(_ id: Int) {
        nodes.removeAll { $0 == id }
    }

    /// Marks or unmarks; returns whether `id` is marked afterwards.
    @discardableResult
    mutating func toggle(_ id: Int, planner: RemovalPlanner) throws(MarkError) -> Bool {
        if isMarked(id) {
            unmark(id)
            return false
        }
        try mark(id, planner: planner)
        return true
    }

    mutating func removeAll() { nodes.removeAll() }

    func totalBytes(in tree: DiskTree) -> UInt64 {
        nodes.reduce(0) { $0 + tree.allocated[$1] }
    }
}
