import Foundation

/// One file kept as its own node (at or above the small-file threshold).
nonisolated struct ScanFile: Sendable {
    let name: String
    let allocated: UInt64
    let apparent: UInt64
    let modified: Int64
    let device: Int32
    let inode: UInt64
    let flags: NodeFlags
}

/// A directory as the scanner fills it in. Each instance is written only by the
/// worker that reads that directory, then read once when the tree is built.
nonisolated final class ScanDirectory: @unchecked Sendable {
    enum State: Sendable { case pending, read, unreadable, otherVolume }

    let name: String
    let device: Int32
    let inode: UInt64
    let modified: Int64
    let flags: NodeFlags

    var state: State = .pending
    var subdirectories: [ScanDirectory] = []
    var files: [ScanFile] = []
    var smallAllocated: UInt64 = 0
    var smallApparent: UInt64 = 0
    var smallCount: UInt64 = 0
    var smallNewest: Int64 = 0

    init(name: String, device: Int32, inode: UInt64, modified: Int64, flags: NodeFlags = []) {
        self.name = name
        self.device = device
        self.inode = inode
        self.modified = modified
        self.flags = flags
    }

    func addSmall(allocated: UInt64, apparent: UInt64, modified: Int64) {
        smallAllocated += allocated
        smallApparent += apparent
        smallCount += 1
        smallNewest = max(smallNewest, modified)
    }
}

nonisolated enum TreeDecodingError: Error, Equatable {
    case inconsistent
}

