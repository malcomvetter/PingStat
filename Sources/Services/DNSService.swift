import Foundation

struct DNSCheckResult {
    let status: DNSCheckStatus
}

final class DNSService {
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

        if configured.isEmpty {
            status.allConfiguredTimedOut = true
            status.fallbackWorked = false
            return await runFallback(status: status, fallbackServers: fallbackServers, timeoutMs: timeoutMs)
        }

        let configuredResponses = await resolveAcrossServers(
            servers: configured,
            timeoutMs: timeoutMs
        )

        let configuredSuccesses = configuredResponses.filter { $0.success }
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
                return await runFallback(status: status, fallbackServers: fallbackServers, timeoutMs: timeoutMs)
            }
        }

        logger.debug(
            .dns,
            "DNS check configuredTimedOut=\(status.allConfiguredTimedOut) privateIP=\(status.resolvedPrivateIP) fallback=\(status.fallbackWorked)",
            enabled: debugEnabledProvider()
        )

        return DNSCheckResult(status: status)
    }

    private func runFallback(
        status: DNSCheckStatus,
        fallbackServers: [String],
        timeoutMs: Int
    ) async -> DNSCheckResult {
        var status = status
        let fallbackResponses = await resolveAcrossServers(
            servers: fallbackServers,
            timeoutMs: timeoutMs
        )
        let fallbackSuccesses = fallbackResponses.filter { $0.success }
        status.fallbackWorked = !fallbackSuccesses.isEmpty
        if status.fallbackWorked {
            status.resolvedIPs = Array(Set(status.resolvedIPs + fallbackSuccesses.flatMap(\.ips))).sorted()
            status.resolvedPrivateIP = status.resolvedIPs.contains(where: Self.isRFC1918)
        }
        logger.debug(
            .dns,
            "DNS fallback worked=\(status.fallbackWorked) ips=\(status.resolvedIPs.joined(separator: ","))",
            enabled: debugEnabledProvider()
        )
        return DNSCheckResult(status: status)
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
        do {
            let timeoutSeconds = max(1, Int(ceil(Double(timeoutMs) / 1_000)))
            let result = try await commandRunner.run(
                launchPath: "/usr/bin/dig",
                arguments: ["+time=\(timeoutSeconds)", "+tries=1", "@\(server)", "captive.apple.com", "A", "+short"],
                timeoutMs: UInt64(timeoutMs + 200)
            )
            let ips = result.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { Self.isIPv4($0) }
            return ServerResolution(
                server: server,
                success: !ips.isEmpty,
                ips: ips
            )
        } catch {
            return ServerResolution(server: server, success: false, ips: [])
        }
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
