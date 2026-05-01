import Foundation
import Network

@MainActor
final class NetworkContextService: ObservableObject {
    @Published private(set) var context: NetworkContext = .empty

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.example.PingStat.path")
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
                await self.refreshContext(pathStatus: path.status, path: path)
            }
        }
        monitor.start(queue: monitorQueue)
        Task { @MainActor in
            await refreshContext(pathStatus: monitor.currentPath.status, path: monitor.currentPath)
        }
    }

    deinit {
        monitor.cancel()
    }

    func refreshContext(pathStatus: NWPath.Status? = nil, path activePath: NWPath? = nil) async {
        let path = activePath ?? monitor.currentPath
        let connected = (pathStatus ?? path.status) == .satisfied
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

        var interfaceName = parseInterface(routeData)
        let gateway = parseGateway(routeData)
        var interfaceType = inferInterfaceType(interfaceName)

        if let nw = matchingNWInterface(name: interfaceName, path: path) {
            interfaceType = describeNWInterfaceType(nw.type)
        } else if interfaceName == nil, let primary = pickPrimaryInterface(from: path) {
            interfaceName = primary.name
            interfaceType = describeNWInterfaceType(primary.type)
        }

        let localIP = await localIPForInterface(interfaceName)
        let dnsServers = parseDNSServers(dnsData)

        context = NetworkContext(
            connected: connected,
            interfaceName: interfaceName,
            interfaceType: interfaceType,
            localIP: localIP,
            gatewayIP: gateway,
            dnsServers: dnsServers
        )

        logger.debug(
            .networkContext,
            "Context refreshed connected=\(connected) interface=\(interfaceName ?? "-") ip=\(localIP ?? "-") gateway=\(gateway ?? "-") dns=\(dnsServers.joined(separator: ","))",
            enabled: debugEnabledProvider()
        )
    }

    private func matchingNWInterface(name: String?, path: NWPath) -> NWInterface? {
        guard let name else { return nil }
        return path.availableInterfaces.first { $0.name == name }
    }

    /// Prefer real transports over loopback/tunnels when the system reports multiple interfaces.
    private func pickPrimaryInterface(from path: NWPath) -> NWInterface? {
        let list = path.availableInterfaces
        guard !list.isEmpty else { return nil }
        func rank(_ iface: NWInterface) -> Int {
            switch iface.type {
            case .wifi: return 0
            case .wiredEthernet: return 1
            case .cellular: return 2
            case .other: return iface.name.hasPrefix("utun") ? 10 : 4
            case .loopback: return 20
            @unknown default: return 15
            }
        }
        return list.min { lhs, rhs in
            let rl = rank(lhs), rr = rank(rhs)
            if rl != rr { return rl < rr }
            return lhs.name < rhs.name
        }
    }

    private func describeNWInterfaceType(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:
            return "Wi-Fi"
        case .wiredEthernet:
            return "Ethernet"
        case .cellular:
            return "Cellular"
        case .loopback:
            return "Loopback"
        case .other:
            return "Other"
        @unknown default:
            return "Other"
        }
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
