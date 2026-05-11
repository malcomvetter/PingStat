import Foundation

enum NetworkHealthState: String, Codable, CaseIterable {
    case offline
    case degraded
    case healthy
    case blazing

    var systemImageName: String {
        "cellularbars"
    }

    var title: String {
        rawValue.capitalized
    }
}

enum EndpointKind: String, Codable {
    case gateway
    /// IPv4 default-route path (tunnel / VPN); ICMP to tunnel next hop, DNS to VPN-scoped resolvers.
    case vpnTunnel
    case cloudflare
    case google
    case openDNS
    case level3
    case quad9
    case custom
}

struct PingTarget: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let label: String
    let host: String
    let kind: EndpointKind
}

struct PingSample: Codable, Equatable {
    let timestamp: Date
    let success: Bool
    let rttMs: Double?
    let timedOut: Bool
    let message: String
}

struct EndpointStatus: Identifiable, Codable, Equatable {
    let id: String
    let label: String
    let host: String
    let kind: EndpointKind
    var meanLast5Ms: Double?
    var last10: [PingSample]
    var latest: PingSample?
    /// When false, ICMP is not sent to this row (popover still shows the row, ping column de-emphasized).
    var icmpProbingActive: Bool
    /// When false, DNS probes are not run against this row’s resolver(s); DNS column de-emphasized.
    var dnsProbingActive: Bool

    var isOnline: Bool {
        latest?.success == true
    }

    /// No probes run for this row (custom targets only: hide navigation).
    var isFullyProbePaused: Bool {
        !icmpProbingActive && !dnsProbingActive
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case host
        case kind
        case meanLast5Ms
        case last10
        case latest
        case icmpProbingActive
        case dnsProbingActive
    }

    init(
        id: String,
        label: String,
        host: String,
        kind: EndpointKind,
        meanLast5Ms: Double?,
        last10: [PingSample],
        latest: PingSample?,
        icmpProbingActive: Bool = true,
        dnsProbingActive: Bool = true
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.kind = kind
        self.meanLast5Ms = meanLast5Ms
        self.last10 = last10
        self.latest = latest
        self.icmpProbingActive = icmpProbingActive
        self.dnsProbingActive = dnsProbingActive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        host = try c.decode(String.self, forKey: .host)
        kind = try c.decode(EndpointKind.self, forKey: .kind)
        meanLast5Ms = try c.decodeIfPresent(Double.self, forKey: .meanLast5Ms)
        last10 = try c.decodeIfPresent([PingSample].self, forKey: .last10) ?? []
        latest = try c.decodeIfPresent(PingSample.self, forKey: .latest)
        icmpProbingActive = try c.decodeIfPresent(Bool.self, forKey: .icmpProbingActive) ?? true
        dnsProbingActive = try c.decodeIfPresent(Bool.self, forKey: .dnsProbingActive) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(host, forKey: .host)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(meanLast5Ms, forKey: .meanLast5Ms)
        try c.encode(last10, forKey: .last10)
        try c.encodeIfPresent(latest, forKey: .latest)
        try c.encode(icmpProbingActive, forKey: .icmpProbingActive)
        try c.encode(dnsProbingActive, forKey: .dnsProbingActive)
    }
}

struct DNSCheckStatus: Codable, Equatable {
    var lastCheck: Date?
    var allConfiguredTimedOut: Bool = false
    /// When true, system resolver list was intentionally not probed (e.g. Low Data Mode); do not treat as “all timed out”.
    var systemResolverProbesSkipped: Bool = false
    var fallbackWorked: Bool = false
    var resolvedPrivateIP: Bool = false
    var configuredServers: [String] = []
    var fallbackServers: [String] = []
    var resolvedIPs: [String] = []
    var timedOutServers: [String] = []
    /// Per fallback nameserver (e.g. 1.1.1.1, 8.8.8.8, 208.67.220.220, 4.2.2.1, 9.9.9.9): UDP DNS probe succeeded.
    var fallbackAnsweredByServer: [String: Bool] = [:]
    /// Custom target IP(s) when DNS probes are enabled: same probe, keyed by nameserver address.
    var customNameserverProbes: [String: Bool] = [:]
    /// One line per resolver from the last probe round (query name + record types and RDATA).
    var lastResolverDetailLines: [String] = []

