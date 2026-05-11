import Foundation

struct CustomPingTarget: Codable, Equatable {
    var label: String
    var ipAddress: String
    /// When true, run the same DNS probe used for WAN targets against `ipAddress` as nameserver.
    var dnsProbesEnabled: Bool
    /// When Low Data Mode is active, allow ICMP/DNS probes to this target (if the master toggles allow).
    var useInLowDataMode: Bool

    init(label: String, ipAddress: String, dnsProbesEnabled: Bool = false, useInLowDataMode: Bool = false) {
        self.label = label
        self.ipAddress = ipAddress
        self.dnsProbesEnabled = dnsProbesEnabled
        self.useInLowDataMode = useInLowDataMode
    }

    enum CodingKeys: String, CodingKey {
        case label
        case ipAddress
        case dnsProbesEnabled
        case useInLowDataMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        ipAddress = try c.decode(String.self, forKey: .ipAddress)
        dnsProbesEnabled = try c.decodeIfPresent(Bool.self, forKey: .dnsProbesEnabled) ?? false
        useInLowDataMode = try c.decodeIfPresent(Bool.self, forKey: .useInLowDataMode) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(ipAddress, forKey: .ipAddress)
        try c.encode(dnsProbesEnabled, forKey: .dnsProbesEnabled)
        try c.encode(useInLowDataMode, forKey: .useInLowDataMode)
    }
}

struct AppConfig: Codable, Equatable {
    /// Milliseconds between ping rounds (minimum enforced in UI).
    var pingIntervalMs: Double
    /// Milliseconds between DNS checks.
    var dnsIntervalMs: Double
    /// ICMP ping and DNS query timeout in milliseconds.
    var pingTimeoutMs: Double
    /// Hostname used for UDP DNS probes (A record) against each resolver.
    var dnsProbeHostname: String
    var degradedThresholdMs: Double
    var healthyThresholdMs: Double
    var blazingThresholdMs: Double
    /// How many probe rounds in a row must agree before the menu bar health status changes (replaces separate downgrade/recover counts).
    var statusChangeConfirmationCount: Int
    /// Minimum time after a status change before another change can take effect (reduces rapid flip-flop).
    var minimumSecondsBetweenStatusChanges: Double
    var notificationCooldownSeconds: Double
    var showNotificationsEnabled: Bool
    var debugLoggingEnabled: Bool
    var launchAtLoginEnabled: Bool
    /// When true, include Cloudflare (1.1.1.1) in ICMP and summary UI.
    var pingCloudflareEnabled: Bool
    /// When true, include Google (8.8.8.8) in ICMP and summary UI.
    var pingGoogleEnabled: Bool
    /// When true, include OpenDNS / Cisco (208.67.220.220) in ICMP and summary UI.
    var pingOpenDNSEnabled: Bool
    /// When true, include CenturyLink / legacy Level3 resolver (4.2.2.1) in ICMP and summary UI.
    var pingLevel3Enabled: Bool
    /// When true, include Quad9 (9.9.9.9) in ICMP and summary UI.
    var pingQuad9Enabled: Bool
    var customTarget: CustomPingTarget?
    /// Per-WAN: allow probes while Low Data Mode is active (constrained / expensive path).
    var lowDataModeUseCloudflare: Bool
    var lowDataModeUseGoogle: Bool
    var lowDataModeUseOpenDNS: Bool
    var lowDataModeUseLevel3: Bool
    var lowDataModeUseQuad9: Bool
    /// Probe system-configured resolvers during Low Data Mode (gateway row DNS column only; ICMP to gateway stays off).
    var lowDataModeUseLocalNetworkDNS: Bool
    /// VPN tolerance addition (ms): added to displayed / threshold ICMP mean for the VPN path row (tunnel overhead).
    var vpnICMPOverheadPaddingMs: Double

