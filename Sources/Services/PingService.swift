import Foundation

struct PingResponse {
    let target: PingTarget
    let sample: PingSample
}

final class PingService {
    private let commandRunner: CommandRunner
    private let logger: LoggingService
    private let debugEnabledProvider: () -> Bool

    init(
        commandRunner: CommandRunner,
        logger: LoggingService,
        debugEnabledProvider: @escaping () -> Bool
    ) {
        self.commandRunner = commandRunner
        self.logger = logger
        self.debugEnabledProvider = debugEnabledProvider
    }

    func ping(target: PingTarget, timeoutMs: Int) async -> PingResponse {
        let start = Date()
        let waitSeconds = max(1, Int(ceil(Double(timeoutMs) / 1_000)))
        do {
            let result = try await commandRunner.run(
                launchPath: "/sbin/ping",
                arguments: ["-c", "1", "-W", "\(waitSeconds)", target.host],
                timeoutMs: UInt64(timeoutMs + 150)
            )
            let elapsedMs = Date().timeIntervalSince(start) * 1_000
            let success = result.exitCode == 0 && result.output.contains("bytes from")
            let parsedRTT = parseRTT(output: result.output)
            let timedOut = !success
            let sample = PingSample(
                timestamp: Date(),
                success: success,
                rttMs: success ? min(parsedRTT ?? elapsedMs, Double(timeoutMs)) : nil,
                timedOut: timedOut,
                message: parsePingMessage(output: result.output, success: success)
            )
            logger.debug(
                .ping,
                "\(target.label) success=\(success) rtt=\(sample.rttMs ?? -1)",
                enabled: debugEnabledProvider()
            )
            return PingResponse(target: target, sample: sample)
        } catch CommandRunnerError.timedOut {
            let sample = PingSample(
                timestamp: Date(),
                success: false,
                rttMs: nil,
                timedOut: true,
                message: "Timed out after \(timeoutMs)ms"
            )
            logger.debug(.ping, "\(target.label) timed out", enabled: debugEnabledProvider())
            return PingResponse(target: target, sample: sample)
        } catch {
            logger.log(.error, category: .errors, "Ping failed for \(target.host): \(error.localizedDescription)")
            let sample = PingSample(
                timestamp: Date(),
                success: false,
                rttMs: nil,
                timedOut: true,
                message: "Ping error: \(error.localizedDescription)"
            )
            return PingResponse(target: target, sample: sample)
        }
    }

    private func parsePingMessage(output: String, success: Bool) -> String {
        if success {
            return "ok"
        }
        if output.contains("Request timeout") {
            return "Timed out"
        }
        if output.contains("No route to host") {
            return "No route to host"
        }
        return "Ping failed"
    }

    private func parseRTT(output: String) -> Double? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("time=") else { continue }
            if let range = trimmed.range(of: "time=") {
                let tail = trimmed[range.upperBound...]
                if let msToken = tail.split(separator: " ").first {
                    let cleaned = msToken.replacingOccurrences(of: "ms", with: "")
                    return Double(cleaned)
                }
            }
        }
        return nil
    }
}