    enum CodingKeys: String, CodingKey {
        case lastCheck
        case allConfiguredTimedOut
        case systemResolverProbesSkipped
        case fallbackWorked
        case resolvedPrivateIP
        case configuredServers
        case fallbackServers
        case resolvedIPs
        case timedOutServers
        case fallbackAnsweredByServer
        case customNameserverProbes
        case lastResolverDetailLines
    }

    init(
        lastCheck: Date? = nil,
        allConfiguredTimedOut: Bool = false,
        systemResolverProbesSkipped: Bool = false,
        fallbackWorked: Bool = false,
        resolvedPrivateIP: Bool = false,
        configuredServers: [String] = [],
        fallbackServers: [String] = [],
        resolvedIPs: [String] = [],
        timedOutServers: [String] = [],
        fallbackAnsweredByServer: [String: Bool] = [:],
        customNameserverProbes: [String: Bool] = [:],
        lastResolverDetailLines: [String] = []
    ) {
        self.lastCheck = lastCheck
        self.allConfiguredTimedOut = allConfiguredTimedOut
        self.systemResolverProbesSkipped = systemResolverProbesSkipped
        self.fallbackWorked = fallbackWorked
        self.resolvedPrivateIP = resolvedPrivateIP
        self.configuredServers = configuredServers
        self.fallbackServers = fallbackServers
        self.resolvedIPs = resolvedIPs
        self.timedOutServers = timedOutServers
        self.fallbackAnsweredByServer = fallbackAnsweredByServer
        self.customNameserverProbes = customNameserverProbes
        self.lastResolverDetailLines = lastResolverDetailLines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
        allConfiguredTimedOut = try c.decodeIfPresent(Bool.self, forKey: .allConfiguredTimedOut) ?? false
        systemResolverProbesSkipped = try c.decodeIfPresent(Bool.self, forKey: .systemResolverProbesSkipped) ?? false
        fallbackWorked = try c.decodeIfPresent(Bool.self, forKey: .fallbackWorked) ?? false
        resolvedPrivateIP = try c.decodeIfPresent(Bool.self, forKey: .resolvedPrivateIP) ?? false
        configuredServers = try c.decodeIfPresent([String].self, forKey: .configuredServers) ?? []
        fallbackServers = try c.decodeIfPresent([String].self, forKey: .fallbackServers) ?? []
        resolvedIPs = try c.decodeIfPresent([String].self, forKey: .resolvedIPs) ?? []
        timedOutServers = try c.decodeIfPresent([String].self, forKey: .timedOutServers) ?? []
        fallbackAnsweredByServer = try c.decodeIfPresent([String: Bool].self, forKey: .fallbackAnsweredByServer) ?? [:]
        customNameserverProbes = try c.decodeIfPresent([String: Bool].self, forKey: .customNameserverProbes) ?? [:]
        lastResolverDetailLines = try c.decodeIfPresent([String].self, forKey: .lastResolverDetailLines) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(lastCheck, forKey: .lastCheck)
        try c.encode(allConfiguredTimedOut, forKey: .allConfiguredTimedOut)
        try c.encode(systemResolverProbesSkipped, forKey: .systemResolverProbesSkipped)
        try c.encode(fallbackWorked, forKey: .fallbackWorked)
        try c.encode(resolvedPrivateIP, forKey: .resolvedPrivateIP)
        try c.encode(configuredServers, forKey: .configuredServers)
        try c.encode(fallbackServers, forKey: .fallbackServers)
        try c.encode(resolvedIPs, forKey: .resolvedIPs)
        try c.encode(timedOutServers, forKey: .timedOutServers)
        try c.encode(fallbackAnsweredByServer, forKey: .fallbackAnsweredByServer)
        try c.encode(customNameserverProbes, forKey: .customNameserverProbes)
        try c.encode(lastResolverDetailLines, forKey: .lastResolverDetailLines)
    }
}

