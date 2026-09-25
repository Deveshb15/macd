import CoreServices
import Darwin
import Foundation
import Synchronization

/// What changed under a root since some point.
nonisolated enum ChangeSet: Equatable, Sendable {
    case folders([FolderChange])
    /// The journal can't say what changed (dropped events, reset journal): scan everything.
    case needsFullScan
}

/// Finds and watches folder changes. The model depends on this so tests can fake it.
nonisolated protocol ChangeTracking: Sendable {
    func currentEventId() -> UInt64
    func volumeUUID(for path: String) -> String?
    /// Everything that changed under `root` since `eventId`, and the event ID it covers up to.
    func changes(under root: String, since eventId: UInt64) async -> (ChangeSet, UInt64)
    /// Calls `onChange` with batches of changes under `root` until the returned watch is stopped.
    func watch(root: String, since eventId: UInt64, onChange: @escaping @Sendable (ChangeSet, UInt64) -> Void) -> ChangeWatch?
}

nonisolated protocol ChangeWatch: AnyObject, Sendable {
    func stop()
}

/// Tracks nothing: every cached scan is treated as needing a full rescan.
nonisolated struct NoChangeTracking: ChangeTracking {
    func currentEventId() -> UInt64 { 0 }
    func volumeUUID(for path: String) -> String? { nil }
    func changes(under root: String, since eventId: UInt64) async -> (ChangeSet, UInt64) { (.needsFullScan, 0) }
    func watch(root: String, since eventId: UInt64, onChange: @escaping @Sendable (ChangeSet, UInt64) -> Void) -> ChangeWatch? { nil }
}

/// Reads macOS's FSEvents journal, which records every folder whose contents changed,
/// per volume, across reboots.
nonisolated struct FSEventsChangeTracker: ChangeTracking {
    /// Folders whose changes are ignored, like the app's own cache folder, so saving a
    /// scan doesn't look like a change that needs another refresh.
    var ignoredPrefixes: [String] = [DiskScanCache.defaultDirectory.path]
    var historyTimeout: Duration = .seconds(30)

    func currentEventId() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    func volumeUUID(for path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    func changes(under root: String, since eventId: UInt64) async -> (ChangeSet, UInt64) {
        let now = currentEventId()
        guard eventId > 0, eventId <= now else { return (.needsFullScan, now) }
        let collector = HistoryCollector(ignoredPrefixes: ignoredPrefixes)
        let result: ChangeSet = await withCheckedContinuation { continuation in
            collector.onFinish = { continuation.resume(returning: $0) }
            let stream = EventStream(paths: [root], since: eventId, latency: 0) { events in
                collector.receive(events)
            }
            guard let stream else {
                collector.finish(.needsFullScan)
                return
            }
            collector.attach(stream)
            let timeout = historyTimeout
            Task.detached {
                try? await Task.sleep(for: timeout)
                collector.finish(.needsFullScan)
            }
        }
        return (result, now)
    }

    func watch(root: String, since eventId: UInt64, onChange: @escaping @Sendable (ChangeSet, UInt64) -> Void) -> ChangeWatch? {
        let ignored = ignoredPrefixes
        return EventStream(paths: [root], since: eventId == 0 ? UInt64(kFSEventStreamEventIdSinceNow) : eventId, latency: 3) { events in
            let (set, latest) = Self.changeSet(from: events, ignoring: ignored)
            if set != .folders([]) { onChange(set, latest) }
        }
    }

    static let dropFlags = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)

    /// Turns raw events into folder changes. Dropped or wrapped events mean the journal
    /// lost track, so everything needs scanning.
    static func changeSet(from events: [EventStream.Event], ignoring ignored: [String]) -> (ChangeSet, UInt64) {
        var folders: [FolderChange] = []
        var latest: UInt64 = 0
        for event in events {
            latest = max(latest, event.id)
            if event.flags & dropFlags != 0 { return (.needsFullScan, latest) }
            if event.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            var path = event.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty, !ignored.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            let recursive = event.flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
            folders.append(FolderChange(path: path, recursive: recursive))
        }
        return (.folders(folders), latest)
    }
}

/// Gathers replayed history until FSEvents says it's done.
nonisolated private final class HistoryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [FolderChange] = []
    private var finished = false
    private let ignoredPrefixes: [String]
    var onFinish: ((ChangeSet) -> Void)?
    private var stream: EventStream?

    init(ignoredPrefixes: [String]) {
        self.ignoredPrefixes = ignoredPrefixes
    }

    /// Holds the stream until history is done. History can finish before the stream is
    /// even handed over, so a late stream is stopped right away.
    func attach(_ newStream: EventStream) {
        let alreadyDone: Bool = lock.withLock {
            if finished { return true }
            stream = newStream
            return false
        }
        if alreadyDone { newStream.stop() }
    }

    func receive(_ events: [EventStream.Event]) {
        let (set, _) = FSEventsChangeTracker.changeSet(from: events, ignoring: ignoredPrefixes)
        switch set {
        case .needsFullScan:
            finish(.needsFullScan)
        case .folders(let batch):
            lock.withLock { folders += batch }
            if events.contains(where: { $0.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }) {
                finish(.folders(lock.withLock { folders }))
            }
        }
    }

    func finish(_ result: ChangeSet) {
        let (callback, finishedStream): (((ChangeSet) -> Void)?, EventStream?) = lock.withLock {
            guard !finished else { return (nil, nil) }
            finished = true
            // Drop the stream so the collector and stream don't keep each other alive.
            defer { stream = nil }
            return (onFinish, stream)
        }
        guard let callback else { return }
        finishedStream?.stop()
        callback(result)
    }
}

/// A thin wrapper over an FSEvents stream delivering batches on a private queue.
nonisolated final class EventStream: ChangeWatch, @unchecked Sendable {
    struct Event: Sendable {
        let path: String
        let flags: UInt32
        let id: UInt64
    }

    private let handler: @Sendable ([Event]) -> Void
    private let queue = DispatchQueue(label: "com.devesh.macd.fsevents")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init?(paths: [String], since eventId: UInt64, latency: TimeInterval, handler: @escaping @Sendable ([Event]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, ids in
            guard let info else { return }
            let me = Unmanaged<EventStream>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            var events: [Event] = []
            events.reserveCapacity(count)
            for index in 0..<min(count, paths.count) {
                events.append(Event(path: paths[index], flags: flags[index], id: ids[index]))
            }
            me.handler(events)
        }
        let createFlags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray, eventId, latency, createFlags) else {
            return nil
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            stop()
            return nil
        }
    }

    /// Stops delivery. Safe to call from inside the handler and more than once.
    func stop() {
        let current: FSEventStreamRef? = lock.withLock {
            defer { stream = nil }
            return stream
        }
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        // Release after any callback in flight has returned.
        nonisolated(unsafe) let released = current
        queue.async { FSEventStreamRelease(released) }
    }

    deinit {
        stop()
    }
}
