import Foundation

/// When to run ICMP / DNS probes vs `NWPath.Status` satisfaction (`NetworkContext.connected`).
enum ConnectivityProbePolicy {
    /// ICMP to gateway, WAN targets, and custom IPs should only run when the OS reports a satisfiable path.
    static func shouldRunICMPProbes(pathSatisfied: Bool) -> Bool {
        pathSatisfied
    }

    /// DNS checks (including UDP fallbacks to 1.1.1.1 / 8.8.8.8) require external connectivity.
    static func shouldRunDNSProbes(pathSatisfied: Bool) -> Bool {
        pathSatisfied
    }
}

/// Clears probe history so the UI does not show stale WAN/DNS results after connectivity drops.
enum OfflineProbeDisplayPolicy {
    static func probeHistoryClearedEndpoints(_ endpoints: [EndpointStatus]) -> [EndpointStatus] {
        endpoints.map { ep in
            var e = ep
            e.last10 = []
            e.latest = nil
            e.meanLast5Ms = nil
            return e
        }
    }
}
