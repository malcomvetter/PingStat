import Foundation

struct PingResponse {
    let target: PingTarget
    let sample: PingSample
}

final class PingService {
    private let logger: LoggingService
    private let debugEnabledProvider: () -> Bool

    init(
        logger: LoggingService,
        debugEnabledProvider: @escaping () -> Bool
    ) {
        self.logger = logger
        self.debugEnabledProvider = debugEnabledProvider
    }

    func ping(target: PingTarget, timeoutMs: Int) async -> PingResponse {
        do {
            let rttMs = try await ICMPPing.echo(host: target.host, timeoutMs: timeoutMs)
            let clamped = min(rttMs, Double(timeoutMs))
            let sample = PingSample(
                timestamp: Date(),
                success: true,
                rttMs: clamped,
                timedOut: false,
                message: "ok"
            )
            logger.debug(
                .ping,
                "\(target.label) success=true rtt=\(sample.rttMs ?? -1)",
                enabled: debugEnabledProvider()
            )
            return PingResponse(target: target, sample: sample)
        } catch let error as ICMPPingError {
            switch error {
            case .timedOut:
                let sample = PingSample(
                    timestamp: Date(),
                    success: false,
                    rttMs: nil,
                    timedOut: true,
                    message: "Timed out after \(timeoutMs)ms"
                )
                logger.debug(.ping, "\(target.label) timed out", enabled: debugEnabledProvider())
                return PingResponse(target: target, sample: sample)

            case let .resolveFailed(host):
                logger.log(.error, category: .errors, "Ping resolve failed for \(host)")
                let sample = PingSample(
                    timestamp: Date(),
                    success: false,
                    rttMs: nil,
                    timedOut: true,
                    message: "Could not resolve \(host) (IPv4)"
                )
                return PingResponse(target: target, sample: sample)

            case let .socketFailed(code):
                logger.log(.error, category: .errors, "ICMP socket failed errno=\(code)")
                let sample = PingSample(
                    timestamp: Date(),
                    success: false,
                    rttMs: nil,
                    timedOut: true,
                    message:
                        "ICMP socket failed (\(code)). Grant network access if prompted; ICMP may be blocked."
                )
                return PingResponse(target: target, sample: sample)

            case let .sendFailed(code), let .recvFailed(code), let .optionFailed(code):
                logger.log(.error, category: .errors, "ICMP failed errno=\(code)")
                let sample = PingSample(
                    timestamp: Date(),
                    success: false,
                    rttMs: nil,
                    timedOut: true,
                    message: "ICMP error (errno \(code))"
                )
                return PingResponse(target: target, sample: sample)
            }
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
}
