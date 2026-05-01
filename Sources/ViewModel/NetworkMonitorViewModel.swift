import Foundation
import SwiftUI
import Combine
import AppKit

@MainActor
final class NetworkMonitorViewModel: ObservableObject {
    @Published private(set) var context: NetworkContext = .empty
    @Published private(set) var endpoints: [EndpointStatus] = []
    @Published private(set) var dnsStatus = DNSCheckStatus()
    @Published private(set) var snapshot = HealthSnapshot(
        state: .offline,
        reason: "Initializing",
        updatedAt: Date()
    )
    @Published private(set) var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

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

    init(
        settingsStore: SettingsStore,
        commandRunner: CommandRunner = CommandRunner(),
        logging: LoggingService = LoggingService()
    ) {
        self.settingsStore = settingsStore
        self.logging = logging
        self.networkContextService = NetworkContextService(
            commandRunner: commandRunner,
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
        notificationService.requestAuthorizationIfNeeded()
        networkContextService.start()
        rebuildEndpoints()
        observePowerMode()
        startPingLoop()
        startDNSLoop()
    }

    func stop() {
        pingLoopTask?.cancel()
        dnsLoopTask?.cancel()
        if let powerModeObserver {
            NotificationCenter.default.removeObserver(powerModeObserver)
            self.powerModeObserver = nil
        }
    }

    func meanText(for endpoint: EndpointStatus) -> String {
        guard let mean = endpoint.meanLast5Ms else { return "--" }
        return "\(Int(mean.rounded())) ms"
    }

    func latestStateColor(for state: NetworkHealthState) -> Color {
        switch state {
        case .offline:
            return .red
        case .degraded:
            return .yellow
        case .healthy, .blazing:
            return .green
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
                let oldGateway = self.context.gatewayIP
                self.context = newContext
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
                self.rebuildEndpoints()
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
        let targets = endpoints.map {
            PingTarget(
                id: $0.id,
                label: $0.label,
                host: $0.host,
                kind: $0.kind
            )
        }
        guard !targets.isEmpty else { return }

        let timeoutMs = settingsStore.config.pingTimeoutMs
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
        let result = await dnsService.check(
            configuredServers: context.dnsServers,
            fallbackServers: settingsStore.config.fallbackDNSServers,
            timeoutMs: settingsStore.config.pingTimeoutMs
        )
        dnsStatus = result.status

        let shouldNotifyFiltering = result.status.allConfiguredTimedOut && result.status.fallbackWorked
        if shouldNotifyFiltering, !previousDNSFiltering {
            notificationService.notifyDNSFiltering(cooldownSeconds: settingsStore.config.notificationCooldownSeconds)
        }
        previousDNSFiltering = shouldNotifyFiltering
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
            notificationService.notifyStateTransition(
                to: updated.state,
                reason: updated.reason,
                cooldownSeconds: settingsStore.config.notificationCooldownSeconds
            )
            previousState = updated.state
        }
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
        newEndpoints.append(EndpointStatus(
            id: "cloudflare",
            label: "Cloudflare",
            host: "1.1.1.1",
            kind: .cloudflare,
            meanLast5Ms: nil,
            last10: [],
            latest: nil
        ))
        newEndpoints.append(EndpointStatus(
            id: "google",
            label: "Google",
            host: "8.8.8.8",
            kind: .google,
            meanLast5Ms: nil,
            last10: [],
            latest: nil
        ))

        if let customTarget = settingsStore.config.customTarget,
           !customTarget.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !customTarget.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newEndpoints.append(EndpointStatus(
                id: "custom",
                label: customTarget.label,
                host: customTarget.ipAddress,
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
        let values = recent.map { $0.rttMs ?? Double(settingsStore.config.pingTimeoutMs) }
        return values.reduce(0, +) / Double(values.count)
    }
}
