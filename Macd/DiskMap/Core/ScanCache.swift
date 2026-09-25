import Foundation

/// A saved scan, and where macOS's change journal stood when it was taken.
nonisolated struct CachedScan: Sendable {
    let tree: DiskTree
    let options: ScanOptions
    /// FSEvents event ID from just before the scan, so replaying from it covers
    /// anything that changed while the scan ran.
    let eventId: UInt64
    /// The volume's FSEvents UUID. If it differs later, the journal was reset.
    let volumeUUID: String?
    let savedAt: Date
}

/// Stores scans between launches. The model depends on this so tests can fake it.
nonisolated protocol ScanCaching: Sendable {
    func load(root: String, options: ScanOptions) -> CachedScan?
    func save(_ scan: CachedScan)
}

/// Keeps nothing: every open scans from scratch.
nonisolated struct NoScanCache: ScanCaching {
    func load(root: String, options: ScanOptions) -> CachedScan? { nil }
    func save(_ scan: CachedScan) {}
}

/// Saves scans as compressed files in the app's caches folder, one per root and options.
nonisolated struct DiskScanCache: ScanCaching {
    static let defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.devesh.macd/DiskMap", isDirectory: true)

    let directory: URL

    init(directory: URL = DiskScanCache.defaultDirectory) {
        self.directory = directory
    }

    func url(root: String, options: ScanOptions) -> URL {
        let safe = root.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("scan\(safe)\(options.includeHidden ? "" : "-nohidden").macdscan")
    }

    func load(root: String, options: ScanOptions) -> CachedScan? {
        guard let data = try? Data(contentsOf: url(root: root, options: options)),
              let scan = try? ScanCodec.decode(data),
              scan.tree.rootPath == root, scan.options == options
        else { return nil }
        return scan
    }

    func save(_ scan: CachedScan) {
        guard let data = try? ScanCodec.encode(scan) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(root: scan.tree.rootPath, options: scan.options), options: .atomic)
    }
}

/// The on-disk format: a small JSON header, then each column as raw little-endian bytes,
/// then names separated by NUL, all LZFSE-compressed.
nonisolated enum ScanCodec {
    static let magic = Data("MACDSCAN".utf8)
    static let version: UInt32 = 1

    enum CodecError: Error { case badMagic, badVersion, truncated, inconsistent }

    private struct Header: Codable {
        let rootPath: String
        let includeHidden: Bool
        let oneVolume: Bool
        let dedupeHardlinks: Bool
        let smallFileThreshold: UInt64
        let eventId: UInt64
        let volumeUUID: String?
        let savedAt: Date
        let count: Int
    }

    static func encode(_ scan: CachedScan) throws -> Data {
        let columns = scan.tree.columns
        let header = Header(
            rootPath: scan.tree.rootPath, includeHidden: scan.options.includeHidden, oneVolume: scan.options.oneVolume,
            dedupeHardlinks: scan.options.dedupeHardlinks, smallFileThreshold: scan.options.smallFileThreshold,
            eventId: scan.eventId, volumeUUID: scan.volumeUUID, savedAt: scan.savedAt, count: columns.names.count
        )
        var body = Data()
        let headerData = try JSONEncoder().encode(header)
        append(UInt32(headerData.count), to: &body)
        body.append(headerData)
        append(columns.parent, to: &body)
        append(columns.childStart, to: &body)
        append(columns.childCount, to: &body)
        append(columns.allocated, to: &body)
        append(columns.apparent, to: &body)
        append(columns.files, to: &body)
        append(columns.newest, to: &body)
        append(columns.kind, to: &body)
        append(columns.flags, to: &body)
        append(columns.device, to: &body)
        append(columns.inode, to: &body)
        for name in columns.names {
            body.append(contentsOf: name.utf8)
            body.append(0)
        }
        let compressed = try (body as NSData).compressed(using: .lzfse) as Data
        var data = magic
        append(version, to: &data)
        data.append(compressed)
        return data
    }

    static func decode(_ data: Data) throws -> CachedScan {
        guard data.count > magic.count + 4, data.prefix(magic.count) == magic else { throw CodecError.badMagic }
        var cursor = magic.count
        guard try read(UInt32.self, from: data, at: &cursor) == version else { throw CodecError.badVersion }
        let body = try (data.subdata(in: cursor..<data.count) as NSData).decompressed(using: .lzfse) as Data

        var offset = 0
        let headerLength = Int(try read(UInt32.self, from: body, at: &offset))
        guard offset + headerLength <= body.count else { throw CodecError.truncated }
        let header = try JSONDecoder().decode(Header.self, from: body.subdata(in: offset..<(offset + headerLength)))
        offset += headerLength
        let n = header.count

        let parent: [Int32] = try readArray(n, from: body, at: &offset)
        let childStart: [Int32] = try readArray(n, from: body, at: &offset)
        let childCount: [Int32] = try readArray(n, from: body, at: &offset)
        let allocated: [UInt64] = try readArray(n, from: body, at: &offset)
        let apparent: [UInt64] = try readArray(n, from: body, at: &offset)
        let files: [UInt64] = try readArray(n, from: body, at: &offset)
        let newest: [Int64] = try readArray(n, from: body, at: &offset)
        let kind: [UInt8] = try readArray(n, from: body, at: &offset)
        let flags: [UInt8] = try readArray(n, from: body, at: &offset)
        let device: [Int32] = try readArray(n, from: body, at: &offset)
        let inode: [UInt64] = try readArray(n, from: body, at: &offset)

        var names: [String] = []
        names.reserveCapacity(n)
        body.withUnsafeBytes { raw in
            var start = offset
            for index in offset..<raw.count where raw[index] == 0 {
                names.append(String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<index]), as: UTF8.self))
                start = index + 1
            }
        }
        guard names.count == n else { throw CodecError.truncated }

        let columns = DiskTree.Columns(
            names: names, parent: parent, childStart: childStart, childCount: childCount, allocated: allocated,
            apparent: apparent, files: files, newest: newest, kind: kind, flags: flags, device: device, inode: inode
        )
        let tree: DiskTree
        do {
            tree = try DiskTree(rootPath: header.rootPath, columns: columns)
        } catch {
            throw CodecError.inconsistent
        }
        let options = ScanOptions(
            includeHidden: header.includeHidden, oneVolume: header.oneVolume,
            dedupeHardlinks: header.dedupeHardlinks, smallFileThreshold: header.smallFileThreshold
        )
        return CachedScan(tree: tree, options: options, eventId: header.eventId, volumeUUID: header.volumeUUID, savedAt: header.savedAt)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append<T: FixedWidthInteger>(_ values: [T], to data: inout Data) {
        values.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_: T.Type, from data: Data, at offset: inout Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { throw CodecError.truncated }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += size
        return T(littleEndian: value)
    }

    private static func readArray<T: FixedWidthInteger>(_ count: Int, from data: Data, at offset: inout Int) throws -> [T] {
        let size = count * MemoryLayout<T>.stride
        guard offset + size <= data.count else { throw CodecError.truncated }
        let values = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.withUnsafeBytes { raw in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + size)]))
            }
            initialized = count
        }
        offset += size
        return values
    }
}
