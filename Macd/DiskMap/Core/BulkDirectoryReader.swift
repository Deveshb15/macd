import Darwin
import Foundation

/// One entry of a directory, as `getattrlistbulk` reports it.
nonisolated struct BulkEntry: Sendable {
    enum Kind: Sendable { case directory, file, symlink, other }

    let name: String
    let kind: Kind
    let device: Int32
    let inode: UInt64
    let modified: Int64
    let bsdFlags: UInt32
    let linkCount: UInt32
    let allocated: UInt64
    let apparent: UInt64
}

nonisolated enum BulkReadError: Error, Equatable {
    /// The directory exists but this process may not read it (EACCES / EPERM).
    case permissionDenied
    case failed(Int32)
}

/// Reads a whole directory's entries with `getattrlistbulk`: one system call returns
/// name, type, device, inode, modification time, flags, link count, and sizes for many
/// entries at once, much faster than `stat` per file on APFS.
nonisolated enum BulkDirectoryReader {
    private static let bufferSize = 256 * 1024

    static func read(_ path: String) throws(BulkReadError) -> [BulkEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error(for: errno) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        let common: [attrgroup_t] = [
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS), attrgroup_t(ATTR_CMN_NAME), attrgroup_t(ATTR_CMN_DEVID),
            attrgroup_t(ATTR_CMN_OBJTYPE), attrgroup_t(ATTR_CMN_MODTIME), attrgroup_t(ATTR_CMN_FLAGS),
            attrgroup_t(ATTR_CMN_FILEID), attrgroup_t(ATTR_CMN_ERROR),
        ]
        let file: [attrgroup_t] = [
            attrgroup_t(ATTR_FILE_LINKCOUNT), attrgroup_t(ATTR_FILE_TOTALSIZE), attrgroup_t(ATTR_FILE_ALLOCSIZE),
        ]
        request.commonattr = common.reduce(0, |)
        request.fileattr = file.reduce(0, |)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var entries: [BulkEntry] = []
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count < 0 {
                if errno == EINTR { continue }
                throw error(for: errno)
            }
            if count == 0 { break }

            var record = buffer
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                if let entry = parse(record) { entries.append(entry) }
                record += length
            }
        }
        return entries
    }

    /// Layout with FSOPT_PACK_INVAL_ATTRS (every requested attribute present, 4-byte aligned):
    /// length, returned attribute_set, error, name ref, devid, objtype, modtime, flags, fileid,
    /// then linkcount, totalsize, allocsize.
    private static func parse(_ record: UnsafeMutableRawPointer) -> BulkEntry? {
        var cursor = record + MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size

        let entryError = cursor.loadUnaligned(as: UInt32.self)
        cursor += 4

        let nameRef = cursor.loadUnaligned(as: attrreference_t.self)
        let namePointer = (cursor + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
        let name = String(cString: namePointer)
        cursor += MemoryLayout<attrreference_t>.size

        let device = cursor.loadUnaligned(as: Int32.self)
        cursor += 4
        let objectType = cursor.loadUnaligned(as: UInt32.self)
        cursor += 4
        let modified = cursor.loadUnaligned(as: timespec.self)
        cursor += MemoryLayout<timespec>.size
        let bsdFlags = cursor.loadUnaligned(as: UInt32.self)
        cursor += 4
        let inode = cursor.loadUnaligned(as: UInt64.self)
        cursor += 8
        let linkCount = cursor.loadUnaligned(as: UInt32.self)
        cursor += 4
        let apparent = cursor.loadUnaligned(as: Int64.self)
        cursor += 8
        let allocated = cursor.loadUnaligned(as: Int64.self)

        guard entryError == 0, !name.isEmpty else { return nil }

        let kind: BulkEntry.Kind = switch objectType {
        case UInt32(VDIR.rawValue): .directory
        case UInt32(VREG.rawValue): .file
        case UInt32(VLNK.rawValue): .symlink
        default: .other
        }
        return BulkEntry(
            name: name, kind: kind, device: device, inode: inode, modified: Int64(modified.tv_sec),
            bsdFlags: bsdFlags, linkCount: linkCount,
            allocated: UInt64(max(allocated, 0)), apparent: UInt64(max(apparent, 0))
        )
    }

    private static func error(for code: Int32) -> BulkReadError {
        code == EACCES || code == EPERM ? .permissionDenied : .failed(code)
    }
}
