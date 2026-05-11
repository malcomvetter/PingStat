import Foundation
import SwiftUI
import Combine
import AppKit
import Network

@MainActor
final class NetworkMonitorViewModel: ObservableObject {
    /// Same window as health notification toasts: status bar icon stays on best health until this elapses after `start()`.
    private static let healthUIStabilizationDelaySeconds: TimeInterval = 30

    @Published private(set) var context: NetworkContext = .empty
    @Published private(set) var endpoints: [EndpointStatus] = []
    @Published private(set) var dnsStatus = DNSCheckStatus()
    /// DNS probe results for **VPN-pushed** resolvers (``NetworkContext.dnsServersVPN``); empty when no VPN path.
    @Published private(set) var dnsStatusVPN = DNSCheckStatus()
    /// Last DNS probe detail lines keyed by nameserver address (e.g. `8.8.8.8`), max 2 lines per server, for endpoint detail.
    @Published private(set) var dnsProbeHistoryByNameserver: [String: [String]] = [:]
    @Published private(set) var snapshot = HealthSnapshot(
        state: .offline,
        reason: "Initializing",
        updatedAt: Date()
    )
    @Published private(set) var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Satisfied path that is constrained or expensive (Apple APIs); shown in UI as **Low Data Mode**.
    @Published private(set) var lowDataModePathActive = false
    @Published private(set) var notificationBannerHelp: NotificationBannerHelp = .unknown

    let settingsStore: SettingsStore

    private let networkContextService: NetworkContextService
    private let pingService: PingService
    private let dnsService: DNSService
    private let healthEvaluator: HealthEvaluator
    private let notificationService: NotificationService
    private let logging: LoggingService
    private let loginItemService: LoginItemService
    private let debugExportService: DebugExportService

    private var cancellables = Set<AnyCancellable>()
    private var pingLoopTask: Task<Void, Never>?
    private var dnsLoopTask: Task<Void, Never>?
    private var powerModeObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var lowDataPathMonitor: NWPathMonitor?
    private let lowDataPathQueue = DispatchQueue(label: "PingStat.lowDataPath")
    private var previousState: NetworkHealthState = .offline
    private var previousDNSFiltering = false
    /// Health-related notification toasts are suppressed until this time (set in `start()`).
    private var healthToastsNotBefore: Date?
    private var lastAppliedShowNotifications: Bool?

    private var statusIconGracePeriodTask: Task<Void, Never>?

    /// Coalesces health evaluation onto the next main-queue turn to avoid publishing during SwiftUI view updates (which can terminate the process).
    private var coalesceHealthEvaluationItem: DispatchWorkItem?

    /// When false (initial and for `Self.healthUIStabilizationDelaySeconds` after each `start()`), the status item shows best health instead of `snapshot.state`.
    @Published private(set) var statusBarIconReflectsLiveHealth = false

    init(
        settingsStore: SettingsStore,
        logging: LoggingService = .shared
    ) {
        self.settingsStore = settingsStore
        self.logging = logging
        self.networkContextService = NetworkContextService(
            logger: logging,
            debugEnabledProvider: { settingsStore.config.debugLoggingEnabled }
        )
        self.pingService = PingService(
            logger: logging,
            debugEnabledProvider: { settingsStore.config.debugLoggingEnabled }
        )
        self.dnsService = DNSService(
            logger: logging,
            debugEnabledProvider: { settingsStore.config.debugLoggingEnabled }
        )
        self.healthEvaluator = HealthEvaluator()
        self.notificationService = NotificationService(logger: logging)
        self.loginItemService = LoginItemService(logger: logging)
        self.debugExportService = DebugExportService(logger: logging)
        bind()
    }

