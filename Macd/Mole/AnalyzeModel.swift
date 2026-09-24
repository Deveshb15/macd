import AppKit
import Foundation
import Observation

/// Browses disk usage one folder at a time, keeping a breadcrumb trail for navigation.
@Observable
final class AnalyzeModel {
    enum State: Equatable {
        case idle
        case loading(String)
        case loaded(DiskListing)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Folders from the starting point down to the current folder.
    private(set) var trail: [String] = []

    @ObservationIgnored private let runner: MoleCommandRunning?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cache: [String: DiskListing] = [:]

    init(runner: MoleCommandRunning?) {
        self.runner = runner
    }

    static var homePath: String { FileManager.default.homeDirectoryForCurrentUser.path }

    func start(at path: String = AnalyzeModel.homePath) {
        trail = [path]
        cache.removeAll()
        load(path)
    }

    func open(_ entry: DiskEntry) {
        guard entry.isDirectory else { return }
        trail.append(entry.path)
        load(entry.path)
    }

    func goBack(to index: Int) {
        guard trail.indices.contains(index) else { return }
        trail.removeSubrange((index + 1)...)
        load(trail[index])
    }

    func refresh() {
        guard let current = trail.last else { return }
        cache[current] = nil
        load(current)
    }

    func cancel() {
        task?.cancel()
    }

    func revealInFinder(_ entry: DiskEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    private func load(_ path: String) {
        task?.cancel()
        if let cached = cache[path] {
            state = .loaded(cached)
            return
        }
        guard let runner else {
            state = .failed(MoleError.notInstalled.localizedDescription)
            return
        }
        state = .loading(path)
        task = Task {
            do {
                let result = try await runner.run(["analyze", "-json", path], timeout: .seconds(600), onLine: { _ in })
                let listing = try AnalyzeDecoder.decode(lines: result.output)
                guard !Task.isCancelled else { return }
                cache[path] = listing
                state = .loaded(listing)
            } catch MoleError.cancelled {
                if case .loading = state { state = .idle }
            } catch is DecodingError {
                state = .failed("mac'd couldn't read the disk analysis.")
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
