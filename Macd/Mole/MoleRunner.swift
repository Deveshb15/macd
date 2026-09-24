import Darwin
import Foundation
import Synchronization

nonisolated struct MoleRunResult: Sendable {
    let exitCode: Int32
    let output: [String]
}

nonisolated enum MoleError: Error, Equatable, LocalizedError {
    case notInstalled
    case launchFailed(Int32)
    case failed(exitCode: Int32, tail: [String])
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The cleaning engine is missing from the app. Reinstall mac'd."
        case .launchFailed(let code):
            "The cleaning engine could not start (error \(code))."
        case .failed(let exitCode, let tail):
            (["The cleaning engine stopped with an error (code \(exitCode))."] + tail).joined(separator: "\n")
        case .timedOut:
            "The cleaning engine took too long and was stopped."
        case .cancelled:
            "Cancelled."
        }
    }
}

/// Anything that can run a Mole command. `CleanFlow` and the analyze model depend on this, so tests can fake it.
protocol MoleCommandRunning: Sendable {
    func run(
        _ arguments: [String],
        timeout: Duration,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> MoleRunResult
}

/// Runs the bundled Mole with no terminal: stdin is /dev/null, color is off, and the
/// command gets its own process group so cancelling stops every child process too.
nonisolated struct MoleRunner: MoleCommandRunning {
    let scriptURL: URL

    /// The Mole copy embedded in the app bundle, or `nil` if it is missing.
    static func bundled() -> MoleRunner? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("mole/mole"),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return MoleRunner(scriptURL: url)
    }

    func run(
        _ arguments: [String],
        timeout: Duration = .seconds(900),
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> MoleRunResult {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw MoleError.notInstalled
        }
        let process = try SpawnedProcess.launch(
            executable: "/bin/bash",
            arguments: [scriptURL.path] + arguments,
            environment: Self.environment()
        )

        let watchdog = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            process.terminate(reason: .timedOut)
        }
        defer { watchdog.cancel() }

        let (status, lines) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let lines = process.readLines(onLine: onLine)
                    let status = process.waitForExit()
                    continuation.resume(returning: (status, lines))
                }
            }
        } onCancel: {
            process.terminate(reason: .cancelled)
        }

        switch process.terminationReason {
        case .cancelled: throw MoleError.cancelled
        case .timedOut: throw MoleError.timedOut
        case nil: break
        }
        guard status == 0 else {
            throw MoleError.failed(exitCode: status, tail: Array(lines.suffix(5)))
        }
        return MoleRunResult(exitCode: status, output: lines)
    }

    static func environment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "HOME": home,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TERM": "dumb",
            "NO_COLOR": "1",
            "TMPDIR": NSTemporaryDirectory(),
        ]
    }
}

/// Strips ANSI escape sequences and carriage-return redraws from terminal output.
nonisolated enum TerminalText {
    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}[()][A-Za-z0-9]")

    static func clean(_ line: String) -> String {
        let lastSegment = line.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? line
        let range = NSRange(lastSegment.startIndex..., in: lastSegment)
        return ansi.stringByReplacingMatches(in: lastSegment, range: range, withTemplate: "")
    }
}

/// A child process launched with `posix_spawn` in its own process group.
nonisolated final class SpawnedProcess: Sendable {
    enum TerminationReason: Sendable { case cancelled, timedOut }

    let pid: pid_t
    private let outputFD: Int32
    private let reason = Mutex<TerminationReason?>(nil)

    var terminationReason: TerminationReason? { reason.withLock { $0 } }

    private init(pid: pid_t, outputFD: Int32) {
        self.pid = pid
        self.outputFD = outputFD
    }

    static func launch(executable: String, arguments: [String], environment: [String: String]) throws -> SpawnedProcess {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw MoleError.launchFailed(errno) }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStringArray(argv) { argvPointer in
            withCStringArray(envp) { envPointer in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointer, envPointer)
            }
        }
        close(fds[1])
        guard result == 0 else {
            close(fds[0])
            throw MoleError.launchFailed(result)
        }
        return SpawnedProcess(pid: pid, outputFD: fds[0])
    }

    /// Blocks until the output pipe closes, reporting each cleaned line as it arrives.
    func readLines(onLine: (String) -> Void) -> [String] {
        defer { close(outputFD) }
        var lines: [String] = []
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)

        func emit(_ data: Data) {
            let line = TerminalText.clean(String(decoding: data, as: UTF8.self))
            lines.append(line)
            onLine(line)
        }

        while true {
            let count = read(outputFD, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                emit(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { emit(pending) }
        return lines
    }

    /// Waits for the process and returns its exit code (128 + signal when killed).
    func waitForExit() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    /// Interrupts the whole process group, escalating to SIGTERM and SIGKILL if it lingers.
    func terminate(reason newReason: TerminationReason) {
        let first = reason.withLock { current -> Bool in
            guard current == nil else { return false }
            current = newReason
            return true
        }
        guard first else { return }
        let group = -pid
        kill(group, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(group, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { kill(group, SIGKILL) }
    }
}

nonisolated private func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
