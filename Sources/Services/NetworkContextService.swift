import Foundation
import Network

@MainActor
final class NetworkContextService: ObservableObject {
    @Published private(set) var context: NetworkContext = .empty

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.example.MacNetStatus.path")
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

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshContext(pathStatus: path.status)
            }
        }
        monitor.start(queue: monitorQueue)
        Task { @MainActor in
            await refreshContext(pathStatus: monitor.currentPath.status)
        }
    }

    deinit {
        monitor.cancel()
    }

    func refreshContext(pathStatus: NWPath.Status? = nil) async {
        let connected = (pathStatus ?? monitor.currentPath.status) == .satisfied
        let routeData = (try? await commandRunner.run(
            launchPath: "/usr/sbin/route",
            arguments: ["-n", "get", "default"],
            timeoutMs: 1_000
        ))?.output ?? ""
        let dnsData = (try? await commandRunner.run(
            launchPath: "/usr/sbin/scutil",
            arguments: ["--dns"],
            timeoutMs: 1_500
        ))?.output ?? ""

        let interface = parseInterface(routeData)
        let gateway = parseGateway(routeData)
        let localIP = await localIPForInterface(interface)
        let interfaceType = inferInterfaceType(interface)
        let dnsServers = parseDNSServers(dnsData)

        context = NetworkContext(
            connected: connected,
            interfaceName: interface,
            interfaceType: interfaceType,
            localIP: localIP,
            gatewayIP: gateway,
            dnsServers: dnsServers
        )

        logger.debug(
            .networkContext,
            "Context refreshed connected=\(connected) interface=\(interface ?? "-") ip=\(localIP ?? "-") gateway=\(gateway ?? "-") dns=\(dnsServers.joined(separator: ","))",
            enabled: debugEnabledProvider()
        )
    }

    private func parseInterface(_ route: String) -> String? {
        parseValue(in: route, prefix: "interface:")
    }

    private func parseGateway(_ route: String) -> String? {
        parseValue(in: route, prefix: "gateway:")
    }

    private func parseValue(in output: String, prefix: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return trimmed.replacingOccurrences(of: prefix, with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func localIPForInterface(_ interface: String?) async -> String? {
        guard let interface else { return nil }
        guard let result = try? await commandRunner.run(
            launchPath: "/usr/sbin/ipconfig",
            arguments: ["getifaddr", interface],
            timeoutMs: 1_000
        ) else {
            return nil
        }
        let ip = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return ip.isEmpty ? nil : ip
    }

    private func parseDNSServers(_ dnsOutput: String) -> [String] {
        var servers: [String] = []
        for line in dnsOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("nameserver[") else { continue }
            let parts = trimmed.split(separator: ":")
            guard let last = parts.last else { continue }
            let candidate = last.trimmingCharacters(in: .whitespaces)
            if isIPAddress(candidate) {
                servers.append(candidate)
            }
        }
        return Array(Set(servers)).sorted()
    }

    private func inferInterfaceType(_ name: String?) -> String? {
        guard let name else { return nil }
        if name.hasPrefix("en") { return "Ethernet/Wi-Fi" }
        if name.hasPrefix("pdp_ip") { return "Cellular" }
        if name.hasPrefix("utun") { return "VPN" }
        return "Other"
    }

    private func isIPAddress(_ value: String) -> Bool {
        let pattern = #"^(\d{1,3}\.){3}\d{1,3}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
