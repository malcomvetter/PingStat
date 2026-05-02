import Foundation

struct CustomPingTarget: Codable, Equatable {
    var label: String
    var ipAddress: String
    /// When true, run the same DNS probe used for WAN targets against `ipAddress` as nameserver.
    var dnsProbesEnabled: Bool

    init(label: String, ipAddress: String, dnsProbesEnabled: Bool = false) {
        self.label = label
        self.ipAddress = ipAddress
        self.dnsProbesEnabled = dnsProbesEnabled
    }

    enum CodingKeys: String, CodingKey {
        case label
        case ipAddress
        case dnsProbesEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        ipAddress = try c.decode(String.self, forKey: .ipAddress)
        dnsProbesEnabled = try c.decodeIfPresent(Bool.self, forKey: .dnsProbesEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(ipAddress, forKey: .ipAddress)
        try c.encode(dnsProbesEnabled, forKey: .dnsProbesEnabled)
    }
}

struct AppConfig: Codable, Equatable {
    /// Milliseconds between ping rounds (minimum enforced in UI).
    var pingIntervalMs: Double
    /// Milliseconds between DNS checks.
    var dnsIntervalMs: Double
    /// ICMP ping and DNS query timeout in milliseconds.
    var pingTimeoutMs: Double
    var degradedThresholdMs: Double
    var healthyThresholdMs: Double
    var blazingThresholdMs: Double
    var antiFlapEnterCount: Int
    var antiFlapRecoverCount: Int
    var minimumStateDwellSeconds: Double
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
    /// When true, include Level3 (4.2.2.1) in ICMP and summary UI.
    var pingLevel3Enabled: Bool
    /// When true, include Quad9 (9.9.9.9) in ICMP and summary UI.
    var pingQuad9Enabled: Bool
    var customTarget: CustomPingTarget?

    static let defaults = AppConfig(
        pingIntervalMs: 1_000,
        dnsIntervalMs: 30_000,
        pingTimeoutMs: 1_000,
        degradedThresholdMs: 150,
        healthyThresholdMs: 60,
        blazingThresholdMs: 30,
        antiFlapEnterCount: 2,
        antiFlapRecoverCount: 3,
        minimumStateDwellSeconds: 10,
        notificationCooldownSeconds: 60,
        showNotificationsEnabled: true,
        debugLoggingEnabled: false,
        launchAtLoginEnabled: false,
        pingCloudflareEnabled: true,
        pingGoogleEnabled: true,
        pingOpenDNSEnabled: true,
        pingLevel3Enabled: true,
        pingQuad9Enabled: true,
        customTarget: nil
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
        case antiFlapEnterCount
        case antiFlapRecoverCount
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
    }

    init(
        pingIntervalMs: Double,
        dnsIntervalMs: Double,
        pingTimeoutMs: Double,
        degradedThresholdMs: Double,
        healthyThresholdMs: Double,
        blazingThresholdMs: Double,
        antiFlapEnterCount: Int,
        antiFlapRecoverCount: Int,
        minimumStateDwellSeconds: Double,
        notificationCooldownSeconds: Double,
        showNotificationsEnabled: Bool,
        debugLoggingEnabled: Bool,
        launchAtLoginEnabled: Bool,
        pingCloudflareEnabled: Bool,
        pingGoogleEnabled: Bool,
        pingOpenDNSEnabled: Bool,
        pingLevel3Enabled: Bool,
        pingQuad9Enabled: Bool,
        customTarget: CustomPingTarget?
    ) {
        self.pingIntervalMs = pingIntervalMs
        self.dnsIntervalMs = dnsIntervalMs
        self.pingTimeoutMs = pingTimeoutMs
        self.degradedThresholdMs = degradedThresholdMs
        self.healthyThresholdMs = healthyThresholdMs
        self.blazingThresholdMs = blazingThresholdMs
        self.antiFlapEnterCount = antiFlapEnterCount
        self.antiFlapRecoverCount = antiFlapRecoverCount
        self.minimumStateDwellSeconds = minimumStateDwellSeconds
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
        antiFlapEnterCount = try c.decodeIfPresent(Int.self, forKey: .antiFlapEnterCount) ?? Self.defaults.antiFlapEnterCount
        antiFlapRecoverCount = try c.decodeIfPresent(Int.self, forKey: .antiFlapRecoverCount) ?? Self.defaults.antiFlapRecoverCount
        minimumStateDwellSeconds = try c.decodeIfPresent(Double.self, forKey: .minimumStateDwellSeconds) ?? Self.defaults.minimumStateDwellSeconds
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pingIntervalMs, forKey: .pingIntervalMs)
        try c.encode(dnsIntervalMs, forKey: .dnsIntervalMs)
        try c.encode(pingTimeoutMs, forKey: .pingTimeoutMs)
        try c.encode(degradedThresholdMs, forKey: .degradedThresholdMs)
        try c.encode(healthyThresholdMs, forKey: .healthyThresholdMs)
        try c.encode(blazingThresholdMs, forKey: .blazingThresholdMs)
        try c.encode(antiFlapEnterCount, forKey: .antiFlapEnterCount)
        try c.encode(antiFlapRecoverCount, forKey: .antiFlapRecoverCount)
        try c.encode(minimumStateDwellSeconds, forKey: .minimumStateDwellSeconds)
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
    }
}

extension AppConfig {
    var fallbackDNSServers: [String] {
        ["1.1.1.1", "8.8.8.8", "208.67.220.220", "4.2.2.1", "9.9.9.9"]
    }

    /// Seconds between ping rounds (for `Task.sleep`).
    func adjustedPingInterval(lowPowerMode: Bool) -> Double {
        let ms = lowPowerMode ? pingIntervalMs * 5 : pingIntervalMs
        return max(0.001, ms / 1000)
    }

    /// Seconds between DNS checks.
    func adjustedDNSInterval(lowPowerMode: Bool) -> Double {
        let ms = lowPowerMode ? dnsIntervalMs * 5 : dnsIntervalMs
        return max(0.001, ms / 1000)
    }

    /// Ping and DNS socket timeout in whole milliseconds (minimum 1).
    var servicePingTimeoutMs: Int {
        max(1, Int(pingTimeoutMs.rounded()))
    }
}
