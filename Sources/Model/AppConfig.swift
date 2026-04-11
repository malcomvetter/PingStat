import Foundation

struct CustomPingTarget: Codable, Equatable {
    var label: String
    var ipAddress: String
}

struct AppConfig: Codable, Equatable {
    var pingIntervalSeconds: Double
    var dnsIntervalSeconds: Double
    var pingTimeoutMs: Int
    var degradedThresholdMs: Double
    var healthyThresholdMs: Double
    var blazingGatewayThresholdMs: Double
    var blazingWanThresholdMs: Double
    var antiFlapEnterCount: Int
    var antiFlapRecoverCount: Int
    var minimumStateDwellSeconds: Double
    var notificationCooldownSeconds: Double
    var debugLoggingEnabled: Bool
    var launchAtLoginEnabled: Bool
    var customTarget: CustomPingTarget?

    static let `default` = AppConfig(
        pingIntervalSeconds: 1,
        dnsIntervalSeconds: 15,
        pingTimeoutMs: 1_000,
        degradedThresholdMs: 150,
        healthyThresholdMs: 60,
        blazingGatewayThresholdMs: 8,
        blazingWanThresholdMs: 30,
        antiFlapEnterCount: 2,
        antiFlapRecoverCount: 3,
        minimumStateDwellSeconds: 10,
        notificationCooldownSeconds: 60,
        debugLoggingEnabled: false,
        launchAtLoginEnabled: false,
        customTarget: nil
    )
}

extension AppConfig {
    var fallbackDNSServers: [String] {
        ["1.1.1.1", "8.8.8.8"]
    }

    func adjustedPingInterval(lowPowerMode: Bool) -> Double {
        lowPowerMode ? pingIntervalSeconds * 5 : pingIntervalSeconds
    }

    func adjustedDNSInterval(lowPowerMode: Bool) -> Double {
        lowPowerMode ? dnsIntervalSeconds * 5 : dnsIntervalSeconds
    }
}