    func start() {
        let c = settingsStore.config
        logging.log(
            .notice,
            category: .lifecycle,
            "event=monitor_start ping_interval_ms=\(Int(c.pingIntervalMs)) dns_interval_ms=\(Int(c.dnsIntervalMs)) notifications=\(c.showNotificationsEnabled) debug_file_logging=\(c.debugLoggingEnabled)"
        )
        healthToastsNotBefore = Date().addingTimeInterval(Self.healthUIStabilizationDelaySeconds)
        statusBarIconReflectsLiveHealth = false
        statusIconGracePeriodTask?.cancel()
        statusIconGracePeriodTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let deadline = self.healthToastsNotBefore else {
                self.statusBarIconReflectsLiveHealth = true
                return
            }
            let seconds = max(0, deadline.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.statusBarIconReflectsLiveHealth = true
        }
        if settingsStore.config.showNotificationsEnabled {
            notificationService.requestAuthorizationIfNeeded()
        }
        networkContextService.start()
        startLowDataPathMonitoring()
        rebuildEndpoints()
        observePowerMode()
        observeSystemWake()
        startPingLoop()
        startDNSLoop()
    }

    func stop() {
        logging.log(.notice, category: .lifecycle, "event=monitor_stop phase=begin")
        coalesceHealthEvaluationItem?.cancel()
        coalesceHealthEvaluationItem = nil
        statusIconGracePeriodTask?.cancel()
        statusIconGracePeriodTask = nil
        pingLoopTask?.cancel()
        dnsLoopTask?.cancel()
        pingLoopTask = nil
        dnsLoopTask = nil
        lowDataPathMonitor?.cancel()
        lowDataPathMonitor = nil
        networkContextService.stop()
        if let powerModeObserver {
            NotificationCenter.default.removeObserver(powerModeObserver)
            self.powerModeObserver = nil
        }
        removeSystemWakeObserver()
        logging.log(.notice, category: .lifecycle, "event=monitor_stop phase=end")
    }

    func refreshNotificationBannerHelp() async {
        notificationBannerHelp = await notificationService.bannerHelpSnapshot()
    }

    func openSystemNotificationSettings() {
        notificationService.openSystemNotificationsSettings()
    }

    func requestNotificationPermissionFromSettings() async {
        _ = await notificationService.requestAuthorizationFromUserPrompt()
        await refreshNotificationBannerHelp()
    }

    func meanText(for endpoint: EndpointStatus) -> String {
        guard let mean = endpoint.meanLast5Ms else { return "--" }
        let displayMean: Double
        if endpoint.kind == .vpnTunnel {
            displayMean = mean + settingsStore.config.vpnICMPOverheadPaddingMs
        } else {
            displayMean = mean
        }
        return "\(Int(displayMean.rounded())) ms"
    }