/// A finished scan as flat arrays indexed by node ID. Node 0 is the root.
/// Children of a node have consecutive IDs, always larger than their parent's,
/// so iterating IDs in reverse visits children before parents.
nonisolated final class DiskTree: @unchecked Sendable {
    static let root = 0

    let rootPath: String
    private(set) var names: [String] = []
    private(set) var parent: [Int32] = []
    private(set) var childStart: [Int32] = []
    private(set) var childCount: [Int32] = []
    private(set) var allocated: [UInt64] = []
    private(set) var apparent: [UInt64] = []
    private(set) var files: [UInt64] = []
    /// Newest modification time beneath the node, Unix seconds.
    private(set) var newest: [Int64] = []
    private(set) var kind: [NodeKind] = []
    private(set) var flags: [NodeFlags] = []
    private(set) var device: [Int32] = []
    private(set) var inode: [UInt64] = []

    /// Set by the classifier.
    var category: [Category] = []
    var reclaim: [Reclaim?] = []

    /// Directories the scan could not read.
    private(set) var unreadableCount = 0

    var count: Int { names.count }

    /// Builds the flat tree from a finished scan, breadth first, then aggregates bottom-up.
    init(rootPath: String, root: ScanDirectory) {
        self.rootPath = rootPath
        var queue: [ScanDirectory?] = [root]
        append(name: (rootPath as NSString).lastPathComponent, parent: -1, directory: root)

        var index = 0
        while index < queue.count {
            let id = index
            defer { index += 1 }
            guard let directory = queue[index], directory.state == .read else { continue }

            childStart[id] = Int32(count)
            var added: Int32 = 0
            for sub in directory.subdirectories {
                append(name: sub.name, parent: id, directory: sub)
                queue.append(sub)
                added += 1
            }
            for file in directory.files {
                appendFile(file, parent: id)
                queue.append(nil)
                added += 1
            }
            if directory.smallCount > 0 {
                appendNode(
                    name: "\(directory.smallCount) smaller file\(directory.smallCount == 1 ? "" : "s")",
                    parent: id, kind: .smallFiles,
                    allocated: directory.smallAllocated, apparent: directory.smallApparent,
                    files: directory.smallCount, newest: directory.smallNewest,
                    flags: [], device: directory.device, inode: 0
                )
                queue.append(nil)
                added += 1
            }
            childCount[id] = added
        }

        for id in stride(from: count - 1, through: 1, by: -1) {
            let up = Int(parent[id])
            allocated[up] += allocated[id]
            apparent[up] += apparent[id]
            files[up] += files[id]
            newest[up] = max(newest[up], newest[id])
        }
        category = Array(repeating: .other, count: count)
        reclaim = Array(repeating: nil, count: count)
    }

    /// The tree's raw storage, for saving to and loading from the scan cache.
    struct Columns: Equatable, Sendable {
        var names: [String]
        var parent: [Int32]
        var childStart: [Int32]
        var childCount: [Int32]
        var allocated: [UInt64]
        var apparent: [UInt64]
        var files: [UInt64]
        var newest: [Int64]
        var kind: [UInt8]
        var flags: [UInt8]
        var device: [Int32]
        var inode: [UInt64]
    }

    var columns: Columns {
        Columns(
            names: names, parent: parent, childStart: childStart, childCount: childCount,
            allocated: allocated, apparent: apparent, files: files, newest: newest,
            kind: kind.map(\.rawValue), flags: flags.map(\.rawValue), device: device, inode: inode
        )
    }

    /// Rebuilds a tree from saved columns. Throws when they are inconsistent.
    init(rootPath: String, columns c: Columns) throws(TreeDecodingError) {
        let n = c.names.count
        let counts = [c.parent.count, c.childStart.count, c.childCount.count, c.allocated.count, c.apparent.count,
                      c.files.count, c.newest.count, c.kind.count, c.flags.count, c.device.count, c.inode.count]
        guard n > 0, counts.allSatisfy({ $0 == n }) else { throw .inconsistent }
        var kinds: [NodeKind] = []
        kinds.reserveCapacity(n)
        for raw in c.kind {
            guard let kind = NodeKind(rawValue: raw) else { throw .inconsistent }
            kinds.append(kind)
        }
        for id in 0..<n {
            let up = Int(c.parent[id])
            let start = Int(c.childStart[id])
            let size = Int(c.childCount[id])
            guard (id == 0 ? up == -1 : (up >= 0 && up < id)), size >= 0, size == 0 || (start > id && start + size <= n) else {
                throw .inconsistent
            }
        }
        self.rootPath = rootPath
        names = c.names
        parent = c.parent
        childStart = c.childStart
        childCount = c.childCount
        allocated = c.allocated
        apparent = c.apparent
        files = c.files
        newest = c.newest
        kind = kinds
        flags = c.flags.map(NodeFlags.init(rawValue:))
        device = c.device
        inode = c.inode
        unreadableCount = kinds.lazy.filter { $0 == .unreadable }.count
        category = Array(repeating: .other, count: n)
        reclaim = Array(repeating: nil, count: n)
    }

    /// An editable copy of the tree as scanner directories, so a refresh can re-read
    /// changed folders and keep everything else. Directories take their newest
    /// modification time as their own, which rebuilds to the same totals.
    func makeMirror() -> ScanDirectory {
        var directories = [ScanDirectory?](repeating: nil, count: count)
        let root = ScanDirectory(name: names[0], device: device[0], inode: inode[0], modified: newest[0], flags: flags[0])
        root.state = .read
        directories[0] = root
        for id in 1..<count {
            guard let up = directories[Int(parent[id])] else { continue }
            switch kind[id] {
            case .directory, .unreadable, .otherVolume:
                let directory = ScanDirectory(name: names[id], device: device[id], inode: inode[id], modified: newest[id], flags: flags[id])
                directory.state = switch kind[id] {
                case .unreadable: .unreadable
                case .otherVolume: .otherVolume
                default: .read
                }
                up.subdirectories.append(directory)
                directories[id] = directory
            case .file:
                up.files.append(ScanFile(
                    name: names[id], allocated: allocated[id], apparent: apparent[id], modified: newest[id],
                    device: device[id], inode: inode[id], flags: flags[id]
                ))
            case .smallFiles:
                up.smallAllocated = allocated[id]
                up.smallApparent = apparent[id]
                up.smallCount = files[id]
                up.smallNewest = newest[id]
            }
        }
        return root
    }

    private func append(name: String, parent up: Int, directory: ScanDirectory) {
        let nodeKind: NodeKind = switch directory.state {
        case .unreadable: .unreadable
        case .otherVolume: .otherVolume
        default: .directory
        }
        if nodeKind == .unreadable { unreadableCount += 1 }
        appendNode(
            name: name, parent: up, kind: nodeKind, allocated: 0, apparent: 0, files: 0,
            newest: directory.modified, flags: directory.flags, device: directory.device, inode: directory.inode
        )
    }

    private func appendFile(_ file: ScanFile, parent up: Int) {
        appendNode(
            name: file.name, parent: up, kind: .file, allocated: file.allocated, apparent: file.apparent,
            files: 1, newest: file.modified, flags: file.flags, device: file.device, inode: file.inode
        )
    }

    private func appendNode(
        name: String, parent up: Int, kind nodeKind: NodeKind, allocated bytes: UInt64, apparent logical: UInt64,
        files fileTotal: UInt64, newest time: Int64, flags nodeFlags: NodeFlags, device dev: Int32, inode ino: UInt64
    ) {
        names.append(name)
        parent.append(Int32(up))
        childStart.append(0)
        childCount.append(0)
        allocated.append(bytes)
        apparent.append(logical)
        files.append(fileTotal)
        newest.append(time)
        kind.append(nodeKind)
        flags.append(nodeFlags)
        device.append(dev)
        inode.append(ino)
    }

    // MARK: Queries

    func children(of id: Int) -> Range<Int> {
        let start = Int(childStart[id])
        return start..<(start + Int(childCount[id]))
    }

    func value(of id: Int, metric: SizeMetric) -> UInt64 {
        switch metric {
        case .allocated: allocated[id]
        case .apparent: apparent[id]
        case .files: files[id]
        }
    }

    /// Children largest first by `metric`; ties by name.
    func sortedChildren(of id: Int, by metric: SizeMetric) -> [Int] {
        children(of: id).sorted { lhs, rhs in
            let left = value(of: lhs, metric: metric)
            let right = value(of: rhs, metric: metric)
            return left != right ? left > right : names[lhs] < names[rhs]
        }
    }

    func parentOf(_ id: Int) -> Int? {
        let up = Int(parent[id])
        return up < 0 ? nil : up
    }

    func isDirectory(_ id: Int) -> Bool {
        kind[id] == .directory
    }

    /// Ancestors from the root down to and including `id`.
    func chain(to id: Int) -> [Int] {
        var result = [id]
        var current = id
        while let up = parentOf(current) {
            result.append(up)
            current = up
        }
        return result.reversed()
    }

    func path(of id: Int) -> String {
        chain(to: id).dropFirst().reduce(rootPath) { ($0 as NSString).appendingPathComponent(names[$1]) }
    }

    /// The node at `path`, if the path is the root or beneath it.
    func node(at path: String) -> Int? {
        let standardized = (path as NSString).standardizingPath
        guard standardized == rootPath || standardized.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") else { return nil }
        let relative = standardized.dropFirst(rootPath.count)
        var current = DiskTree.root
        for component in relative.split(separator: "/") {
            guard let next = children(of: current).first(where: { names[$0] == component }) else { return nil }
            current = next
        }
        return current
    }

    /// Whether `ancestor` is `id` or above it.
    func isAncestor(_ ancestor: Int, of id: Int) -> Bool {
        var current: Int? = id
        while let node = current {
            if node == ancestor { return true }
            current = parentOf(node)
        }
        return false
    }

    /// Whether any strict ancestor of `id` is a package.
    func isInsidePackage(_ id: Int) -> Bool {
        var current = parentOf(id)
        while let node = current {
            if flags[node].contains(.package) { return true }
            current = parentOf(node)
        }
        return false
    }
}
