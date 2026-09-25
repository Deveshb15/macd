import Darwin
import Foundation

nonisolated enum RemovalMode: Sendable, Equatable {
    case trash
    case permanent
}

/// A marked item, captured at plan time so removal can check nothing changed since the scan.
nonisolated struct RemovalTarget: Sendable, Equatable {
    let path: String
    let device: Int32
    let inode: UInt64
    let bytes: UInt64
    let isSymlink: Bool

    init(tree: DiskTree, node: Int) {
        path = tree.path(of: node)
        device = tree.device[node]
        inode = tree.inode[node]
        bytes = tree.allocated[node]
        isSymlink = tree.flags[node].contains(.symlink)
    }

    init(path: String, device: Int32, inode: UInt64, bytes: UInt64, isSymlink: Bool = false) {
        self.path = path
        self.device = device
        self.inode = inode
        self.bytes = bytes
        self.isSymlink = isSymlink
    }
}

nonisolated struct RemovalOutcome: Sendable, Equatable {
    let target: RemovalTarget
    /// `nil` on success; otherwise why it failed.
    let failure: String?
}

protocol RemovalPerforming: Sendable {
    func remove(_ targets: [RemovalTarget], mode: RemovalMode) async -> [RemovalOutcome]
}

/// Moves items to the Trash or deletes them. Symlinks are removed, never followed. Each
/// item is re-checked first; one failure never stops the rest.
nonisolated struct RemovalExecutor: RemovalPerforming {
    func remove(_ targets: [RemovalTarget], mode: RemovalMode) async -> [RemovalOutcome] {
        await Task.detached(priority: .userInitiated) {
            targets.map { removeOne($0, mode: mode) }
        }.value
    }

    func removeOne(_ target: RemovalTarget, mode: RemovalMode) -> RemovalOutcome {
        var info = stat()
        guard lstat(target.path, &info) == 0 else {
            return RemovalOutcome(target: target, failure: "no longer exists")
        }
        guard info.st_dev == target.device, UInt64(info.st_ino) == target.inode else {
            return RemovalOutcome(target: target, failure: "changed since the scan; rescan and try again")
        }
        let isLink = (info.st_mode & S_IFMT) == S_IFLNK
        do {
            switch mode {
            case .trash:
                try FileManager.default.trashItem(at: URL(fileURLWithPath: target.path, isDirectory: false), resultingItemURL: nil)
            case .permanent:
                if isLink || (info.st_mode & S_IFMT) != S_IFDIR {
                    guard unlink(target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                } else {
                    try FileManager.default.removeItem(atPath: target.path)
                }
            }
            return RemovalOutcome(target: target, failure: nil)
        } catch {
            return RemovalOutcome(target: target, failure: error.localizedDescription)
        }
    }
}
