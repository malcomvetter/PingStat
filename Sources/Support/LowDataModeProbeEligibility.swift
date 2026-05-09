import Foundation

/// Pure rules for which probes run while **Low Data Mode** is active (`NWPath` satisfied and constrained or expensive).
/// `NetworkMonitorViewModel` uses this when building endpoints so ping/DNS loops only hit allowed targets.
enum LowDataModeProbeEligibility {
    /// Gateway ICMP is never sent in Low Data Mode.
    static func gatewayICMPProbingActive(lowDataModePathActive: Bool) -> Bool {
        !lowDataModePathActive
    }

    static func gatewayDNSProbingActive(lowDataModePathActive: Bool, config: AppConfig) -> Bool {
        !lowDataModePathActive || config.lowDataModeUseLocalNetworkDNS
    }

    /// WAN rows: ICMP and DNS share the same eligibility when the resolver is master-enabled.
    static func wanProbingEligible(lowDataModePathActive: Bool, config: AppConfig, kind: EndpointKind) -> Bool {
        !lowDataModePathActive || config.lowDataModeUse(for: kind)
    }

    static func customICMPProbingActive(lowDataModePathActive: Bool, target: CustomPingTarget) -> Bool {
        !lowDataModePathActive || target.useInLowDataMode
    }

    static func customDNSProbingActive(lowDataModePathActive: Bool, target: CustomPingTarget) -> Bool {
        target.dnsProbesEnabled && (!lowDataModePathActive || target.useInLowDataMode)
    }
}
