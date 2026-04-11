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

        let gateway = input.endpointStatuses[.gateway]
        let cloudflare = input.endpointStatuses[.cloudflare]
        let google = input.endpointStatuses[.google]

        if input.dnsStatus.allConfiguredTimedOut && !input.dnsStatus.fallbackWorked {
            return (.offline, "DNS timed out on all servers")
        }

        if allCorePingsTimedOut(gateway: gateway, cloudflare: cloudflare, google: google) {
            return (.offline, "Gateway, Cloudflare, and Google timed out")
        }

        if input.dnsStatus.resolvedPrivateIP {
            return (.degraded, "captive.apple.com resolved to private IP")
        }

        if input.dnsStatus.allConfiguredTimedOut && input.dnsStatus.fallbackWorked {
            return (.degraded, "Primary DNS filtered; Cloudflare/Google DNS works")
        }

        let cloudflareMean = cloudflare?.meanLast5Ms
        let googleMean = google?.meanLast5Ms
        if exceedsDegraded(meanMs: cloudflareMean, thresholdMs: input.config.degradedThresholdMs) ||
            exceedsDegraded(meanMs: googleMean, thresholdMs: input.config.degradedThresholdMs) {
            return (.degraded, "Cloudflare or Google mean latency above \(Int(input.config.degradedThresholdMs))ms")
        }

        if isBlazing(gatewayMean: gateway?.meanLast5Ms, cloudflareMean: cloudflareMean, googleMean: googleMean, config: input.config) {
            return (.blazing, "Gateway and WAN latency are excellent")
        }

        if isHealthy(cloudflareMean: cloudflareMean, googleMean: googleMean, config: input.config) {
            return (.healthy, "Cloudflare and Google means are <= \(Int(input.config.healthyThresholdMs))ms")
        }

        return (.healthy, "Connected with moderate latency")
    }

    private func allCorePingsTimedOut(
        gateway: EndpointStatus?,
        cloudflare: EndpointStatus?,
        google: EndpointStatus?
    ) -> Bool {
        let core = [gateway, cloudflare, google]
        guard core.allSatisfy({ $0?.latest != nil }) else {
            return false
        }
        return core.allSatisfy { status in
            guard let latest = status?.latest else { return false }
            return latest.timedOut || !latest.success
        }
    }

    private func exceedsDegraded(meanMs: Double?, thresholdMs: Double) -> Bool {
        guard let meanMs else { return false }
        return meanMs > thresholdMs
    }

    private func isHealthy(cloudflareMean: Double?, googleMean: Double?, config: AppConfig) -> Bool {
        guard
            let cloudflareMean,
            let googleMean
        else {
            return false
        }
        return cloudflareMean <= config.healthyThresholdMs && googleMean <= config.healthyThresholdMs
    }

    private func isBlazing(
        gatewayMean: Double?,
        cloudflareMean: Double?,
        googleMean: Double?,
        config: AppConfig
    ) -> Bool {
        guard
            let gatewayMean,
            let cloudflareMean,
            let googleMean
        else {
            return false
        }

        return gatewayMean < config.blazingGatewayThresholdMs &&
            cloudflareMean < config.blazingWanThresholdMs &&
            googleMean < config.blazingWanThresholdMs
    }
}
