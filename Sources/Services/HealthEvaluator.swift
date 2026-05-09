import Foundation

struct HealthEvaluationInput {
    let context: NetworkContext
    let endpointStatuses: [EndpointKind: EndpointStatus]
    let dnsStatus: DNSCheckStatus
    let config: AppConfig
    let lowDataModePathActive: Bool
}

@MainActor
final class HealthEvaluator {
    private(set) var snapshot = HealthSnapshot(
        state: .offline,
        reason: "Starting up",
        updatedAt: Date()
    )

    private var pendingState: NetworkHealthState?
    private var pendingReason: String = ""
    private var pendingCount: Int = 0
    private var lastTransitionAt = Date.distantPast

    func evaluate(_ input: HealthEvaluationInput) -> HealthSnapshot {
        let candidate = candidateState(for: input)
        guard candidate.state != snapshot.state else {
            pendingState = nil
            pendingCount = 0
            snapshot = HealthSnapshot(
                state: snapshot.state,
                reason: candidate.reason,
                updatedAt: Date()
            )
            return snapshot
        }

        if pendingState == candidate.state {
            pendingCount += 1
            pendingReason = candidate.reason
        } else {
            pendingState = candidate.state
            pendingReason = candidate.reason
            pendingCount = 1
        }

        let now = Date()
        let canTransitionByDwell = now.timeIntervalSince(lastTransitionAt) >= input.config.minimumSecondsBetweenStatusChanges
        let requiredCount = transitionCount(
            from: snapshot.state,
            to: candidate.state,
            config: input.config
        )

        if canTransitionByDwell, pendingCount >= requiredCount {
            snapshot = HealthSnapshot(
                state: candidate.state,
                reason: candidate.reason,
                updatedAt: now
            )
            lastTransitionAt = now
            pendingState = nil
            pendingCount = 0
        }

        return snapshot
    }

    private func transitionCount(from: NetworkHealthState, to: NetworkHealthState, config: AppConfig) -> Int {
        let fromRank = rank(for: from)
        let toRank = rank(for: to)
        return max(1, config.statusChangeConfirmationCount)
    }

    private func rank(for state: NetworkHealthState) -> Int {
        switch state {
        case .offline:
            return 0
        case .degraded:
            return 1
        case .healthy:
            return 2
        case .blazing:
            return 3
        }
    }

    private func candidateState(for input: HealthEvaluationInput) -> (state: NetworkHealthState, reason: String) {
        if !input.context.connected {
            return suffixLDM((.offline, "No local connectivity"), input: input)
        }

        if input.dnsStatus.allConfiguredTimedOut,
           !input.dnsStatus.fallbackWorked,
           !input.dnsStatus.systemResolverProbesSkipped {
            return suffixLDM((.offline, "DNS timed out on all servers"), input: input)
        }

        if allMonitoredPingsTimedOut(endpointStatuses: input.endpointStatuses) {
            return suffixLDM((.offline, "All monitored endpoints timed out"), input: input)
        }

        if input.dnsStatus.resolvedPrivateIP {
            return suffixLDM((.degraded, "captive.apple.com resolved to private IP"), input: input)
        }

        if input.dnsStatus.allConfiguredTimedOut,
           input.dnsStatus.fallbackWorked,
           !input.dnsStatus.systemResolverProbesSkipped {
            return suffixLDM((.degraded, "Primary DNS filtered; public DNS resolvers still work"), input: input)
        }

        let wanMeansMs = Self.monitoredPublicResolverMeanMs(from: input)
        if wanMeansMs.contains(where: { $0 > input.config.degradedThresholdMs }) {
            return suffixLDM((.degraded, "WAN mean latency above \(Int(input.config.degradedThresholdMs))ms"), input: input)
        }

        if Self.isBlazing(wanMeansMs: wanMeansMs, config: input.config) {
            return suffixLDM((.blazing, "WAN latency is excellent"), input: input)
        }

        if Self.isHealthy(wanMeansMs: wanMeansMs, config: input.config) {
            return suffixLDM((.healthy, "WAN means are <= \(Int(input.config.healthyThresholdMs))ms"), input: input)
        }

        return suffixLDM((.healthy, "Connected with moderate latency"), input: input)
    }

    private func suffixLDM(_ pair: (state: NetworkHealthState, reason: String), input: HealthEvaluationInput)
        -> (state: NetworkHealthState, reason: String) {
        guard input.lowDataModePathActive else { return pair }
        return (pair.state, pair.reason + " – Low Data Mode")
    }

    private func allMonitoredPingsTimedOut(endpointStatuses: [EndpointKind: EndpointStatus]) -> Bool {
        let monitors = Array(endpointStatuses.values).filter(\.icmpProbingActive)
        guard !monitors.isEmpty else { return false }
        guard monitors.allSatisfy({ $0.latest != nil }) else { return false }
        return monitors.allSatisfy { status in
            guard let latest = status.latest else { return false }
            return latest.timedOut || !latest.success
        }
    }

    /// ICMP mean(5) for each enabled public resolver row that is actively ICMP-probed, omitting unknowns.
    private static func monitoredPublicResolverMeanMs(from input: HealthEvaluationInput) -> [Double] {
        let kinds: [EndpointKind] = [.cloudflare, .google, .openDNS, .level3, .quad9]
        return kinds.compactMap { kind in
            guard let ep = input.endpointStatuses[kind], ep.icmpProbingActive else { return nil }
            return ep.meanLast5Ms
        }
    }

    private static func isHealthy(wanMeansMs: [Double], config: AppConfig) -> Bool {
        guard !wanMeansMs.isEmpty else { return false }
        return wanMeansMs.allSatisfy { $0 <= config.healthyThresholdMs }
    }

    private static func isBlazing(wanMeansMs: [Double], config: AppConfig) -> Bool {
        guard !wanMeansMs.isEmpty else { return false }
        return wanMeansMs.allSatisfy { $0 < config.blazingThresholdMs }
    }
}
