import Foundation

/// Creates real files and folders in a temporary directory for scanner and removal tests.
final class TestFileTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macd-tree-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var path: String { root.path }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `bytes` of non-zero data so APFS allocates real blocks.
    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: bytes).write(to: url)
        return url
    }

    func hardlink(_ existing: String, _ new: String) throws {
        try FileManager.default.linkItem(at: url(existing), to: url(new))
    }

    func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url(relative).path, withDestinationPath: destination)
    }

    func exists(_ relative: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(relative).path, isDirectory: &isDirectory)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url(relative).path)) != nil
    }

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let item as String in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url(item).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// Allocated bytes of everything beneath the root, by `lstat`, counting each inode once.
    func allocatedTotal() -> UInt64 {
        var seen = Set<UInt64>()
        var total: UInt64 = 0
        let paths = [root.path] + (FileManager.default.subpaths(atPath: root.path) ?? []).map { url($0).path }
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR else { continue }
            guard seen.insert(UInt64(info.st_ino)).inserted else { continue }
            total += UInt64(info.st_blocks) * 512
        }
        return total
    }
}
