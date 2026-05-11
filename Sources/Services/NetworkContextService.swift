import Darwin
import Foundation
import Network

@MainActor
final class NetworkContextService: ObservableObject {
    @Published private(set) var context: NetworkContext = .empty

    private var monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "org.malcomvetter.PingStat.path")
    /// ``NWPathMonitor`` does not always fire when only the IPv4 routing table or VPN tunnel changes; poll lightly to pick up VPN connect/disconnect after launch.
    private var routePollTimer: Timer?
    private let logger: LoggingService
    private let debugEnabledProvider: () -> Bool

    private static let vpnRoutePollIntervalSeconds: TimeInterval = 5

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
        startRoutePollTimer()
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
        startRoutePollTimer()
        Task { @MainActor in
            await refreshContext(pathStatus: next.currentPath.status, path: next.currentPath)
        }
    }

    func stop() {
        stopRoutePollTimer()
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    deinit {
        routePollTimer?.invalidate()
        monitor.cancel()
    }

    private func startRoutePollTimer() {
        stopRoutePollTimer()
        let interval = Self.vpnRoutePollIntervalSeconds
        routePollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshContext()
            }
        }
        if let routePollTimer {
            RunLoop.main.add(routePollTimer, forMode: .common)
        }
    }

    private func stopRoutePollTimer() {
        routePollTimer?.invalidate()
        routePollTimer = nil
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
        let dnsServersPhysical = dnsServersForPhysicalInterface(bsdName: interfaceName)

        let defRoute = NativeNetworkConfiguration.ipv4DefaultRouteInterfaceAndGateway()
        let defRouteGw = defRoute.gatewayIPv4
            ?? defRoute.interfaceName.flatMap { NativeNetworkConfiguration.primaryIPv4Address(onBSDInterface: $0) }
        var vpnEval = VPNPathEvaluator.evaluate(
            primaryInterface: interfaceName,
            primaryRouterIPv4: gateway,
            defaultRouteInterface: defRoute.interfaceName,
            defaultRouteGatewayIPv4: defRouteGw
        )

        if !vpnEval.active, connected,
           let prim = interfaceName?.trimmingCharacters(in: .whitespacesAndNewlines), !prim.isEmpty,
           !NativeNetworkConfiguration.isLikelyVpnTunnelInterfaceName(prim),
           let tunnel = nwTunnelInterfaceFallback(primaryBSDInterface: prim, path: path) {
            let tunnelGw = NativeNetworkConfiguration.primaryIPv4Address(onBSDInterface: tunnel)
            vpnEval = VPNPathEvaluator.Result(
                active: true,
                vpnInterfaceName: tunnel,
                tunnelGatewayIPv4: tunnelGw
            )
        }
        let dnsVPN: [String] = {
            guard vpnEval.active, let vi = vpnEval.vpnInterfaceName, !vi.isEmpty else { return [] }
            let per = SystemDNSConfiguration.nameserversForBSDInterface(vi)
            if !per.isEmpty { return per }
            return []
        }()

        let vpnTunnelGwStored: String? = {
            guard let raw = vpnEval.tunnelGatewayIPv4?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                guard let vi = vpnEval.vpnInterfaceName, !vi.isEmpty else { return nil }
                return NativeNetworkConfiguration.primaryIPv4Address(onBSDInterface: vi)
            }
            return raw
        }()

        // Name must follow the **route-detected** tunnel (`vpnInterfaceName`). Unscoped Network Extension
        // APIs (e.g. `NEVPNManager.shared`) can report a different “VPN” (SSL/TLS zero-trust) that does not
        // carry the default route, so we only use those when we have no BSD tunnel name from routing.
        let vpnNetworkServiceName: String?
        if vpnEval.active,
           let vi = vpnEval.vpnInterfaceName?.trimmingCharacters(in: .whitespacesAndNewlines), !vi.isEmpty {
            let sc = (NativeNetworkConfiguration.networkServiceDisplayName(forBSDInterface: vi) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            vpnNetworkServiceName = sc.isEmpty ? nil : sc
        } else if vpnEval.active {
            let ne = await VpnNetworkExtensionDisplayName.preferredActiveTitle()
            let nt = (ne ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            vpnNetworkServiceName = nt.isEmpty ? nil : nt
        } else {
            vpnNetworkServiceName = nil
        }

        let next = NetworkContext(
            connected: connected,
            interfaceName: interfaceName,
            interfaceType: interfaceType,
            localIP: localIP,
            gatewayIP: gateway,
            dnsServers: dnsServersPhysical,
            vpnPathActive: vpnEval.active,
            vpnDefaultInterfaceName: vpnEval.vpnInterfaceName,
            vpnTunnelGatewayIPv4: vpnTunnelGwStored,
            dnsServersVPN: dnsVPN,
            vpnNetworkServiceName: vpnNetworkServiceName
        )
        if next != context {
            context = next
            logger.debug(
                .networkContext,
                "Context refreshed connected=\(connected) interface=\(interfaceName ?? "-") ip=\(localIP ?? "-") gateway=\(gateway ?? "-") dns=\(dnsServersPhysical.joined(separator: ",")) vpn=\(vpnEval.active) vpnIf=\(vpnEval.vpnInterfaceName ?? "-") vpnGw=\(vpnTunnelGwStored ?? "-") vpnDns=\(dnsVPN.joined(separator: ",")) vpnName=\(vpnNetworkServiceName ?? "-")",
                enabled: debugEnabledProvider()
            )
        }
    }

    private func sysctlDefaultRouteInterfaceName() -> String? {
        NativeNetworkConfiguration.defaultRouteInterfaceNameFromSysctl()
    }

    /// When sysctl route rows omit ``RTAX_IFP`` (common on macOS), ``NWPath`` can still list a ``utun`` with an IPv4.
    /// Prefer a tunnel that also has a wide-Internet route in the IPv4 table; otherwise use any distinct tunnel with an address (WireGuard / NEVPN).
    private func nwTunnelInterfaceFallback(primaryBSDInterface: String, path: NWPath) -> String? {
        let sorted = path.availableInterfaces
            .map(\.name)
            .filter { NativeNetworkConfiguration.isLikelyVpnTunnelInterfaceName($0) }
            .sorted()
        for n in sorted where n != primaryBSDInterface {
            guard NativeNetworkConfiguration.primaryIPv4Address(onBSDInterface: n) != nil else { continue }
            if NativeNetworkConfiguration.hasWideInternetIPv4Route(onBSDInterface: n) {
                return n
            }
        }
        for n in sorted where n != primaryBSDInterface {
            if NativeNetworkConfiguration.primaryIPv4Address(onBSDInterface: n) != nil {
                return n
            }
        }
        return nil
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

    /// DNS for the **physical** primary interface: per-service `State:/Network/Service/*/DNS` matching that
    /// interface, then the same manual fallback as ``resolveDNSServers``.
    private func dnsServersForPhysicalInterface(bsdName: String?) -> [String] {
        guard let bsd = bsdName, !bsd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return resolveDNSServers(interfaceBSDName: nil)
        }
        let per = SystemDNSConfiguration.nameserversForBSDInterface(bsd)
        if !per.isEmpty { return per }
        return resolveDNSServers(interfaceBSDName: bsd)
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
        return NativeNetworkConfiguration.primaryIPv4Address(onBSDInterface: interface)
    }

    private func inferInterfaceType(_ name: String?) -> String? {
        guard let name else { return nil }
        if name.hasPrefix("en") { return "Ethernet/Wi-Fi" }
        if name.hasPrefix("pdp_ip") { return "Cellular" }
        if name.hasPrefix("utun") { return "VPN" }
        return "Other"
    }
}
