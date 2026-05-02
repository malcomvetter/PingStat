import Foundation

struct HealthEvaluationInput {
    let context: NetworkContext
    let endpointStatuses: [EndpointKind: EndpointStatus]
    let dnsStatus: DNSCheckStatus
    let config: AppConfig
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
        let canTransitionByDwell = now.timeIntervalSince(lastTransitionAt) >= input.config.minimumStateDwellSeconds
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
        return toRank < fromRank ? max(1, config.antiFlapEnterCount) : max(1, config.antiFlapRecoverCount)
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
            return (.offline, "No local connectivity")
        }

        if input.dnsStatus.allConfiguredTimedOut && !input.dnsStatus.fallbackWorked {
            return (.offline, "DNS timed out on all servers")
        }

        if allMonitoredPingsTimedOut(endpointStatuses: input.endpointStatuses) {
            return (.offline, "All monitored endpoints timed out")
        }

        if input.dnsStatus.resolvedPrivateIP {
            return (.degraded, "captive.apple.com resolved to private IP")
        }

        if input.dnsStatus.allConfiguredTimedOut && input.dnsStatus.fallbackWorked {
            return (.degraded, "Primary DNS filtered; public DNS resolvers still work")
        }

        let wanMeansMs = Self.monitoredPublicResolverMeanMs(from: input)
        if wanMeansMs.contains(where: { $0 > input.config.degradedThresholdMs }) {
            return (.degraded, "WAN mean latency above \(Int(input.config.degradedThresholdMs))ms")
        }

        if Self.isBlazing(wanMeansMs: wanMeansMs, config: input.config) {
            return (.blazing, "WAN latency is excellent")
        }

        if Self.isHealthy(wanMeansMs: wanMeansMs, config: input.config) {
            return (.healthy, "WAN means are <= \(Int(input.config.healthyThresholdMs))ms")
        }

        return (.healthy, "Connected with moderate latency")
    }

    private func allMonitoredPingsTimedOut(endpointStatuses: [EndpointKind: EndpointStatus]) -> Bool {
        let monitors = Array(endpointStatuses.values)
        guard !monitors.isEmpty else { return false }
        guard monitors.allSatisfy({ $0.latest != nil }) else { return false }
        return monitors.allSatisfy { status in
            guard let latest = status.latest else { return false }
            return latest.timedOut || !latest.success
        }
    }

    /// ICMP mean(5) for each enabled public resolver row (fixed WAN list), omitting unknowns.
    private static func monitoredPublicResolverMeanMs(from input: HealthEvaluationInput) -> [Double] {
        let kinds: [EndpointKind] = [.cloudflare, .google, .openDNS, .level3, .quad9]
        return kinds.compactMap { input.endpointStatuses[$0]?.meanLast5Ms }
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
