import Foundation
import Observation

struct CleanResult: Equatable, Sendable {
    let freedBytes: Int64
    let skipped: [SkippedItem]
    let wasCancelled: Bool
}

/// Drives the preview → confirm → clean → result flow. Only one run happens at a time.
@Observable
final class CleanFlow {
    enum State: Equatable {
        case idle
        case previewing
        case ready(CleanPreview)
        case empty
        case cleaning(CleanPreview)
        case done(CleanResult)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The latest line Mole printed, shown as progress text.
    private(set) var progressLine: String?

    @ObservationIgnored private let runner: MoleCommandRunning?
    @ObservationIgnored private let freeSpace: () -> Int64?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(runner: MoleCommandRunning?, freeSpace: @escaping () -> Int64?) {
        self.runner = runner
        self.freeSpace = freeSpace
    }

    var isBusy: Bool {
        switch state {
        case .previewing, .cleaning: true
        default: false
        }
    }

    func startPreview() {
        guard !isBusy else { return }
        guard let runner else {
            state = .failed(MoleError.notInstalled.localizedDescription)
            return
        }
        state = .previewing
        progressLine = nil
        task = Task {
            do {
                let result = try await runner.run(["clean", "--dry-run"], timeout: .seconds(900), onLine: progressHandler())
                let preview = try CleanPreviewParser.parse(result.output)
                state = preview.totalBytes > 0 ? .ready(preview) : .empty
            } catch MoleError.cancelled {
                state = .idle
            } catch CleanPreviewError.unrecognizedOutput {
                state = .failed("mac'd couldn't read the cleanup preview. Nothing was deleted.")
            } catch {
                state = .failed(error.localizedDescription)
            }
            progressLine = nil
        }
    }

    func confirmClean() {
        guard case .ready(let preview) = state, let runner else { return }
        let before = freeSpace()
        state = .cleaning(preview)
        progressLine = nil
        task = Task {
            var cancelled = false
            do {
                _ = try await runner.run(["clean"], timeout: .seconds(1800), onLine: progressHandler())
            } catch MoleError.cancelled {
                cancelled = true
            } catch {
                state = .failed(error.localizedDescription)
                progressLine = nil
                return
            }
            let freed = Self.freed(before: before, after: freeSpace())
            state = .done(CleanResult(freedBytes: freed, skipped: preview.skipped, wasCancelled: cancelled))
            progressLine = nil
        }
    }

    /// Cancels a running command, or dismisses a finished state.
    func cancel() {
        switch state {
        case .previewing, .cleaning:
            task?.cancel()
        default:
            state = .idle
        }
    }

    func dismiss() {
        guard !isBusy else { return }
        state = .idle
    }

    static func freed(before: Int64?, after: Int64?) -> Int64 {
        guard let before, let after else { return 0 }
        return max(0, after - before)
    }

    private func progressHandler() -> @Sendable (String) -> Void {
        { [weak self] line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            Task { @MainActor in self?.progressLine = trimmed }
        }
    }
}
