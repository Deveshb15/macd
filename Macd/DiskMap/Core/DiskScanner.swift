import Darwin
import Foundation
import Synchronization

nonisolated struct ScanOptions: Sendable, Equatable {
    var includeHidden = true
    /// Skip directories on another device than the root.
    var oneVolume = true
    /// Count a file with several hard links once.
    var dedupeHardlinks = true
    /// Files smaller than this are summed into one entry per folder.
    var smallFileThreshold: UInt64 = 1_000_000
}

/// Live counters the UI can poll without locking.
nonisolated final class ScanProgress: Sendable {
    let entries = Atomic<Int>(0)
    let directories = Atomic<Int>(0)
    let bytes = Atomic<UInt64>(0)
    let unreadable = Atomic<Int>(0)
    let cancelled = Atomic<Bool>(false)

    init() {}

    func cancel() { cancelled.store(true, ordering: .relaxed) }
    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
}

nonisolated enum ScanError: Error, Equatable {
    case rootUnreadable(String)
    case cancelled
}

/// Anything that can produce a `DiskTree`. The model depends on this so tests can fake it.
protocol DiskScanning: Sendable {
    func scan(root: String, options: ScanOptions, progress: ScanProgress) async throws -> DiskTree
}

/// A parallel scanner in dust's shape: worker threads pull directories from one shared
/// stack, each reads its directory in bulk and pushes the subdirectories it finds. The
/// tree is built and aggregated in one serial pass after the last directory is read.
nonisolated struct DiskScanner: DiskScanning {
    /// Directory names that macOS treats as packages: shown as one tile, never marked inside.
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "photoslibrary", "musiclibrary",
        "tvlibrary", "photolibrary", "imovielibrary", "fcpbundle", "logicx", "band", "xcarchive",
        "xcodeproj", "xcworkspace", "playground", "sparsebundle", "rtfd", "pages", "numbers", "key",
        "pkg", "mpkg", "lproj", "docarchive", "mlmodelc",
    ]

    var workerCount = max(2, ProcessInfo.processInfo.activeProcessorCount)

    func scan(root: String, options: ScanOptions, progress: ScanProgress) async throws -> DiskTree {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(with: Result(catching: { try scanBlocking(root: root, options: options, progress: progress) }))
                }
            }
        } onCancel: {
            progress.cancel()
        }
    }

    func scanBlocking(root: String, options: ScanOptions, progress: ScanProgress) throws -> DiskTree {
        let rootPath = (root as NSString).standardizingPath
        var info = stat()
        guard lstat(rootPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ScanError.rootUnreadable(rootPath)
        }
        let rootDirectory = ScanDirectory(
            name: (rootPath as NSString).lastPathComponent, device: info.st_dev,
            inode: UInt64(info.st_ino), modified: Int64(info.st_mtimespec.tv_sec)
        )

        let queue = WorkQueue(first: (rootDirectory, rootPath))
        let context = Context(options: options, rootDevice: info.st_dev, progress: progress, seenInodes: InodeSet())

        let group = DispatchGroup()
        for _ in 0..<workerCount {
            group.enter()
            let thread = Thread {
                Self.disableDatalessMaterialization()
                while let (directory, path) = queue.take() {
                    if !progress.isCancelled {
                        Self.read(directory, at: path, context: context, queue: queue)
                    }
                    queue.finishOne()
                }
                group.leave()
            }
            thread.stackSize = 1 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()

        if progress.isCancelled { throw ScanError.cancelled }
        if rootDirectory.state == .unreadable { throw ScanError.rootUnreadable(rootPath) }
        return DiskTree(rootPath: rootPath, root: rootDirectory)
    }

    // MARK: Reading one directory

    private struct InodeKey: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    private final class InodeSet: Sendable {
        private let seen = Mutex<Set<InodeKey>>([])

        /// Records the inode; returns `true` the first time it is seen.
        func insert(_ key: InodeKey) -> Bool {
            seen.withLock { $0.insert(key).inserted }
        }
    }

    private struct Context: Sendable {
        let options: ScanOptions
        let rootDevice: Int32
        let progress: ScanProgress
        let seenInodes: InodeSet
    }

    private static func read(_ directory: ScanDirectory, at path: String, context: Context, queue: WorkQueue) {
        let entries: [BulkEntry]
        do {
            entries = try BulkDirectoryReader.read(path)
        } catch {
            directory.state = .unreadable
            context.progress.unreadable.add(1, ordering: .relaxed)
            return
        }
        directory.state = .read
        context.progress.directories.add(1, ordering: .relaxed)
        context.progress.entries.add(entries.count, ordering: .relaxed)

        let options = context.options
        var discovered: [(ScanDirectory, String)] = []
        var bytes: UInt64 = 0

        for entry in entries {
            let hidden = entry.name.hasPrefix(".") || entry.bsdFlags & UInt32(UF_HIDDEN) != 0
            if hidden, !options.includeHidden { continue }
            let dataless = entry.bsdFlags & UInt32(SF_DATALESS) != 0
            var flags: NodeFlags = []
            if hidden { flags.insert(.hidden) }
            if dataless { flags.insert(.dataless) }

            switch entry.kind {
            case .directory:
                let childPath = (path as NSString).appendingPathComponent(entry.name)
                let ext = (entry.name as NSString).pathExtension.lowercased()
                if packageExtensions.contains(ext) { flags.insert(.package) }
                let child = ScanDirectory(name: entry.name, device: entry.device, inode: entry.inode, modified: entry.modified, flags: flags)
                directory.subdirectories.append(child)
                if options.oneVolume, entry.device != context.rootDevice {
                    child.state = .otherVolume
                } else if dataless {
                    // Reading a cloud-only folder would ask iCloud to download it.
                    child.state = .read
                } else {
                    discovered.append((child, childPath))
                }

            case .file, .symlink, .other:
                if entry.kind == .symlink { flags.insert(.symlink) }
                var allocated = entry.allocated
                var apparent = entry.apparent
                if options.dedupeHardlinks, entry.kind == .file, entry.linkCount > 1 {
                    let key = InodeKey(device: entry.device, inode: entry.inode)
                    let isFirst = context.seenInodes.insert(key)
                    if !isFirst {
                        allocated = 0
                        apparent = 0
                    }
                }
                bytes += allocated
                if entry.kind == .file, max(allocated, apparent) >= options.smallFileThreshold {
                    directory.files.append(ScanFile(
                        name: entry.name, allocated: allocated, apparent: apparent, modified: entry.modified,
                        device: entry.device, inode: entry.inode, flags: flags
                    ))
                } else {
                    directory.addSmall(allocated: allocated, apparent: apparent, modified: entry.modified)
                }
            }
        }
        context.progress.bytes.add(bytes, ordering: .relaxed)
        queue.push(discovered)
    }

    /// Stops this thread from triggering iCloud downloads of dataless files and folders.
    private static func disableDatalessMaterialization() {
        _ = setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )
    }
}

/// A LIFO work stack that knows when every pushed item has been finished.
nonisolated private final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var stack: [(ScanDirectory, String)]
    private var outstanding: Int

    init(first: (ScanDirectory, String)) {
        stack = [first]
        outstanding = 1
    }

    /// Blocks until work is available; returns `nil` once everything is done.
    func take() -> (ScanDirectory, String)? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty {
            if outstanding == 0 { return nil }
            condition.wait()
        }
        return stack.removeLast()
    }

    func push(_ items: [(ScanDirectory, String)]) {
        guard !items.isEmpty else { return }
        condition.lock()
        stack.append(contentsOf: items)
        outstanding += items.count
        condition.broadcast()
        condition.unlock()
    }

    func finishOne() {
        condition.lock()
        outstanding -= 1
        if outstanding == 0 { condition.broadcast() }
        condition.unlock()
    }
}
