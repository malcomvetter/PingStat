import Foundation

enum CommandRunnerError: Error {
    case failedToLaunch
    case timedOut
}

struct CommandResult {
    let output: String
    let exitCode: Int32
}

final class CommandRunner {
    func run(
        launchPath: String,
        arguments: [String],
        timeoutMs: UInt64
    ) async throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.failedToLaunch
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw CommandRunnerError.timedOut
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        var merged = Data()
        merged.append(outputData)
        merged.append(errorData)
        let output = String(decoding: merged, as: UTF8.self)
        return CommandResult(output: output, exitCode: process.terminationStatus)
    }
}
