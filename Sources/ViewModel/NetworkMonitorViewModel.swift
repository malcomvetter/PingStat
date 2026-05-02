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
    /// One-line summaries of the last DNS probe runs (newest last), max 2, for the endpoint detail UI.
    @Published private(set) var dnsProbeHistoryLines: [String] = []
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
                    self.previousDNSFiltering = false
                }
                if oldGateway != newContext.gatewayIP {
                    self.rebuildEndpoints()
                }
                self.evaluateHealth()
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
                let interval = self.settingsStore.config.adjustedPingInterval(lowPowerMode: self.lowPowerModeEnabled)
                await self.runPingTick()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func startDNSLoop() {
        dnsLoopTask?.cancel()
        dnsLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = self.settingsStore.config.adjustedDNSInterval(lowPowerMode: self.lowPowerModeEnabled)
                await self.runDNSTick()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
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
        evaluateHealth()
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
        evaluateHealth()
    }

    private func evaluateHealth() {
        let map = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.kind, $0) })
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
        if settingsStore.config.pingCloudflareEnabled {
            newEndpoints.append(EndpointStatus(
                id: "cloudflare",
                label: "Cloudflare",
                host: "1.1.1.1",
                kind: .cloudflare,
                meanLast5Ms: nil,
                last10: [],
                latest: nil
            ))
        }
        if settingsStore.config.pingGoogleEnabled {
            newEndpoints.append(EndpointStatus(
                id: "google",
                label: "Google",
                host: "8.8.8.8",
                kind: .google,
                meanLast5Ms: nil,
                last10: [],
                latest: nil
            ))
        }
        if settingsStore.config.pingOpenDNSEnabled {
            newEndpoints.append(EndpointStatus(
                id: "opendns",
                label: "OpenDNS",
                host: "208.67.220.220",
                kind: .openDNS,
                meanLast5Ms: nil,
                last10: [],
                latest: nil
            ))
        }
        if settingsStore.config.pingLevel3Enabled {
            newEndpoints.append(EndpointStatus(
                id: "level3",
                label: "Level3",
                host: "4.2.2.1",
                kind: .level3,
                meanLast5Ms: nil,
                last10: [],
                latest: nil
            ))
        }
        if settingsStore.config.pingQuad9Enabled {
            newEndpoints.append(EndpointStatus(
                id: "quad9",
                label: "Quad9",
                host: "9.9.9.9",
                kind: .quad9,
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
        let line = Self.formatDNSProbeHistoryLine(status: status)
        var next = dnsProbeHistoryLines
        next.append(line)
        if next.count > 2 {
            next.removeFirst(next.count - 2)
        }
        dnsProbeHistoryLines = next
    }

    private static func formatDNSProbeHistoryLine(status: DNSCheckStatus) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: status.lastCheck ?? Date())
        var parts: [String] = []
        if status.configuredServers.isEmpty {
            parts.append("no system resolvers")
            parts.append(status.fallbackWorked ? "fallback OK" : "fallback fail")
        } else {
            parts.append(status.allConfiguredTimedOut ? "system timed out" : "system OK")
            if status.allConfiguredTimedOut {
                parts.append(status.fallbackWorked ? "fallback OK" : "fallback fail")
            }
        }
        if status.resolvedPrivateIP {
            parts.append("private IP answer")
        }
        if !status.customNameserverProbes.isEmpty {
            let summaries = status.customNameserverProbes
                .map { key, ok in "\(key)=\(ok ? "OK" : "no answer")" }
                .sorted()
            parts.append("custom \(summaries.joined(separator: ", "))")
        }
        return "\(ts) DNS probe: " + parts.joined(separator: "; ")
    }
}
