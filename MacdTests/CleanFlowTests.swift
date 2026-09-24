import XCTest
@testable import Macd

final class FakeMoleRunner: MoleCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var responses: [String: Result<[String], MoleError>] = [:]
    var delay: Duration = .zero

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func run(_ arguments: [String], timeout: Duration, onLine: @escaping @Sendable (String) -> Void) async throws -> MoleRunResult {
        lock.withLock { _calls.append(arguments) }
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { throw MoleError.cancelled }
        }
        switch responses[arguments.joined(separator: " ")] ?? .success([]) {
        case .success(let lines):
            lines.forEach(onLine)
            return MoleRunResult(exitCode: 0, output: lines)
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
final class CleanFlowTests: XCTestCase {
    private let previewLines = [
        "◎ System caches need sudo, run sudo -v && mo clean --dry-run for full preview",
        "➤ Browsers",
        "  → Chrome cache · 3.1GB dry",
        "➤ User essentials",
        "  → User app logs · 18 items, 400.0MB dry",
    ]

    private func waitUntil(_ flow: CleanFlow, timeout: TimeInterval = 5, _ condition: @escaping (CleanFlow.State) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(flow.state), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // Covers AE1.
    func testPreviewReachesReadyWithoutCleaning() async {
        let runner = FakeMoleRunner()
        runner.responses["clean --dry-run"] = .success(previewLines)
        let flow = CleanFlow(runner: runner, freeSpace: { 12_000_000_000 })

        flow.startPreview()
        await waitUntil(flow) { if case .ready = $0 { true } else { false } }

        guard case .ready(let preview) = flow.state else { return XCTFail("state \(flow.state)") }
        XCTAssertEqual(preview.totalBytes, 3_500_000_000)
        XCTAssertEqual(runner.calls, [["clean", "--dry-run"]])
    }

    // Covers AE2 and AE3.
    func testCleanReportsMeasuredFreedSpaceAndSkippedItems() async {
        let runner = FakeMoleRunner()
        runner.responses["clean --dry-run"] = .success(previewLines)
        var free: Int64 = 10_000_000_000
        let flow = CleanFlow(runner: runner, freeSpace: { free })

        flow.startPreview()
        await waitUntil(flow) { if case .ready = $0 { true } else { false } }
        flow.confirmClean()
        free = 14_200_000_000
        await waitUntil(flow) { if case .done = $0 { true } else { false } }

        guard case .done(let result) = flow.state else { return XCTFail("state \(flow.state)") }
        XCTAssertEqual(result.freedBytes, 4_200_000_000)
        XCTAssertEqual(Formatters.bytes(result.freedBytes), "4.2 GB")
        XCTAssertEqual(result.skipped, [CleanPreviewParser.adminSkip])
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(runner.calls, [["clean", "--dry-run"], ["clean"]])
    }

    func testCancelWhenReadyNeverCleans() async {
        let runner = FakeMoleRunner()
        runner.responses["clean --dry-run"] = .success(previewLines)
        let flow = CleanFlow(runner: runner, freeSpace: { 0 })

        flow.startPreview()
        await waitUntil(flow) { if case .ready = $0 { true } else { false } }
        flow.cancel()

        XCTAssertEqual(flow.state, .idle)
        XCTAssertEqual(runner.calls, [["clean", "--dry-run"]])
    }

    func testZeroTotalIsEmpty() async {
        let runner = FakeMoleRunner()
        runner.responses["clean --dry-run"] = .success(["➤ Browsers", "  ✓ Nothing to clean"])
        let flow = CleanFlow(runner: runner, freeSpace: { 0 })

        flow.startPreview()
        await waitUntil(flow) { $0 == .empty }
        XCTAssertEqual(flow.state, .empty)
    }

    func testSecondPreviewWhileBusyIsIgnored() async {
        let runner = FakeMoleRunner()
        runner.delay = .milliseconds(300)
        runner.responses["clean --dry-run"] = .success(previewLines)
        let flow = CleanFlow(runner: runner, freeSpace: { 0 })

        flow.startPreview()
        flow.startPreview()
        await waitUntil(flow) { if case .ready = $0 { true } else { false } }
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testCancelDuringPreviewReturnsToIdle() async {
        let runner = FakeMoleRunner()
        runner.delay = .seconds(5)
        let flow = CleanFlow(runner: runner, freeSpace: { 0 })

        flow.startPreview()
        try? await Task.sleep(for: .milliseconds(50))
        flow.cancel()
        await waitUntil(flow) { $0 == .idle }
        XCTAssertEqual(flow.state, .idle)
    }

    func testUnreadablePreviewFailsWithoutCleaning() async {
        let runner = FakeMoleRunner()
        runner.responses["clean --dry-run"] = .success(["garbage"])
        let flow = CleanFlow(runner: runner, freeSpace: { 0 })

        flow.startPreview()
        await waitUntil(flow) { if case .failed = $0 { true } else { false } }
        guard case .failed(let message) = flow.state else { return XCTFail("state \(flow.state)") }
        XCTAssertTrue(message.contains("Nothing was deleted"))
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testMissingEngineFailsClearly() {
        let flow = CleanFlow(runner: nil, freeSpace: { 0 })
        flow.startPreview()
        XCTAssertEqual(flow.state, .failed(MoleError.notInstalled.localizedDescription))
    }

    func testFreedNeverNegative() {
        XCTAssertEqual(CleanFlow.freed(before: 10, after: 5), 0)
        XCTAssertEqual(CleanFlow.freed(before: nil, after: 5), 0)
    }
}
