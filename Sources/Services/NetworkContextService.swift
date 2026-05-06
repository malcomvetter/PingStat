import Darwin
import Foundation
import Network

@MainActor
final class NetworkContextService: ObservableObject {
    @Published private(set) var context: NetworkContext = .empty

    private var monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "org.malcomvetter.PingStat.path")
    private let logger: LoggingService
    private let debugEnabledProvider: () -> Bool

    init(
        logger: LoggingService,
        debugEnabledProvider: @escaping () -> Bool
    ) {
        self.logger = logger
        self.debugEnabledProvider = debugEnabledProvider
    }

    func start() {
        attachPathHandler(to: monitor)
        monitor.start(queue: monitorQueue)
        Task { @MainActor in
            await refreshContext(pathStatus: monitor.currentPath.status, path: monitor.currentPath)
        }
    }

    /// After full system sleep, ``NWPathMonitor`` may stop delivering path updates until replaced.
    func restartPathMonitoring() {
        logger.log(.notice, category: .networkContext, "event=path_monitor_restart reason=wake_or_recovery")
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        let next = NWPathMonitor()
        monitor = next
        attachPathHandler(to: next)
        next.start(queue: monitorQueue)
        Task { @MainActor in
            await refreshContext(pathStatus: next.currentPath.status, path: next.currentPath)
        }
    }

    func stop() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    deinit {
        monitor.cancel()
    }

    private func attachPathHandler(to pathMonitor: NWPathMonitor) {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshContext(pathStatus: path.status, path: path)
            }
        }
    }

    func refreshContext(pathStatus: NWPath.Status? = nil, path activePath: NWPath? = nil) async {
        let path = activePath ?? monitor.currentPath
        let connected = (pathStatus ?? path.status) == .satisfied

        let global = NativeNetworkConfiguration.globalIPv4FromStore()
        var interfaceName = global.interface?.trimmingCharacters(in: .whitespacesAndNewlines)
        var gateway = Self.normalizedIPv4Gateway(global.router)

        if interfaceName == nil {
            interfaceName = sysctlDefaultRouteInterfaceName()
        }

        var interfaceType = inferInterfaceType(interfaceName)

        if let nw = matchingNWInterface(name: interfaceName, path: path) {
            interfaceType = describeNWInterfaceType(nw.type)
        } else if interfaceName == nil, let primary = pickPrimaryInterface(from: path) {
            interfaceName = primary.name
            interfaceType = describeNWInterfaceType(primary.type)
        }

        if let ifn = interfaceName {
            if gateway == nil {
                gateway = Self.normalizedIPv4Gateway(NativeNetworkConfiguration.routerFromServiceIPv4(bsdInterface: ifn))
            }
            if gateway == nil {
                let sysctl = NativeNetworkConfiguration.defaultIPv4GatewaysViaSysctl(preferredInterface: ifn)
                gateway = Self.normalizedIPv4Gateway(sysctl.preferred) ?? Self.normalizedIPv4Gateway(sysctl.any)
            }
        }

        let localIP = localIPForInterface(interfaceName)
        let dnsServers = resolveDNSServers(interfaceBSDName: interfaceName)

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

    private func sysctlDefaultRouteInterfaceName() -> String? {
        NativeNetworkConfiguration.defaultRouteInterfaceNameFromSysctl()
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

    private static func normalizedIPv4Gateway(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("link#") { return nil }
        let pattern = #"^(\d{1,3}\.){3}\d{1,3}$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    /// Resolver IPs from **SystemConfiguration** (`SCDynamicStore`, same source as `scutil --dns`), then
    /// manual DNS from the active **network set** (parity with `networksetup -getdnsservers`) when only
    /// loopback appears in the dynamic store.
    private func resolveDNSServers(interfaceBSDName: String?) -> [String] {
        let raw = SystemDNSConfiguration.orderedNameserverAddresses(interfaceHint: interfaceBSDName)
        let nonLoopback = raw.filter { !["127.0.0.1", "0.0.0.0", "::1"].contains($0) }
        if !nonLoopback.isEmpty {
            return nonLoopback
        }
        guard let bsd = interfaceBSDName else {
            return raw
        }
        guard let fromPrefs = NativeNetworkConfiguration.manualDNSServersFromPreferences(bsdInterface: bsd) else {
            return raw
        }
        if !fromPrefs.isEmpty {
            return fromPrefs.map { Self.attachInterfaceZoneToLinkLocalIPv6($0, interfaceBSDName: bsd) }
        }
        return []
    }

    /// Parses **scutil --dns**-style text for tests (resolver blocks + `if_index`). Production uses ``SystemDNSConfiguration``.
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
        return withUnsafeBytes(of: &addr) { raw in
            let p = raw.bindMemory(to: UInt8.self)
            guard p.count >= 2 else { return false }
            return p[0] == 0xfe && (p[1] & 0xc0) == 0x80
        }
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

    private func localIPForInterface(_ interface: String?) -> String? {
        guard let interface else { return nil }
        return Self.ipv4FromGetifaddrs(interfaceName: interface)
    }

    /// Enumerates kernel interface addresses (parity with `ipconfig getifaddr` plus relay / privacy cases).
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
