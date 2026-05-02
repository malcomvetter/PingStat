import Foundation

struct DNSCheckResult {
    let status: DNSCheckStatus
}

final class DNSService {
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
        probeHostname: String,
        configuredServers: [String],
        fallbackServers: [String],
        customNameservers: [String],
        timeoutMs: Int
    ) async -> DNSCheckResult {
        let hostname = probeHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = configuredServers.filter { !$0.isEmpty }
        let customFiltered = customNameservers.filter { !$0.isEmpty }
        async let customResponsesTask = resolveAcrossServers(
            servers: customFiltered,
            hostname: hostname,
            timeoutMs: timeoutMs
        )

        var status = DNSCheckStatus()
        status.lastCheck = Date()
        status.configuredServers = configured
        status.fallbackServers = fallbackServers

        async let fallbackResponsesTask = resolveAcrossServers(
            servers: fallbackServers,
            hostname: hostname,
            timeoutMs: timeoutMs
        )

        if configured.isEmpty {
            let (fallbackResponses, customResponses) = await (fallbackResponsesTask, customResponsesTask)
            Self.applyFallbackAnswerMap(&status, responses: fallbackResponses)
            Self.applyCustomProbes(&status, responses: customResponses)
            status.lastResolverDetailLines = Self.mergeProbeLines(
                configured: [],
                fallback: fallbackResponses,
                custom: customResponses
            )
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
            hostname: hostname,
            timeoutMs: timeoutMs
        )
        let (configuredResponses, fallbackResponses, customResponses) = await (
            configuredResponsesTask,
            fallbackResponsesTask,
            customResponsesTask
        )
        Self.applyFallbackAnswerMap(&status, responses: fallbackResponses)
        Self.applyCustomProbes(&status, responses: customResponses)
        status.lastResolverDetailLines = Self.mergeProbeLines(
            configured: configuredResponses,
            fallback: fallbackResponses,
            custom: customResponses
        )

        let configuredSuccesses = configuredResponses.filter(\.success)
        let configuredTimeouts = configuredResponses.filter { !$0.success }.map(\.server)
        status.timedOutServers = configuredTimeouts
        status.allConfiguredTimedOut = configuredSuccesses.isEmpty
        status.resolvedIPs = Array(Set(configuredSuccesses.flatMap(\.ips))).sorted()
        status.resolvedPrivateIP = status.resolvedIPs.contains(where: Self.isRFC1918)

        if status.allConfiguredTimedOut {
            let configuredSet = Set(configured)
            let publicFallbackIPs = Set(fallbackServers)
            let shouldFallback = configuredSet.isDisjoint(with: publicFallbackIPs)
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

    private static func mergeProbeLines(
        configured: [ServerResolution],
        fallback: [ServerResolution],
        custom: [ServerResolution]
    ) -> [String] {
        configured.map(\.detailLine) + fallback.map(\.detailLine) + custom.map(\.detailLine)
    }

    private static func applyCustomProbes(_ status: inout DNSCheckStatus, responses: [ServerResolution]) {
        for r in responses {
            status.customNameserverProbes[r.server] = r.success
        }
    }

    private static func applyFallbackAnswerMap(_ status: inout DNSCheckStatus, responses: [ServerResolution]) {
        for r in responses {
            status.fallbackAnsweredByServer[r.server] = r.success
        }
    }

    private func resolveAcrossServers(
        servers: [String],
        hostname: String,
        timeoutMs: Int
    ) async -> [ServerResolution] {
        await withTaskGroup(of: ServerResolution.self, returning: [ServerResolution].self) { group in
            for server in servers {
                group.addTask {
                    await self.resolve(server: server, hostname: hostname, timeoutMs: timeoutMs)
                }
            }

            var results: [ServerResolution] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func resolve(server: String, hostname: String, timeoutMs: Int) async -> ServerResolution {
        let res = await DNSUDPQuery.resolveARecordDetails(
            hostname: hostname,
            nameserver: server,
            timeoutMs: timeoutMs
        )
        let filtered = res.ipv4Addresses.filter { Self.isIPv4($0) }
        let success = !filtered.isEmpty
        let responsePart: String
        if res.responseCode == nil {
            responsePart = "no reply (timeout)"
        } else if !res.answerSummaries.isEmpty {
            responsePart = res.answerSummaries.joined(separator: "; ")
        } else {
            responsePart = "empty answers"
        }
        let detailLine = "@\(server) Q A \(hostname) → \(responsePart)"
        return ServerResolution(
            server: server,
            success: success,
            ips: filtered,
            detailLine: detailLine
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
    let detailLine: String
}