    static let defaults = AppConfig(
        pingIntervalMs: 1_000,
        dnsIntervalMs: 30_000,
        pingTimeoutMs: 1_000,
        dnsProbeHostname: "captive.apple.com",
        degradedThresholdMs: 150,
        healthyThresholdMs: 60,
        blazingThresholdMs: 30,
        statusChangeConfirmationCount: 4,
        minimumSecondsBetweenStatusChanges: 10,
        notificationCooldownSeconds: 120,
        showNotificationsEnabled: true,
        debugLoggingEnabled: false,
        launchAtLoginEnabled: false,
        pingCloudflareEnabled: true,
        pingGoogleEnabled: true,
        pingOpenDNSEnabled: false,
        pingLevel3Enabled: false,
        pingQuad9Enabled: false,
        customTarget: nil,
        lowDataModeUseCloudflare: true,
        lowDataModeUseGoogle: false,
        lowDataModeUseOpenDNS: false,
        lowDataModeUseLevel3: false,
        lowDataModeUseQuad9: false,
        lowDataModeUseLocalNetworkDNS: false,
        vpnICMPOverheadPaddingMs: 15
    )

    enum CodingKeys: String, CodingKey {
        case pingIntervalMs
        case dnsIntervalMs
        case pingTimeoutMs
        case pingIntervalSeconds
        case dnsIntervalSeconds
        case pingTimeoutSeconds
        case degradedThresholdMs
        case healthyThresholdMs
        case blazingThresholdMs
        case blazingWanThresholdMs
        case blazingGatewayThresholdMs
        case statusChangeConfirmationCount
        case antiFlapEnterCount
        case antiFlapRecoverCount
        case minimumSecondsBetweenStatusChanges
        case minimumStateDwellSeconds
        case notificationCooldownSeconds
        case showNotificationsEnabled
        case debugLoggingEnabled
        case launchAtLoginEnabled
        case pingCloudflareEnabled
        case pingGoogleEnabled
        case pingOpenDNSEnabled
        case pingLevel3Enabled
        case pingQuad9Enabled
        case customTarget
        case dnsProbeHostname
        case lowDataModeUseCloudflare
        case lowDataModeUseGoogle
        case lowDataModeUseOpenDNS
        case lowDataModeUseLevel3
        case lowDataModeUseQuad9
        case lowDataModeUseLocalNetworkDNS
        case vpnICMPOverheadPaddingMs
    }