    /// DNS UDP probe log lines: WAN/custom use this endpoint’s nameserver only (max 2). Local network lists each resolver IP in order, up to 2 lines per server.
    func dnsProbeLogLines(for endpoint: EndpointStatus) -> [String] {
        if endpoint.kind == .vpnTunnel {
            let keys = context.dnsServersVPN.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var combined: [String] = []
            for k in keys {
                combined.append(contentsOf: dnsProbeHistoryByNameserver[k] ?? [])
            }
            return combined
        }
        if endpoint.kind == .gateway {
            var keys: [String] = []
            var seen = Set<String>()
            let keySources =
                context.dnsServers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                + [endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)]
            for s in keySources {
                guard !s.isEmpty, !seen.contains(s) else { continue }
                seen.insert(s)
                keys.append(s)
            }
            var combined: [String] = []
            for k in keys {
                combined.append(contentsOf: dnsProbeHistoryByNameserver[k] ?? [])
            }
            return combined
        }
        let k = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return dnsProbeHistoryByNameserver[k] ?? []
    }

    func latestStateColor(for state: NetworkHealthState, colorScheme: ColorScheme) -> Color {
        switch state {
        case .offline:
            return .red
        case .degraded:
            return .orange
        case .healthy, .blazing:
            return HealthAppearance.successGreen(for: colorScheme)
        }
    }

    func exportDebugData(to directoryURL: URL) async throws -> URL {
        let logs = await logging.exportEntries()
        let payload = DebugExportPayload(
            createdAt: Date(),
            context: context,
            config: settingsStore.config,
            snapshot: snapshot,
            endpoints: endpoints,
            dnsStatus: dnsStatus,
            dnsStatusVPN: dnsStatusVPN,
            logs: logs
        )
        return try debugExportService.exportJSON(to: directoryURL, payload: payload)
    }

    private func bind() {
        networkContextService.$context
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newContext in
                guard let self else { return }
                let previous = self.context
                let hadConnectivity = previous.connected
                self.context = newContext
                if hadConnectivity, !newContext.connected {
                    self.endpoints = OfflineProbeDisplayPolicy.probeHistoryClearedEndpoints(self.endpoints)
                    self.dnsStatus = DNSCheckStatus()
                    self.dnsStatusVPN = DNSCheckStatus()
                    self.dnsProbeHistoryByNameserver = [:]
                    self.previousDNSFiltering = false
                }
                if previous != newContext {
                    self.rebuildEndpoints()
                }
                self.requestHealthEvaluation()
            }
            .store(in: &cancellables)

        settingsStore.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                guard let self else { return }
                self.loginItemService.apply(enabled: config.launchAtLoginEnabled)
                if config.showNotificationsEnabled, self.lastAppliedShowNotifications == false {
                    self.notificationService.requestAuthorizationIfNeeded()
                }
                self.lastAppliedShowNotifications = config.showNotificationsEnabled
                // Defer endpoint rebuild: settings TextField bindings update `config` synchronously;
                // rebuilding `endpoints` here publishes on `self` during the same update and can abort the app.
                Task { @MainActor [weak self] in
                    self?.rebuildEndpoints()
                    self?.requestHealthEvaluation()
                }
            }
            .store(in: &cancellables)
    }

    private func observePowerMode() {
        if let powerModeObserver {
            NotificationCenter.default.removeObserver(powerModeObserver)
        }
        powerModeObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            self.logging.log(
                .notice,
                category: .lifecycle,
                "Low power mode changed: \(self.lowPowerModeEnabled)"
            )
            self.startPingLoop()
            self.startDNSLoop()
        }
    }

    private func observeSystemWake() {
        removeSystemWakeObserver()
        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemDidWake()
        }
    }

    private func removeSystemWakeObserver() {
        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
            self.workspaceWakeObserver = nil
        }
    }

    private func handleSystemDidWake() {
        logging.log(.notice, category: .lifecycle, "event=system_did_wake note=NSWorkspace.didWakeNotification")
        networkContextService.restartPathMonitoring()
        rebuildEndpoints()
        startPingLoop()
        startDNSLoop()
        requestHealthEvaluation()
    }

    private func startLowDataPathMonitoring() {
        lowDataPathMonitor?.cancel()
        let mon = NWPathMonitor()
        mon.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.applyLowDataModePath(path)
            }
        }
        mon.start(queue: lowDataPathQueue)
        lowDataPathMonitor = mon
        applyLowDataModePath(mon.currentPath)
    }

    private func applyLowDataModePath(_ path: NWPath) {
        let active = path.status == .satisfied && (path.isConstrained || path.isExpensive)
        guard active != lowDataModePathActive else { return }
        lowDataModePathActive = active
        logging.log(
            .notice,
            category: .lifecycle,
            "Low Data Mode path active=\(active) status=\(String(describing: path.status)) constrained=\(path.isConstrained) expensive=\(path.isExpensive)"
        )
        rebuildEndpoints()
        startPingLoop()
        startDNSLoop()
        requestHealthEvaluation()
    }

    private func startPingLoop() {
        pingLoopTask?.cancel()
        pingLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runPingTick()
                let interval = self.settingsStore.config.adjustedPingInterval(
                    lowPowerMode: self.lowPowerModeEnabled,
                    lowDataMode: self.lowDataModePathActive
                )
                await Self.sleepSecondsClamped(interval)
            }
        }
    }

    private func startDNSLoop() {
        dnsLoopTask?.cancel()
        dnsLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runDNSTick()
                let interval = self.settingsStore.config.adjustedDNSInterval(
                    lowPowerMode: self.lowPowerModeEnabled,
                    lowDataMode: self.lowDataModePathActive
                )
                await Self.sleepSecondsClamped(interval)
            }
        }
    }

    /// Avoid `Task.sleep` overflow / absurd intervals from bad prefs.
    private static func sleepSecondsClamped(_ seconds: Double) async {
        let clamped = min(max(seconds, 0.001), 86_400)
        let nanosDouble = min(clamped * 1_000_000_000, Double(UInt64.max))
        let ns = max(UInt64(1), UInt64(nanosDouble))
        try? await Task.sleep(nanoseconds: ns)
    }

    private func runPingTick() async {
        if endpoints.isEmpty {
            rebuildEndpoints()
        }
        guard ConnectivityProbePolicy.shouldRunICMPProbes(pathSatisfied: context.connected) else {
            return
        }
        let targets = endpoints.filter(\.icmpProbingActive).map {
            PingTarget(
                id: $0.id,
                label: $0.label,
                host: $0.host,
                kind: $0.kind
            )
        }
        guard !targets.isEmpty else {
            requestHealthEvaluation()
            return
        }

        let timeoutMs = settingsStore.config.servicePingTimeoutMs
        let responses = await withTaskGroup(of: PingResponse.self, returning: [PingResponse].self) { group in
            for target in targets {
                group.addTask { [pingService] in
                    await pingService.ping(target: target, timeoutMs: timeoutMs)
                }
            }

            var collected: [PingResponse] = []
            for await response in group {
                collected.append(response)
            }
            return collected
        }

        for response in responses {
            guard let index = endpoints.firstIndex(where: { $0.id == response.target.id }) else { continue }
            var endpoint = endpoints[index]
            endpoint.last10.append(response.sample)
            if endpoint.last10.count > 10 {
                endpoint.last10.removeFirst(endpoint.last10.count - 10)
            }
            endpoint.latest = response.sample
            endpoint.meanLast5Ms = computeMeanLast5(endpoint.last10)
            endpoints[index] = endpoint
        }
        requestHealthEvaluation()
    }

    private func runDNSTick() async {
        guard ConnectivityProbePolicy.shouldRunDNSProbes(pathSatisfied: context.connected) else {
            return
        }
        let cfg = settingsStore.config
        let ldm = lowDataModePathActive
        let skipSystemResolverProbes = ldm && !cfg.lowDataModeUseLocalNetworkDNS
        let configuredPhysical: [String] = skipSystemResolverProbes
            ? []
            : context.dnsServers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let fallbackServers = cfg.fallbackDNSServersForProbes(lowDataModePathActive: ldm)
        let customNameservers: [String] = {
            guard let t = cfg.customTarget, t.dnsProbesEnabled else { return [] }
            guard !ldm || t.useInLowDataMode else { return [] }
            let ip = t.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            return ip.isEmpty ? [] : [ip]
        }()
        let physicalHasWork =
            !configuredPhysical.isEmpty || !fallbackServers.isEmpty || !customNameservers.isEmpty

        let configuredVPN: [String] = {
            guard context.vpnPathActive else { return [] }
            guard !skipSystemResolverProbes else { return [] }
            return context.dnsServersVPN.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }()
        let vpnHasWork =
            context.vpnPathActive
            && (!configuredVPN.isEmpty || !fallbackServers.isEmpty || !customNameservers.isEmpty)

        guard physicalHasWork || vpnHasWork else {
            dnsStatus = DNSCheckStatus()
            dnsStatusVPN = DNSCheckStatus()
            requestHealthEvaluation()
            return
        }

        if physicalHasWork {
            let result = await dnsService.check(
                probeHostname: cfg.sanitizedDNSProbeHostname,
                configuredServers: configuredPhysical,
                fallbackServers: fallbackServers,
                customNameservers: customNameservers,
                timeoutMs: cfg.servicePingTimeoutMs,
                skipSystemResolverProbes: skipSystemResolverProbes && configuredPhysical.isEmpty
            )
            dnsStatus = result.status
            recordDNSProbeHistory(result.status)

            let shouldNotifyFiltering =
                result.status.allConfiguredTimedOut
                && result.status.fallbackWorked
                && !result.status.systemResolverProbesSkipped
            if shouldNotifyFiltering {
                if !previousDNSFiltering, healthToastsPermitted() {
                    notificationService.notifyDNSFiltering(cooldownSeconds: settingsStore.config.notificationCooldownSeconds)
                    previousDNSFiltering = true
                }
            } else {
                previousDNSFiltering = false
            }
        } else {
            dnsStatus = DNSCheckStatus()
        }

        if vpnHasWork {
            let vpnResult = await dnsService.check(
                probeHostname: cfg.sanitizedDNSProbeHostname,
                configuredServers: configuredVPN,
                fallbackServers: fallbackServers,
                customNameservers: customNameservers,
                timeoutMs: cfg.servicePingTimeoutMs,
                skipSystemResolverProbes: skipSystemResolverProbes && configuredVPN.isEmpty
            )
            dnsStatusVPN = vpnResult.status
            recordDNSProbeHistory(vpnResult.status)
        } else {
            dnsStatusVPN = DNSCheckStatus()
        }

        requestHealthEvaluation()
    }

    private func requestHealthEvaluation() {
        coalesceHealthEvaluationItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.evaluateHealth()
        }
        coalesceHealthEvaluationItem = item
        DispatchQueue.main.async(execute: item)
    }

    /// Builds the endpoint map without trapping on duplicate ``EndpointKind`` (defensive).
    private func endpointStatusesByKindForHealth() -> [EndpointKind: EndpointStatus] {
        var map: [EndpointKind: EndpointStatus] = [:]
        for ep in endpoints {
            if let existing = map[ep.kind] {
                logging.log(
                    .error,
                    category: .errors,
                    "Duplicate endpoint kind \(String(describing: ep.kind)) (ids \(existing.id) vs \(ep.id)); using \(ep.id)"
                )
            }
            map[ep.kind] = ep
        }
        return map
    }

    private func evaluateHealth() {
        let map = endpointStatusesByKindForHealth()
        let input = HealthEvaluationInput(
            context: context,
            endpointStatuses: map,
            dnsStatus: dnsStatus,
            config: settingsStore.config,
            lowDataModePathActive: lowDataModePathActive
        )
        let updated = healthEvaluator.evaluate(input)
        snapshot = updated

        if updated.state != previousState {
            logging.log(
                .notice,
                category: .health,
                "State changed \(previousState.rawValue) -> \(updated.state.rawValue): \(updated.reason)"
            )
            if healthToastsPermitted() {
                notificationService.notifyStateTransition(
                    to: updated.state,
                    reason: updated.reason,
                    cooldownSeconds: settingsStore.config.notificationCooldownSeconds
                )
            }
            previousState = updated.state
        }
    }

    private func healthToastsPermitted() -> Bool {
        guard settingsStore.config.showNotificationsEnabled else { return false }
        guard let notBefore = healthToastsNotBefore else { return false }
        return Date() >= notBefore
    }

    private func rebuildEndpoints() {
        let ldm = lowDataModePathActive
        let cfg = settingsStore.config
        var newEndpoints: [EndpointStatus] = []
        if let gateway = context.gatewayIP, !gateway.isEmpty {
            let gatewayICMP = LowDataModeProbeEligibility.gatewayICMPProbingActive(lowDataModePathActive: ldm)
            let gatewayDNS = LowDataModeProbeEligibility.gatewayDNSProbingActive(lowDataModePathActive: ldm, config: cfg)
            newEndpoints.append(EndpointStatus(
                id: "gateway",
                label: "Gateway",
                host: gateway,
                kind: .gateway,
                meanLast5Ms: nil,
                last10: [],
                latest: nil,
                icmpProbingActive: gatewayICMP,
                dnsProbingActive: gatewayDNS
            ))
        }

        if context.vpnPathActive {
            let tunnelGw = context.vpnTunnelGatewayIPv4?.trimmingCharacters(in: .whitespacesAndNewlines)
            let vpnDns = context.dnsServersVPN.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let hasIcmp = tunnelGw.map { !$0.isEmpty } ?? false
            let hasDns = !vpnDns.isEmpty
            if hasIcmp || hasDns {
                let host: String = {
                    if let g = tunnelGw, !g.isEmpty { return g }
                    return vpnDns.first ?? "VPN"
                }()
                let vpnLabel: String = {
                    let n = context.vpnNetworkServiceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return n.isEmpty ? "VPN" : n
                }()
                let icmpOn = hasIcmp && LowDataModeProbeEligibility.vpnTunnelICMPProbingActive(lowDataModePathActive: ldm)
                let dnsOn = hasDns && LowDataModeProbeEligibility.vpnTunnelDNSProbingActive(lowDataModePathActive: ldm, config: cfg)
                newEndpoints.append(EndpointStatus(
                    id: "vpn",
                    label: vpnLabel,
                    host: host,
                    kind: .vpnTunnel,
                    meanLast5Ms: nil,
                    last10: [],
                    latest: nil,
                    icmpProbingActive: icmpOn,
                    dnsProbingActive: dnsOn
                ))
            }
        }

        let wanIdByKind: [EndpointKind: String] = [
            .cloudflare: "cloudflare",
            .google: "google",
            .openDNS: "opendns",
            .level3: "level3",
            .quad9: "quad9"
        ]
        let wanLabelByKind: [EndpointKind: String] = [
            .cloudflare: "Cloudflare",
            .google: "Google",
            .openDNS: "OpenDNS",
            .level3: "CenturyLink",
            .quad9: "Quad9"
        ]
        for (kind, host) in cfg.enabledWanResolverTargets {
            guard let id = wanIdByKind[kind] else { continue }
            let label = wanLabelByKind[kind] ?? host
            let eligible = LowDataModeProbeEligibility.wanProbingEligible(lowDataModePathActive: ldm, config: cfg, kind: kind)
            newEndpoints.append(EndpointStatus(
                id: id,
                label: label,
                host: host,
                kind: kind,
                meanLast5Ms: nil,
                last10: [],
                latest: nil,
                icmpProbingActive: eligible,
                dnsProbingActive: eligible
            ))
        }

        if let customTarget = cfg.customTarget,
           !customTarget.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !customTarget.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let icmpOn = LowDataModeProbeEligibility.customICMPProbingActive(lowDataModePathActive: ldm, target: customTarget)
            let dnsOn = LowDataModeProbeEligibility.customDNSProbingActive(lowDataModePathActive: ldm, target: customTarget)
            newEndpoints.append(EndpointStatus(
                id: "custom",
                label: customTarget.label,
                host: customTarget.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: .custom,
                meanLast5Ms: nil,
                last10: [],
                latest: nil,
                icmpProbingActive: icmpOn,
                dnsProbingActive: dnsOn
            ))
        }
        endpoints = newEndpoints
    }

    private func computeMeanLast5(_ samples: [PingSample]) -> Double? {
        let recent = Array(samples.suffix(5))
        guard !recent.isEmpty else { return nil }
        let values = recent.map { $0.rttMs ?? settingsStore.config.pingTimeoutMs }
        return values.reduce(0, +) / Double(values.count)
    }

    private func recordDNSProbeHistory(_ status: DNSCheckStatus) {
        let ts = Self.dnsProbeHistoryTimeFormatter.string(from: status.lastCheck ?? Date())
        guard !status.lastResolverDetailLines.isEmpty else { return }
        var next = dnsProbeHistoryByNameserver
        for detail in status.lastResolverDetailLines {
            guard let key = DNSProbeDetailLine.nameserverKey(from: detail) else { continue }
            let prefixed = "\(ts) \(detail)"
            var bucket = next[key] ?? []
            bucket.append(prefixed)
            let cap = 2
            if bucket.count > cap {
                bucket.removeFirst(bucket.count - cap)
            }
            next[key] = bucket
        }
        dnsProbeHistoryByNameserver = next
    }

    private static let dnsProbeHistoryTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
