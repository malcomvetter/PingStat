import Darwin
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
        var gateway = Self.normalizedIPv4Gateway(parseGateway(routeData))
        var interfaceType = inferInterfaceType(interfaceName)

        if let nw = matchingNWInterface(name: interfaceName, path: path) {
            interfaceType = describeNWInterfaceType(nw.type)
        } else if interfaceName == nil, let primary = pickPrimaryInterface(from: path) {
            interfaceName = primary.name
            interfaceType = describeNWInterfaceType(primary.type)
        }

        let localIP = await localIPForInterface(interfaceName)
        if let ifn = interfaceName {
            if gateway == nil {
                gateway = await gatewayFromIpconfigRouter(interface: ifn)
            }
            if gateway == nil {
                gateway = await gatewayFromNetstatDefault(interface: ifn)
            }
            if gateway == nil {
                gateway = await gatewayFromRouteGet(host: "1.1.1.1")
            }
        }
        let dnsServers = await resolveDNSServers(scutilOutput: dnsData, interfaceBSDName: interfaceName)

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
        Self.parseValue(in: route, prefix: "interface:")
    }

    private func parseGateway(_ route: String) -> String? {
        Self.parseValue(in: route, prefix: "gateway:")
    }

    /// Default route row from `netstat -rn -f inet` (IPv4 gateway on the active interface).
    private func gatewayFromNetstatDefault(interface: String) async -> String? {
        guard let result = try? await commandRunner.run(
            launchPath: "/usr/sbin/netstat",
            arguments: ["-rn", "-f", "inet"],
            timeoutMs: 1_500
        ) else {
            return nil
        }
        return Self.parseDefaultGatewayFromNetstat(output: result.output, preferredInterface: interface)
    }

    /// `route -n get <host>` often still reports a usable IPv4 `gateway:` when `route get default` does not.
    private func gatewayFromRouteGet(host: String) async -> String? {
        guard let result = try? await commandRunner.run(
            launchPath: "/usr/sbin/route",
            arguments: ["-n", "get", host],
            timeoutMs: 1_000
        ) else {
            return nil
        }
        return Self.normalizedIPv4Gateway(Self.parseValue(in: result.output, prefix: "gateway:"))
    }

    /// `route -n get default` often omits an IPv4 gateway on relay / iCloud Private Relay paths; `ipconfig` still reports the router.
    private func gatewayFromIpconfigRouter(interface: String) async -> String? {
        guard let result = try? await commandRunner.run(
            launchPath: "/usr/sbin/ipconfig",
            arguments: ["getoption", interface, "router"],
            timeoutMs: 1_000
        ) else {
            return nil
        }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.normalizedIPv4Gateway(value)
    }

    private static func normalizedIPv4Gateway(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("link#") { return nil }
        let pattern = #"^(\d{1,3}\.){3}\d{1,3}$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    private static func parseValue(in output: String, prefix: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return trimmed.replacingOccurrences(of: prefix, with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Picks IPv4 gateway from `default` rows; prefers the row whose `Netif` matches `preferredInterface`.
    private static func parseDefaultGatewayFromNetstat(output: String, preferredInterface: String) -> String? {
        var anyGateway: String?
        for line in output.split(separator: "\n") {
            let s = String(line)
            let parts = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            guard parts.first == "default", parts.count >= 3 else { continue }
            let gwCandidate = parts[1]
            guard let gw = normalizedIPv4Gateway(gwCandidate) else { continue }
            if parts.contains(preferredInterface) {
                return gw
            }
            if anyGateway == nil {
                anyGateway = gw
            }
        }
        return anyGateway
    }

    /// Prefer real resolver IPs from `scutil`; drop `127.0.0.1` when other nameservers exist. If only the stub appears, use `networksetup -getdnsservers` for the Wi‑Fi/Ethernet service tied to `en0`, etc.
    private func resolveDNSServers(scutilOutput: String, interfaceBSDName: String?) async -> [String] {
        let raw = Self.collectNameserversInOrder(from: scutilOutput)
        let nonLoopback = raw.filter { !["127.0.0.1", "0.0.0.0", "::1"].contains($0) }
        if !nonLoopback.isEmpty {
            return nonLoopback
        }
        guard let bsd = interfaceBSDName else {
            return raw
        }
        guard let fromSetup = await dnsServersFromNetworkSetup(interfaceBSDName: bsd) else {
            return raw
        }
        if !fromSetup.isEmpty {
            return fromSetup.map { Self.attachInterfaceZoneToLinkLocalIPv6($0, interfaceBSDName: bsd) }
        }
        return []
    }

    /// Pulls `nameserver[n] : …` from `scutil --dns` in order. Parses **resolver** blocks so `if_index : N (en0)` applies to
    /// **link-local IPv6** nameservers that omit `%` (common); otherwise UDP cannot scope `fe80::/64` correctly.
    static func collectNameserversInOrder(from dnsOutput: String) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        var pendingInBlock: [String] = []
        var ifIndexInBlock: UInt32?

        func flushBlock() {
            for raw in pendingInBlock {
                let withScope = Self.applyIfIndexToLinkLocalNameserver(raw, ifIndex: ifIndexInBlock)
                guard Self.isIPLiteral(withScope), !seen.contains(withScope) else { continue }
                ordered.append(withScope)
                seen.insert(withScope)
            }
            pendingInBlock.removeAll(keepingCapacity: true)
            ifIndexInBlock = nil
        }

        for line in dnsOutput.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("resolver #") {
                flushBlock()
                continue
            }
            if let idx = Self.parseScutilIfIndexLine(trimmed) {
                ifIndexInBlock = idx
                continue
            }
            guard trimmed.contains("nameserver[") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let candidate = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard Self.isIPLiteral(candidate) else { continue }
            pendingInBlock.append(candidate)
        }
        flushBlock()
        return ordered
    }

    /// `if_index : 12 (en0)` or `if_index : 12` — returns the numeric interface index for `sin6_scope_id`.
    private static func parseScutilIfIndexLine(_ line: String) -> UInt32? {
        guard line.hasPrefix("if_index") else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let after = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        var digits = ""
        for ch in after {
            if ch.isNumber { digits.append(ch) }
            else { break }
        }
        guard let v = UInt32(digits), v > 0 else { return nil }
        return v
    }

    private static func applyIfIndexToLinkLocalNameserver(_ raw: String, ifIndex: UInt32?) -> String {
        guard let ifIndex, ifIndex > 0 else { return raw }
        guard !raw.contains("%") else { return raw }
        guard isIPv6LinkLocalLiteral(raw) else { return raw }
        return "\(raw)%\(ifIndex)"
    }

    private static func attachInterfaceZoneToLinkLocalIPv6(_ raw: String, interfaceBSDName: String?) -> String {
        guard let ifName = interfaceBSDName, !ifName.isEmpty else { return raw }
        guard !raw.contains("%") else { return raw }
        guard isIPv6LinkLocalLiteral(raw) else { return raw }
        return "\(raw)%\(ifName)"
    }

    private static func isIPv6LinkLocalLiteral(_ value: String) -> Bool {
        let unzoned = stripZoneIndex(value.trimmingCharacters(in: .whitespacesAndNewlines))
        var addr = in6_addr()
        guard unzoned.withCString({ inet_pton(AF_INET6, $0, &addr) == 1 }) else { return false }
        // fe80::/10 (RFC 4291 link-local); Swift cannot use IN6_IS_ADDR_LINKLOCAL macro here.
        return withUnsafeBytes(of: &addr) { raw in
            let p = raw.bindMemory(to: UInt8.self)
            guard p.count >= 2 else { return false }
            return p[0] == 0xfe && (p[1] & 0xc0) == 0x80
        }
    }

    private func dnsServersFromNetworkSetup(interfaceBSDName: String) async -> [String]? {
        guard let serviceName = await networkSetupHardwarePortName(device: interfaceBSDName) else { return nil }
        guard let result = try? await commandRunner.run(
            launchPath: "/usr/sbin/networksetup",
            arguments: ["-getdnsservers", serviceName],
            timeoutMs: 2_000
        ) else {
            return nil
        }
        let text = result.output.lowercased()
        if text.contains("aren't any dns") || text.contains("there aren't any") {
            return []
        }
        var servers: [String] = []
        for line in result.output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard Self.isIPLiteral(t) else { continue }
            servers.append(Self.attachInterfaceZoneToLinkLocalIPv6(t, interfaceBSDName: interfaceBSDName))
        }
        return servers
    }

    private func networkSetupHardwarePortName(device: String) async -> String? {
        guard let result = try? await commandRunner.run(
            launchPath: "/usr/sbin/networksetup",
            arguments: ["-listallhardwareports"],
            timeoutMs: 2_000
        ) else {
            return nil
        }
        var currentPortName: String?
        for line in result.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                currentPortName = trimmed
                    .replacingOccurrences(of: "Hardware Port:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Device:") {
                let dev = trimmed.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if dev == device { return currentPortName }
            }
        }
        return nil
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let pattern = #"^(\d{1,3}\.){3}\d{1,3}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func stripZoneIndex(_ value: String) -> String {
        if let i = value.firstIndex(of: "%") {
            return String(value[..<i])
        }
        return value
    }

    private static func isIPv6Literal(_ value: String) -> Bool {
        let v = stripZoneIndex(value.trimmingCharacters(in: .whitespacesAndNewlines))
        var addr = in6_addr()
        return v.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }

    private static func isIPLiteral(_ value: String) -> Bool {
        isIPv4Address(value) || isIPv6Literal(value)
    }

    private func localIPForInterface(_ interface: String?) async -> String? {
        guard let interface else { return nil }
        if let ip = await ipconfigIPv4(for: interface) {
            return ip
        }
        // `ipconfig getifaddr` often returns nothing with iCloud Private Relay / “Limit IP Address
        // Tracking” enabled, while `getifaddrs` still reports the interface IPv4 (e.g. 192.0.0.2).
        return Self.ipv4FromGetifaddrs(interfaceName: interface)
    }

    private func ipconfigIPv4(for interface: String) async -> String? {
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

    /// Enumerates kernel interface addresses; complements `ipconfig getifaddr` for relay / privacy modes.
    private static func ipv4FromGetifaddrs(interfaceName: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }

        var candidates: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let node = ptr {
            defer { ptr = node.pointee.ifa_next }

            guard let addr = node.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: node.pointee.ifa_name)
            guard name == interfaceName else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard rc == 0 else { continue }

            let ip = String(cString: host).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ip.isEmpty, !ip.hasPrefix("127.") else { continue }
            candidates.append(ip)
        }

        guard !candidates.isEmpty else { return nil }
        let unique = Array(Set(candidates))
        return unique.sorted { lhs, rhs in
            let lLink = lhs.hasPrefix("169.254.")
            let rLink = rhs.hasPrefix("169.254.")
            if lLink != rLink { return !lLink }
            return lhs < rhs
        }.first
    }

    private func inferInterfaceType(_ name: String?) -> String? {
        guard let name else { return nil }
        if name.hasPrefix("en") { return "Ethernet/Wi-Fi" }
        if name.hasPrefix("pdp_ip") { return "Cellular" }
        if name.hasPrefix("utun") { return "VPN" }
        return "Other"
    }

}