    init(
        pingIntervalMs: Double,
        dnsIntervalMs: Double,
        pingTimeoutMs: Double,
        dnsProbeHostname: String,
        degradedThresholdMs: Double,
        healthyThresholdMs: Double,
        blazingThresholdMs: Double,
        statusChangeConfirmationCount: Int,
        minimumSecondsBetweenStatusChanges: Double,
        notificationCooldownSeconds: Double,
        showNotificationsEnabled: Bool,
        debugLoggingEnabled: Bool,
        launchAtLoginEnabled: Bool,
        pingCloudflareEnabled: Bool,
        pingGoogleEnabled: Bool,
        pingOpenDNSEnabled: Bool,
        pingLevel3Enabled: Bool,
        pingQuad9Enabled: Bool,
        customTarget: CustomPingTarget?,
        lowDataModeUseCloudflare: Bool,
        lowDataModeUseGoogle: Bool,
        lowDataModeUseOpenDNS: Bool,
        lowDataModeUseLevel3: Bool,
        lowDataModeUseQuad9: Bool,
        lowDataModeUseLocalNetworkDNS: Bool,
        vpnICMPOverheadPaddingMs: Double
    ) {
        self.pingIntervalMs = pingIntervalMs
        self.dnsIntervalMs = dnsIntervalMs
        self.pingTimeoutMs = pingTimeoutMs
        self.dnsProbeHostname = dnsProbeHostname
        self.degradedThresholdMs = degradedThresholdMs
        self.healthyThresholdMs = healthyThresholdMs
        self.blazingThresholdMs = blazingThresholdMs
        self.statusChangeConfirmationCount = statusChangeConfirmationCount
        self.minimumSecondsBetweenStatusChanges = minimumSecondsBetweenStatusChanges
        self.notificationCooldownSeconds = notificationCooldownSeconds
        self.showNotificationsEnabled = showNotificationsEnabled
        self.debugLoggingEnabled = debugLoggingEnabled
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.pingCloudflareEnabled = pingCloudflareEnabled
        self.pingGoogleEnabled = pingGoogleEnabled
        self.pingOpenDNSEnabled = pingOpenDNSEnabled
        self.pingLevel3Enabled = pingLevel3Enabled
        self.pingQuad9Enabled = pingQuad9Enabled
        self.customTarget = customTarget
        self.lowDataModeUseCloudflare = lowDataModeUseCloudflare
        self.lowDataModeUseGoogle = lowDataModeUseGoogle
        self.lowDataModeUseOpenDNS = lowDataModeUseOpenDNS
        self.lowDataModeUseLevel3 = lowDataModeUseLevel3
        self.lowDataModeUseQuad9 = lowDataModeUseQuad9
        self.lowDataModeUseLocalNetworkDNS = lowDataModeUseLocalNetworkDNS
        self.vpnICMPOverheadPaddingMs = vpnICMPOverheadPaddingMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let ms = try c.decodeIfPresent(Double.self, forKey: .pingIntervalMs) {
            pingIntervalMs = max(1, ms)
        } else if let sec = try c.decodeIfPresent(Double.self, forKey: .pingIntervalSeconds) {
            pingIntervalMs = max(1, sec * 1000)
        } else {
            pingIntervalMs = Self.defaults.pingIntervalMs
        }

        if let ms = try c.decodeIfPresent(Double.self, forKey: .dnsIntervalMs) {
            dnsIntervalMs = max(1, ms)
        } else if let sec = try c.decodeIfPresent(Double.self, forKey: .dnsIntervalSeconds) {
            dnsIntervalMs = max(1, sec * 1000)
        } else {
            dnsIntervalMs = Self.defaults.dnsIntervalMs
        }

        if let ms = try c.decodeIfPresent(Double.self, forKey: .pingTimeoutMs) {
            pingTimeoutMs = max(1, ms)
        } else if let sec = try c.decodeIfPresent(Double.self, forKey: .pingTimeoutSeconds) {
            pingTimeoutMs = max(1, sec * 1000)
        } else {
            pingTimeoutMs = Self.defaults.pingTimeoutMs
        }

        if let raw = try c.decodeIfPresent(String.self, forKey: .dnsProbeHostname) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            dnsProbeHostname = trimmed.isEmpty ? Self.defaults.dnsProbeHostname : trimmed
        } else {
            dnsProbeHostname = Self.defaults.dnsProbeHostname
        }

        degradedThresholdMs = try c.decodeIfPresent(Double.self, forKey: .degradedThresholdMs) ?? Self.defaults.degradedThresholdMs
        healthyThresholdMs = try c.decodeIfPresent(Double.self, forKey: .healthyThresholdMs) ?? Self.defaults.healthyThresholdMs
        if let b = try c.decodeIfPresent(Double.self, forKey: .blazingThresholdMs) {
            blazingThresholdMs = b
        } else if let wan = try c.decodeIfPresent(Double.self, forKey: .blazingWanThresholdMs) {
            blazingThresholdMs = wan
        } else {
            blazingThresholdMs = Self.defaults.blazingThresholdMs
        }
        _ = try c.decodeIfPresent(Double.self, forKey: .blazingGatewayThresholdMs)
        if let v = try c.decodeIfPresent(Int.self, forKey: .statusChangeConfirmationCount) {
            statusChangeConfirmationCount = max(1, v)
        } else {
            let enter = try c.decodeIfPresent(Int.self, forKey: .antiFlapEnterCount) ?? Self.defaults.statusChangeConfirmationCount
            let recover = try c.decodeIfPresent(Int.self, forKey: .antiFlapRecoverCount) ?? Self.defaults.statusChangeConfirmationCount
            statusChangeConfirmationCount = max(1, max(enter, recover))
        }

