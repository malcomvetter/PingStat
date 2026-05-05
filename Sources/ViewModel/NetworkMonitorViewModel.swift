import Foundation
import SwiftUI
import Combine
import AppKit

@MainActor
final class NetworkMonitorViewModel: ObservableObject {
    /// Same window as health notification toasts: status bar icon stays on best health until this elapses after `start()`.
    private static let healthUIStabilizationDelaySeconds: TimeInterval = 30

    @Published private(set) var context: NetworkContext = .empty
    @Published private(set) var endpoints: [EndpointStatus] = []
    @Published private(set) var dnsStatus = DNSCheckStatus()
    /// Last DNS probe detail lines keyed by nameserver address (e.g. `8.8.8.8`), max 2 lines per server, for endpoint detail.
    @Published private(set) var dnsProbeHistoryByNameserver: [String: [String]] = [:]
    @Published private(set) var snapshot = HealthSnapshot(
        state: .offline,
        reason: "Initializing",
        updatedAt: Date()
    )
    @Published private(set) var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
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
        logging: LoggingService = LoggingService()
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
        logging.log(.info, category: .lifecycle, "Starting network monitor")
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
        rebuildEndpoints()
        observePowerMode()
        startPingLoop()
        startDNSLoop()
    }

    func stop() {
        coalesceHealthEvaluationItem?.cancel()
        coalesceHealthEvaluationItem = nil
        statusIconGracePeriodTask?.cancel()
        statusIconGracePeriodTask = nil
        pingLoopTask?.cancel()
        dnsLoopTask?.cancel()
        pingLoopTask = nil
        dnsLoopTask = nil
        networkContextService.stop()
        if let powerModeObserver {
            NotificationCenter.default.removeObserver(powerModeObserver)
            self.powerModeObserver = nil
        }
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
        return "\(Int(mean.rounded())) ms"
    }

    /// DNS UDP probe log lines: WAN/custom use this endpoint’s nameserver only (max 2). Local network lists each resolver IP in order, up to 2 lines per server.
    func dnsProbeLogLines(for endpoint: EndpointStatus) -> [String] {
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
            logs: logs
        )
        return try debugExportService.exportJSON(to: directoryURL, payload: payload)
    }

    private func bind() {
        networkContextService.$context
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newContext in
                guard let self else { return }
                let hadConnectivity = self.context.connected
                let oldGateway = self.context.gatewayIP
                self.context = newContext
                if hadConnectivity, !newContext.connected {
                    self.endpoints = OfflineProbeDisplayPolicy.probeHistoryClearedEndpoints(self.endpoints)
                    self.dnsStatus = DNSCheckStatus()
                    self.dnsProbeHistoryByNameserver = [:]
                    self.previousDNSFiltering = false
                }
                if oldGateway != newContext.gatewayIP {
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

    private func startPingLoop() {
        pingLoopTask?.cancel()
        pingLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runPingTick()
                let interval = self.settingsStore.config.adjustedPingInterval(lowPowerMode: self.lowPowerModeEnabled)
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
                let interval = self.settingsStore.config.adjustedDNSInterval(lowPowerMode: self.lowPowerModeEnabled)
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
        let targets = endpoints.map {
            PingTarget(
                id: $0.id,
                label: $0.label,
                host: $0.host,
                kind: $0.kind
            )
        }
        guard !targets.isEmpty else { return }

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
        let customNameservers: [String] = {
            guard let t = settingsStore.config.customTarget, t.dnsProbesEnabled else { return [] }
            let ip = t.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            return ip.isEmpty ? [] : [ip]
        }()
        let result = await dnsService.check(
            probeHostname: settingsStore.config.sanitizedDNSProbeHostname,
            configuredServers: context.dnsServers,
            fallbackServers: settingsStore.config.fallbackDNSServers,
            customNameservers: customNameservers,
            timeoutMs: settingsStore.config.servicePingTimeoutMs
        )
        dnsStatus = result.status
        recordDNSProbeHistory(result.status)

        let shouldNotifyFiltering = result.status.allConfiguredTimedOut && result.status.fallbackWorked
        if shouldNotifyFiltering {
            if !previousDNSFiltering, healthToastsPermitted() {
                notificationService.notifyDNSFiltering(cooldownSeconds: settingsStore.config.notificationCooldownSeconds)
                previousDNSFiltering = true
            }
        } else {
            previousDNSFiltering = false
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
            config: settingsStore.config
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
        var newEndpoints: [EndpointStatus] = []
        if let gateway = context.gatewayIP, !gateway.isEmpty {
            newEndpoints.append(EndpointStatus(
                id: "gateway",
                label: "Gateway",
                host: gateway,
                kind: .gateway,
                meanLast5Ms: nil,
                last10: [],
                latest: nil
            ))
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
            .level3: "Level3",
            .quad9: "Quad9"
        ]
        for (kind, host) in settingsStore.config.enabledWanResolverTargets {
            guard let id = wanIdByKind[kind] else { continue }
            let label = wanLabelByKind[kind] ?? host
            newEndpoints.append(EndpointStatus(
                id: id,
                label: label,
                host: host,
                kind: kind,
                meanLast5Ms: nil,
                last10: [],
                latest: nil
            ))
        }

        if let customTarget = settingsStore.config.customTarget,
           !customTarget.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !customTarget.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newEndpoints.append(EndpointStatus(
                id: "custom",
                label: customTarget.label,
                host: customTarget.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: .custom,
                meanLast5Ms: nil,
                last10: [],
                latest: nil
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
            guard let key = Self.nameserverKey(fromProbeDetailLine: detail) else { continue }
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

    private static func nameserverKey(fromProbeDetailLine detail: String) -> String? {
        guard let at = detail.firstIndex(of: "@") else { return nil }
        let afterAt = detail[detail.index(after: at)...]
        if let space = afterAt.firstIndex(of: " ") {
            return String(afterAt[..<space])
        }
        return String(afterAt).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let dnsProbeHistoryTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
