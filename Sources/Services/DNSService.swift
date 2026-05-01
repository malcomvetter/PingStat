import Foundation

struct DNSCheckResult {
    let status: DNSCheckStatus
}

final class DNSService {
    private static let probeHostname = "captive.apple.com"

    private let logger: LoggingService
    private let debugEnabledProvider: () -> Bool

    init(
        logger: LoggingService,
        debugEnabledProvider: @escaping () -> Bool
    ) {
        self.logger = logger
        self.debugEnabledProvider = debugEnabledProvider
    }

    func check(
        configuredServers: [String],
        fallbackServers: [String],
        timeoutMs: Int
    ) async -> DNSCheckResult {
        let configured = configuredServers.filter { !$0.isEmpty }
        var status = DNSCheckStatus()
        status.lastCheck = Date()
        status.configuredServers = configured
        status.fallbackServers = fallbackServers

        async let fallbackResponsesTask = resolveAcrossServers(
            servers: fallbackServers,
            timeoutMs: timeoutMs
        )

        if configured.isEmpty {
            let fallbackResponses = await fallbackResponsesTask
            Self.applyFallbackAnswerMap(&status, responses: fallbackResponses)
            status.allConfiguredTimedOut = true
            let fallbackSuccesses = fallbackResponses.filter(\.success)
            status.fallbackWorked = !fallbackSuccesses.isEmpty
            if status.fallbackWorked {
                status.resolvedIPs = Array(Set(fallbackSuccesses.flatMap(\.ips))).sorted()
                status.resolvedPrivateIP = status.resolvedIPs.contains(where: Self.isRFC1918)
            }
            logger.debug(
                .dns,
                "DNS check (no configured) fallback=\(status.fallbackWorked) ips=\(status.resolvedIPs.joined(separator: ","))",
                enabled: debugEnabledProvider()
            )
            return DNSCheckResult(status: status)
        }

        async let configuredResponsesTask = resolveAcrossServers(
            servers: configured,
            timeoutMs: timeoutMs
        )
        let (configuredResponses, fallbackResponses) = await (configuredResponsesTask, fallbackResponsesTask)
        Self.applyFallbackAnswerMap(&status, responses: fallbackResponses)

        let configuredSuccesses = configuredResponses.filter(\.success)
        let configuredTimeouts = configuredResponses.filter { !$0.success }.map(\.server)
        status.timedOutServers = configuredTimeouts
        status.allConfiguredTimedOut = configuredSuccesses.isEmpty
        status.resolvedIPs = Array(Set(configuredSuccesses.flatMap(\.ips))).sorted()
        status.resolvedPrivateIP = status.resolvedIPs.contains(where: Self.isRFC1918)

        if status.allConfiguredTimedOut {
            let configuredSet = Set(configured)
            let cloudflareGoogle = Set(fallbackServers)
            let shouldFallback = configuredSet.isDisjoint(with: cloudflareGoogle)
            if shouldFallback {
                let fallbackSuccesses = fallbackResponses.filter(\.success)
                status.fallbackWorked = !fallbackSuccesses.isEmpty
                if status.fallbackWorked {
                    status.resolvedIPs = Array(Set(status.resolvedIPs + fallbackSuccesses.flatMap(\.ips))).sorted()
                    status.resolvedPrivateIP = status.resolvedIPs.contains(where: Self.isRFC1918)
                }
            }
        }

        logger.debug(
            .dns,
            "DNS check configuredTimedOut=\(status.allConfiguredTimedOut) privateIP=\(status.resolvedPrivateIP) fallback=\(status.fallbackWorked)",
            enabled: debugEnabledProvider()
        )

        return DNSCheckResult(status: status)
    }

    private static func applyFallbackAnswerMap(_ status: inout DNSCheckStatus, responses: [ServerResolution]) {
        for r in responses {
            status.fallbackAnsweredByServer[r.server] = r.success
        }
    }

    private func resolveAcrossServers(
        servers: [String],
        timeoutMs: Int
    ) async -> [ServerResolution] {
        await withTaskGroup(of: ServerResolution.self, returning: [ServerResolution].self) { group in
            for server in servers {
                group.addTask {
                    await self.resolve(server: server, timeoutMs: timeoutMs)
                }
            }

            var results: [ServerResolution] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func resolve(server: String, timeoutMs: Int) async -> ServerResolution {
        let ips = await DNSUDPQuery.resolveA(
            hostname: Self.probeHostname,
            nameserver: server,
            timeoutMs: timeoutMs
        )
        let filtered = ips.filter { Self.isIPv4($0) }
        return ServerResolution(
            server: server,
            success: !filtered.isEmpty,
            ips: filtered
        )
    }

    private static func isIPv4(_ value: String) -> Bool {
        let pattern = #"^(\d{1,3}\.){3}\d{1,3}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isRFC1918(ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        return false
    }
}

private struct ServerResolution {
    let server: String
    let success: Bool
    let ips: [String]
}