        if let v = try c.decodeIfPresent(Double.self, forKey: .minimumSecondsBetweenStatusChanges) {
            minimumSecondsBetweenStatusChanges = max(0, v)
        } else {
            minimumSecondsBetweenStatusChanges = try c.decodeIfPresent(Double.self, forKey: .minimumStateDwellSeconds)
                ?? Self.defaults.minimumSecondsBetweenStatusChanges
        }
        notificationCooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .notificationCooldownSeconds) ?? Self.defaults.notificationCooldownSeconds
        showNotificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .showNotificationsEnabled) ?? Self.defaults.showNotificationsEnabled
        debugLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .debugLoggingEnabled) ?? Self.defaults.debugLoggingEnabled
        launchAtLoginEnabled = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? Self.defaults.launchAtLoginEnabled
        pingCloudflareEnabled = try c.decodeIfPresent(Bool.self, forKey: .pingCloudflareEnabled) ?? Self.defaults.pingCloudflareEnabled
        pingGoogleEnabled = try c.decodeIfPresent(Bool.self, forKey: .pingGoogleEnabled) ?? Self.defaults.pingGoogleEnabled
        pingOpenDNSEnabled = try c.decodeIfPresent(Bool.self, forKey: .pingOpenDNSEnabled) ?? Self.defaults.pingOpenDNSEnabled
        pingLevel3Enabled = try c.decodeIfPresent(Bool.self, forKey: .pingLevel3Enabled) ?? Self.defaults.pingLevel3Enabled
        pingQuad9Enabled = try c.decodeIfPresent(Bool.self, forKey: .pingQuad9Enabled) ?? Self.defaults.pingQuad9Enabled
        customTarget = try c.decodeIfPresent(CustomPingTarget.self, forKey: .customTarget)
        lowDataModeUseCloudflare = try c.decodeIfPresent(Bool.self, forKey: .lowDataModeUseCloudflare) ?? Self.defaults.lowDataModeUseCloudflare
        lowDataModeUseGoogle = try c.decodeIfPresent(Bool.self, forKey: .lowDataModeUseGoogle) ?? Self.defaults.lowDataModeUseGoogle
        lowDataModeUseOpenDNS = try c.decodeIfPresent(Bool.self, forKey: .lowDataModeUseOpenDNS) ?? Self.defaults.lowDataModeUseOpenDNS
        lowDataModeUseLevel3 = try c.decodeIfPresent(Bool.self, forKey: .lowDataModeUseLevel3) ?? Self.defaults.lowDataModeUseLevel3
        lowDataModeUseQuad9 = try c.decodeIfPresent(Bool.self, forKey: .lowDataModeUseQuad9) ?? Self.defaults.lowDataModeUseQuad9
        lowDataModeUseLocalNetworkDNS =
            try c.decodeIfPresent(Bool.self, forKey: .lowDataModeUseLocalNetworkDNS) ?? Self.defaults.lowDataModeUseLocalNetworkDNS
        vpnICMPOverheadPaddingMs =
            try c.decodeIfPresent(Double.self, forKey: .vpnICMPOverheadPaddingMs) ?? Self.defaults.vpnICMPOverheadPaddingMs
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pingIntervalMs, forKey: .pingIntervalMs)
        try c.encode(dnsIntervalMs, forKey: .dnsIntervalMs)
        try c.encode(pingTimeoutMs, forKey: .pingTimeoutMs)
        try c.encode(dnsProbeHostname, forKey: .dnsProbeHostname)
        try c.encode(degradedThresholdMs, forKey: .degradedThresholdMs)
        try c.encode(healthyThresholdMs, forKey: .healthyThresholdMs)
        try c.encode(blazingThresholdMs, forKey: .blazingThresholdMs)
        try c.encode(statusChangeConfirmationCount, forKey: .statusChangeConfirmationCount)
        try c.encode(minimumSecondsBetweenStatusChanges, forKey: .minimumSecondsBetweenStatusChanges)
        try c.encode(notificationCooldownSeconds, forKey: .notificationCooldownSeconds)
        try c.encode(showNotificationsEnabled, forKey: .showNotificationsEnabled)
        try c.encode(debugLoggingEnabled, forKey: .debugLoggingEnabled)
        try c.encode(launchAtLoginEnabled, forKey: .launchAtLoginEnabled)
        try c.encode(pingCloudflareEnabled, forKey: .pingCloudflareEnabled)
        try c.encode(pingGoogleEnabled, forKey: .pingGoogleEnabled)
        try c.encode(pingOpenDNSEnabled, forKey: .pingOpenDNSEnabled)
        try c.encode(pingLevel3Enabled, forKey: .pingLevel3Enabled)
        try c.encode(pingQuad9Enabled, forKey: .pingQuad9Enabled)
        try c.encodeIfPresent(customTarget, forKey: .customTarget)
        try c.encode(lowDataModeUseCloudflare, forKey: .lowDataModeUseCloudflare)
        try c.encode(lowDataModeUseGoogle, forKey: .lowDataModeUseGoogle)
        try c.encode(lowDataModeUseOpenDNS, forKey: .lowDataModeUseOpenDNS)
        try c.encode(lowDataModeUseLevel3, forKey: .lowDataModeUseLevel3)
        try c.encode(lowDataModeUseQuad9, forKey: .lowDataModeUseQuad9)
        try c.encode(lowDataModeUseLocalNetworkDNS, forKey: .lowDataModeUseLocalNetworkDNS)
        try c.encode(vpnICMPOverheadPaddingMs, forKey: .vpnICMPOverheadPaddingMs)
    }
}