struct NetworkContext: Codable, Equatable {
    var connected: Bool
    var interfaceName: String?
    var interfaceType: String?
    var localIP: String?
    var gatewayIP: String?
    /// Resolvers for the **physical** primary interface (DHCP / manual on that link).
    var dnsServers: [String]
    /// True when the IPv4 default route uses a tunnel or differs from the primary link’s gateway.
    var vpnPathActive: Bool
    /// BSD interface name on the default IPv4 route (e.g. `utun3`).
    var vpnDefaultInterfaceName: String?
    /// Next-hop IPv4 on the default route through the tunnel, when known.
    var vpnTunnelGatewayIPv4: String?
    /// Resolvers from network services bound to ``vpnDefaultInterfaceName``.
    var dnsServersVPN: [String]
    /// VPN row title: **Network** service name for ``vpnDefaultInterfaceName`` (the route-carrying tunnel). Network Extension titles are used only when no BSD tunnel name is known—unscoped NE APIs can name a different active profile (e.g. SSL/TLS zero-trust) that does not own the default route.
    var vpnNetworkServiceName: String?

    static let empty = NetworkContext(
        connected: false,
        interfaceName: nil,
        interfaceType: nil,
        localIP: nil,
        gatewayIP: nil,
        dnsServers: [],
        vpnPathActive: false,
        vpnDefaultInterfaceName: nil,
        vpnTunnelGatewayIPv4: nil,
        dnsServersVPN: [],
        vpnNetworkServiceName: nil
    )

    enum CodingKeys: String, CodingKey {
        case connected
        case interfaceName
        case interfaceType
        case localIP
        case gatewayIP
        case dnsServers
        case vpnPathActive
        case vpnDefaultInterfaceName
        case vpnTunnelGatewayIPv4
        case dnsServersVPN
        case vpnNetworkServiceName
    }

    init(
        connected: Bool,
        interfaceName: String?,
        interfaceType: String?,
        localIP: String?,
        gatewayIP: String?,
        dnsServers: [String],
        vpnPathActive: Bool,
        vpnDefaultInterfaceName: String?,
        vpnTunnelGatewayIPv4: String?,
        dnsServersVPN: [String],
        vpnNetworkServiceName: String? = nil
    ) {
        self.connected = connected
        self.interfaceName = interfaceName
        self.interfaceType = interfaceType
        self.localIP = localIP
        self.gatewayIP = gatewayIP
        self.dnsServers = dnsServers
        self.vpnPathActive = vpnPathActive
        self.vpnDefaultInterfaceName = vpnDefaultInterfaceName
        self.vpnTunnelGatewayIPv4 = vpnTunnelGatewayIPv4
        self.dnsServersVPN = dnsServersVPN
        self.vpnNetworkServiceName = vpnNetworkServiceName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        interfaceName = try c.decodeIfPresent(String.self, forKey: .interfaceName)
        interfaceType = try c.decodeIfPresent(String.self, forKey: .interfaceType)
        localIP = try c.decodeIfPresent(String.self, forKey: .localIP)
        gatewayIP = try c.decodeIfPresent(String.self, forKey: .gatewayIP)
        dnsServers = try c.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
        vpnPathActive = try c.decodeIfPresent(Bool.self, forKey: .vpnPathActive) ?? false
        vpnDefaultInterfaceName = try c.decodeIfPresent(String.self, forKey: .vpnDefaultInterfaceName)
        vpnTunnelGatewayIPv4 = try c.decodeIfPresent(String.self, forKey: .vpnTunnelGatewayIPv4)
        dnsServersVPN = try c.decodeIfPresent([String].self, forKey: .dnsServersVPN) ?? []
        vpnNetworkServiceName = try c.decodeIfPresent(String.self, forKey: .vpnNetworkServiceName)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connected, forKey: .connected)
        try c.encodeIfPresent(interfaceName, forKey: .interfaceName)
        try c.encodeIfPresent(interfaceType, forKey: .interfaceType)
        try c.encodeIfPresent(localIP, forKey: .localIP)
        try c.encodeIfPresent(gatewayIP, forKey: .gatewayIP)
        try c.encode(dnsServers, forKey: .dnsServers)
        try c.encode(vpnPathActive, forKey: .vpnPathActive)
        try c.encodeIfPresent(vpnDefaultInterfaceName, forKey: .vpnDefaultInterfaceName)
        try c.encodeIfPresent(vpnTunnelGatewayIPv4, forKey: .vpnTunnelGatewayIPv4)
        try c.encode(dnsServersVPN, forKey: .dnsServersVPN)
        try c.encodeIfPresent(vpnNetworkServiceName, forKey: .vpnNetworkServiceName)
    }
}

struct HealthSnapshot: Codable, Equatable {
    var state: NetworkHealthState
    var reason: String
    var updatedAt: Date
}
