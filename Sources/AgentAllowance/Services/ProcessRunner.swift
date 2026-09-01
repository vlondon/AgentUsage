import Foundation

struct ProcessResult: Sendable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32

    var outputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }
}

enum ProcessRunnerError: LocalizedError {
    case executableNotFound(String)
    case timedOut(String)
    case failedToLaunch(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            "Could not find \(name). Install it or add it to PATH."
        case .timedOut(let name):
            "\(name) did not respond in time."
        case .failedToLaunch(let name):
            "Could not start \(name)."
        }
    }
}

enum ProcessRunner {
    static func findExecutable(named name: String, preferredPaths: [String] = []) -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let directories = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ] + pathEntries

        for candidate in preferredPaths + directories.map({ "\($0)/\(name)" }) {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func run(
        executable: String,
        arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval = 15,
        environment additions: [String: String] = [:],
        waitForOutputContaining completionMarker: String? = nil
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .utility) {
            try runSynchronously(
                executable: executable,
                arguments: arguments,
                input: input,
                timeout: timeout,
                environment: additions,
                completionMarker: completionMarker
            )
        }.value
    }

    private static func runSynchronously(
        executable: String,
        arguments: [String],
        input: Data?,
        timeout: TimeInterval,
        environment additions: [String: String],
        completionMarker: String?
    ) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        let completion = DispatchSemaphore(value: 0)
        let capturedOutput = OutputCapture(
            marker: completionMarker.map { Data($0.utf8) }
        )
        let capturedError = OutputCapture(marker: nil)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        var environment = ProcessInfo.processInfo.environment
        additions.forEach { environment[$0.key] = $0.value }
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.terminationHandler = { _ in completion.signal() }

        // Drain both pipes while the child runs. Waiting for termination before
        // reading can deadlock when a command writes more than the pipe buffer.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if capturedOutput.append(chunk) {
                try? stdin.fileHandleForWriting.close()
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            _ = capturedError.append(chunk)
        }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.failedToLaunch(
                URL(fileURLWithPath: executable).lastPathComponent
            )
        }

        if let input {
            stdin.fileHandleForWriting.write(input)
        }
        if completionMarker == nil {
            try? stdin.fileHandleForWriting.close()
        }

        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = completion.wait(timeout: .now() + 2)
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw ProcessRunnerError.timedOut(
                URL(fileURLWithPath: executable).lastPathComponent
            )
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        _ = capturedOutput.append(stdout.fileHandleForReading.readDataToEndOfFile())
        _ = capturedError.append(stderr.fileHandleForReading.readDataToEndOfFile())

        return ProcessResult(
            standardOutput: capturedOutput.data,
            standardError: capturedError.data,
            terminationStatus: process.terminationStatus
        )
    }
}

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let marker: Data?
    private var storage = Data()
    private var markerReported = false

    init(marker: Data?) {
        self.marker = marker
    }

    var data: Data {
        lock.withLock { storage }
    }

    /// Returns true exactly once, when the marker first appears.
    func append(_ chunk: Data) -> Bool {
        lock.withLock {
            storage.append(chunk)
            guard !markerReported,
                  let marker,
                  storage.range(of: marker) != nil
            else { return false }
            markerReported = true
            return true
        }
    }
}
