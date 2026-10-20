import Foundation
import Synchronization

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
}

/// Runs a short-lived child process and collects its output.
enum ProcessRunner {

    static func run(
        executable: URL,
        arguments: [String],
        timeout: Duration
    ) async -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Detach stdin so ssh can never block waiting on a prompt we'd
        // never see. BatchMode covers the SSH side; this covers the rest.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ProcessResult(
                exitCode: -1, stdout: "",
                stderr: "could not launch \(executable.path): \(error.localizedDescription)",
                timedOut: false
            )
        }

        // Drain both pipes concurrently with waiting for exit. A child that
        // writes more than the pipe buffer holds would otherwise block
        // forever on write while we block on waitUntilExit.
        async let stdoutData = readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = readToEnd(stderrPipe.fileHandleForReading)

        let timedOut = Mutex(false)
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            timedOut.withLock { $0 = true }
            terminate(process)
        }

        await withTaskCancellationHandler {
            await waitForExit(process)
        } onCancel: {
            terminate(process)
        }
        timeoutTask.cancel()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: await stdoutData),
            stderr: String(decoding: await stderrData),
            timedOut: timedOut.withLock { $0 }
        )
    }

    // Both helpers hop onto a background thread, because the only APIs for
    // reading a pipe to the end and waiting on a process are blocking ones.

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
    }
}

private extension String {
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? ""
    }
}
