import Foundation

/// A folder whose contents changed since a scan.
nonisolated struct FolderChange: Hashable, Sendable {
    let path: String
    /// Re-read everything beneath it, not just its own entries.
    var recursive = false
}

/// Anything that can bring a tree up to date for a set of changed folders.
/// The model depends on this so tests can fake it.
nonisolated protocol DiskRefreshing: Sendable {
    func refresh(_ tree: DiskTree, changes: [FolderChange], options: ScanOptions, progress: ScanProgress) async throws -> DiskTree
}

/// Brings a tree up to date by re-reading only the folders that changed. A changed
/// folder's own entries are read again; subfolders it already knew keep their scanned
/// contents, new ones are scanned fully, and removed ones drop out.
///
/// Hard links are only de-duplicated among the folders re-read here, so a file linked
/// from both a changed and an unchanged folder can count twice until the next full scan.
nonisolated struct IncrementalRefresher: DiskRefreshing {
    /// The editable copy the last refreshed tree was built from. Converting a large tree
    /// back into one takes a moment, so live updates reuse it.
    private let lastMirror = MirrorReuse()

    func refresh(_ tree: DiskTree, changes: [FolderChange], options: ScanOptions, progress: ScanProgress) async throws -> DiskTree {
        let reuse = lastMirror
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(with: Result(catching: {
                        let mirror = reuse.take(for: tree) ?? tree.makeMirror()
                        let refreshed = try Self.apply(changes, to: tree, mirror: mirror, options: options, progress: progress)
                        reuse.store(mirror, for: refreshed)
                        return refreshed
                    }))
                }
            }
        } onCancel: {
            progress.cancel()
        }
    }

    static func apply(_ changes: [FolderChange], to tree: DiskTree, options: ScanOptions, progress: ScanProgress) throws -> DiskTree {
        try apply(changes, to: tree, mirror: tree.makeMirror(), options: options, progress: progress)
    }

    /// `mirror` must be an editable copy of `tree`; it's updated in place.
    static func apply(_ changes: [FolderChange], to tree: DiskTree, mirror root: ScanDirectory, options: ScanOptions, progress: ScanProgress) throws -> DiskTree {
        DiskScanner.disableDatalessMaterialization()
        let rootPath = tree.rootPath
        let context = ScanContext(options: options, rootDevice: tree.device[DiskTree.root], progress: progress)

        for change in normalized(changes, root: rootPath) {
            if progress.isCancelled { throw ScanError.cancelled }
            let (directory, parent, reachedPath) = nearestDirectory(to: change.path, in: root, rootPath: rootPath)
            let whole = change.recursive && reachedPath == change.path
            refresh(directory, parent: parent, at: reachedPath, recursive: whole, context: context)
        }
        if progress.isCancelled { throw ScanError.cancelled }
        guard root.state != .unreadable else { throw ScanError.rootUnreadable(rootPath) }
        return DiskTree(rootPath: rootPath, root: root)
    }

    /// Paths inside the root, deduplicated, shallowest first, with anything beneath a
    /// recursive change dropped because that change covers it.
    static func normalized(_ changes: [FolderChange], root: String) -> [FolderChange] {
        var byPath: [String: Bool] = [:]
        for change in changes {
            var path = (change.path as NSString).standardizingPath
            if root.hasPrefix(RemovalPlanner.dataVolume + "/") || root == RemovalPlanner.dataVolume,
               !path.hasPrefix(RemovalPlanner.dataVolume) {
                path = RemovalPlanner.dataVolume + path
            }
            guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { continue }
            byPath[path] = (byPath[path] ?? false) || change.recursive
        }
        let sorted = byPath.keys.sorted { depth($0) != depth($1) ? depth($0) < depth($1) : $0 < $1 }
        var recursiveRoots: [String] = []
        var result: [FolderChange] = []
        for path in sorted {
            if recursiveRoots.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            let recursive = byPath[path] ?? false
            if recursive { recursiveRoots.append(path) }
            result.append(FolderChange(path: path, recursive: recursive))
        }
        return result
    }

    private static func depth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    /// The deepest known directory on the way to `path`, its parent, and its path.
    private static func nearestDirectory(to path: String, in root: ScanDirectory, rootPath: String) -> (ScanDirectory, ScanDirectory?, String) {
        var current = root
        var parent: ScanDirectory?
        var currentPath = rootPath
        let relative = path.dropFirst(rootPath.count)
        for component in relative.split(separator: "/") {
            guard current.state == .read,
                  let next = current.subdirectories.first(where: { $0.name == component }),
                  next.state == .read
            else { break }
            parent = current
            current = next
            currentPath = (currentPath as NSString).appendingPathComponent(String(component))
        }
        return (current, parent, currentPath)
    }

    private static func refresh(_ directory: ScanDirectory, parent: ScanDirectory?, at path: String, recursive: Bool, context: ScanContext) {
        let previous = directory.subdirectories
        let fresh = ScanDirectory(name: directory.name, device: directory.device, inode: directory.inode, modified: directory.modified, flags: directory.flags)
        let outcome = DiskScanner.readDirectory(fresh, at: path, context: context) { entry in
            // Keep a subfolder's scanned contents when it's still the same folder.
            guard !recursive, let known = previous.first(where: { $0.name == entry.name }),
                  known.inode == entry.inode, known.state == .read
            else { return nil }
            return known
        }
        switch outcome {
        case .missing:
            parent?.subdirectories.removeAll { $0 === directory }
        case .unreadable:
            directory.replaceContents(with: fresh)
        case .read(let discovered):
            directory.replaceContents(with: fresh)
            DiskScanner.fill(discovered, context: context)
        }
    }
}

/// Holds one editable copy, handed out only for the exact tree it matches. Taking it
/// removes it, so a failed or concurrent refresh can never reuse a half-edited copy.
nonisolated final class MirrorReuse: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (tree: ObjectIdentifier, mirror: ScanDirectory)?

    func take(for tree: DiskTree) -> ScanDirectory? {
        lock.withLock {
            defer { entry = nil }
            guard let entry, entry.tree == ObjectIdentifier(tree) else { return nil }
            return entry.mirror
        }
    }

    func store(_ mirror: ScanDirectory, for tree: DiskTree) {
        lock.withLock { entry = (ObjectIdentifier(tree), mirror) }
    }
}

extension ScanDirectory {
    /// Takes another directory's scanned contents, keeping this object's identity so
    /// its parent still points at it.
    nonisolated func replaceContents(with other: ScanDirectory) {
        state = other.state
        subdirectories = other.subdirectories
        files = other.files
        smallAllocated = other.smallAllocated
        smallApparent = other.smallApparent
        smallCount = other.smallCount
        smallNewest = other.smallNewest
    }
}
