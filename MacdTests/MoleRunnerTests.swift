import XCTest
@testable import Macd

@MainActor
final class MoleRunnerTests: XCTestCase {
    private lazy var directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macd-runner-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }()

    private func stub(_ body: String) throws -> MoleRunner {
        let url = directory.appendingPathComponent("mole")
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        return MoleRunner(scriptURL: url)
    }

    func testStreamsLinesInOrder() async throws {
        let runner = try stub("echo one; echo two; echo three")
        let received = LineCollector()
        let result = try await runner.run([], timeout: .seconds(10)) { received.append($0) }
        XCTAssertEqual(result.output, ["one", "two", "three"])
        XCTAssertEqual(received.lines, ["one", "two", "three"])
    }

    func testPassesArgumentsAndStripsANSI() async throws {
        let runner = try stub(#"printf '\033[0;32m%s\033[0m\n' "$@""#)
        let result = try await runner.run(["clean", "--dry-run"], timeout: .seconds(10)) { _ in }
        XCTAssertEqual(result.output, ["clean", "--dry-run"])
    }

    func testStdinIsNotATerminal() async throws {
        let runner = try stub(#"if [[ -t 0 ]]; then echo tty; else echo notty; fi"#)
        let result = try await runner.run([], timeout: .seconds(10)) { _ in }
        XCTAssertEqual(result.output, ["notty"])
    }

    func testNonZeroExitIsFailureWithTail() async throws {
        let runner = try stub("for i in 1 2 3 4 5 6 7; do echo line$i; done; exit 3")
        do {
            _ = try await runner.run([], timeout: .seconds(10)) { _ in }
            XCTFail("expected failure")
        } catch let MoleError.failed(exitCode, tail) {
            XCTAssertEqual(exitCode, 3)
            XCTAssertEqual(tail, ["line3", "line4", "line5", "line6", "line7"])
        }
    }

    func testCancelStopsProcessAndChildren() async throws {
        let marker = directory.appendingPathComponent("child-still-running")
        let runner = try stub("(sleep 5; touch '\(marker.path)') & echo started; wait")
        let task = Task { try await runner.run([], timeout: .seconds(30)) { _ in } }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as MoleError {
            XCTAssertEqual(error, .cancelled)
        }
        try await Task.sleep(for: .seconds(6))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "child process survived cancel")
    }

    func testTimeout() async throws {
        let runner = try stub("sleep 10")
        do {
            _ = try await runner.run([], timeout: .milliseconds(300)) { _ in }
            XCTFail("expected timeout")
        } catch let error as MoleError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testMissingScriptIsNotInstalled() async {
        let runner = MoleRunner(scriptURL: directory.appendingPathComponent("absent"))
        do {
            _ = try await runner.run([], timeout: .seconds(1)) { _ in }
            XCTFail("expected notInstalled")
        } catch let error as MoleError {
            XCTAssertEqual(error, .notInstalled)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTerminalTextCleaning() {
        XCTAssertEqual(TerminalText.clean("\u{1B}[0;32m✓\u{1B}[0m done"), "✓ done")
        XCTAssertEqual(TerminalText.clean("Scanning 10%\rScanning 90%\rDone"), "Done")
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock(); storage.append(line); lock.unlock()
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