extension AppConfig {
    /// Trims whitespace; falls back to default if empty or unreasonably long.
    var sanitizedDNSProbeHostname: String {
        let t = dnsProbeHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 253 else { return Self.defaults.dnsProbeHostname }
        return t
    }

    /// Enabled public resolver rows (ICMP + DNS use the same set).
    var enabledWanResolverTargets: [(kind: EndpointKind, host: String)] {
        var rows: [(EndpointKind, String)] = []
        if pingCloudflareEnabled { rows.append((.cloudflare, "1.1.1.1")) }
        if pingGoogleEnabled { rows.append((.google, "8.8.8.8")) }
        if pingOpenDNSEnabled { rows.append((.openDNS, "208.67.220.220")) }
        if pingLevel3Enabled { rows.append((.level3, "4.2.2.1")) }
        if pingQuad9Enabled { rows.append((.quad9, "9.9.9.9")) }
        return rows
    }

    /// Public DNS IPs used as UDP probe fallbacks (same order as enabled WAN ICMP targets).
    var fallbackDNSServers: [String] {
        enabledWanResolverTargets.map(\.host)
    }

    func lowDataModeUse(for kind: EndpointKind) -> Bool {
        switch kind {
        case .cloudflare: return lowDataModeUseCloudflare
        case .google: return lowDataModeUseGoogle
        case .openDNS: return lowDataModeUseOpenDNS
        case .level3: return lowDataModeUseLevel3
        case .quad9: return lowDataModeUseQuad9
        case .gateway, .vpnTunnel, .custom:
            return false
        }
    }

    /// Fallback nameservers to probe: only WAN targets that stay eligible under Low Data Mode when it is active.
    func fallbackDNSServersForProbes(lowDataModePathActive: Bool) -> [String] {
        guard lowDataModePathActive else { return fallbackDNSServers }
        return enabledWanResolverTargets.compactMap { pair in
            lowDataModeUse(for: pair.kind) ? pair.host : nil
        }
    }

    /// Seconds between ping rounds (for `Task.sleep`). Low Power and Low Data Mode each multiply the base interval by 5.
    func adjustedPingInterval(lowPowerMode: Bool, lowDataMode: Bool) -> Double {
        var ms = pingIntervalMs
        if lowPowerMode { ms *= 5 }
        if lowDataMode { ms *= 5 }
        return max(0.001, ms / 1000)
    }

    /// Seconds between DNS checks.
    func adjustedDNSInterval(lowPowerMode: Bool, lowDataMode: Bool) -> Double {
        var ms = dnsIntervalMs
        if lowPowerMode { ms *= 5 }
        if lowDataMode { ms *= 5 }
        return max(0.001, ms / 1000)
    }

    /// Ping and DNS socket timeout in whole milliseconds (minimum 1).
    var servicePingTimeoutMs: Int {
        max(1, Int(pingTimeoutMs.rounded()))
    }
}
