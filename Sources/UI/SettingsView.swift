import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel
    @State private var expandedWanTargets: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppBranding.productName)
                .font(.title2.weight(.semibold))

            ScrollView {
                Form {
                    Section {
                        Toggle("Launch at Login", isOn: binding(\.launchAtLoginEnabled))
                    }

                    Section {
                        Toggle("Enable Debug Logging", isOn: binding(\.debugLoggingEnabled))
                    }

                    Section("Notifications") {
                        Toggle("Show Notifications", isOn: binding(\.showNotificationsEnabled))
                        LabeledContent("Notification Cooldown") {
                            HStack(spacing: 4) {
                                TextField(
                                    "Notification Cooldown",
                                    value: binding(\.notificationCooldownSeconds),
                                    format: .number
                                )
                                .labelsHidden()
                                .frame(width: 80)
                                Text("s")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(viewModel.notificationBannerHelp.headline)
                                .font(.body.weight(.semibold))
                            Text(viewModel.notificationBannerHelp.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)

                        HStack(spacing: 12) {
                            Button("Refresh status") {
                                Task { await viewModel.refreshNotificationBannerHelp() }
                            }
                            Button("Open System Settings…") {
                                viewModel.openSystemNotificationSettings()
                            }
                        }
                        if viewModel.notificationBannerHelp.showRequestPermissionButton {
                            Button("Request permission…") {
                                Task { await viewModel.requestNotificationPermissionFromSettings() }
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("If notification icons still look blank after adding an app icon: quit PingStat, then in Terminal run:")
                            Text("killall NotificationCenter")
                                .font(.system(.caption, design: .monospaced))
                            Text("That restarts Notification Center; then reopen PingStat.")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Section("WAN Targets") {
                        wanTargetDisclosure(
                            title: "Cloudflare",
                            enabled: binding(\.pingCloudflareEnabled),
                            lowDataMode: binding(\.lowDataModeUseCloudflare)
                        )
                        wanTargetDisclosure(
                            title: "Google",
                            enabled: binding(\.pingGoogleEnabled),
                            lowDataMode: binding(\.lowDataModeUseGoogle)
                        )
                        wanTargetDisclosure(
                            title: "OpenDNS",
                            enabled: binding(\.pingOpenDNSEnabled),
                            lowDataMode: binding(\.lowDataModeUseOpenDNS)
                        )
                        wanTargetDisclosure(
                            title: "CenturyLink",
                            enabled: binding(\.pingLevel3Enabled),
                            lowDataMode: binding(\.lowDataModeUseLevel3)
                        )
                        wanTargetDisclosure(
                            title: "Quad9",
                            enabled: binding(\.pingQuad9Enabled),
                            lowDataMode: binding(\.lowDataModeUseQuad9)
                        )
                    }

                    Section("Local Network") {
                        Text(
                            "ICMP to the default gateway is never sent while Low Data Mode is active. You can still allow DNS probes against your system-configured resolvers (popover “Local Network” DNS column)."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Toggle("Use system DNS in Low Data Mode", isOn: binding(\.lowDataModeUseLocalNetworkDNS))
                    }

                    Section("Custom Targets") {
                        TextField("Label", text: customLabelBinding())
                        TextField("IP Address", text: customIPBinding())
                        Toggle("Use DNS probes", isOn: customDnsProbesBinding())
                            .disabled(viewModel.settingsStore.config.customTarget == nil)
                            .help(
                                viewModel.settingsStore.config.customTarget == nil
                                    ? "Enter a label or IP address to enable this option."
                                    : "When on, DNS resolution for this target’s hostnames uses your custom nameservers (same as the popover “DNS” column)."
                            )
                        Toggle("Use in Low Data Mode", isOn: customUseInLowDataModeBinding())
                            .disabled(viewModel.settingsStore.config.customTarget == nil)
                            .help(
                                "When Low Data Mode is active (constrained or expensive network path), allow ICMP and DNS probes for this custom target."
                            )
                        Button("Clear custom target") {
                            viewModel.settingsStore.config.customTarget = nil
                        }
                    }

                    Section("Intervals") {
                        LabeledContent("Ping") {
                            HStack(spacing: 4) {
                                TextField(
                                    "Ping",
                                    value: positiveMillisecondsBinding(\.pingIntervalMs, minimum: 1),
                                    format: .number
                                )
                                .labelsHidden()
                                .frame(width: 80)
                                Text("ms")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Timeout") {
                            HStack(spacing: 4) {
                                TextField(
                                    "Timeout",
                                    value: positiveMillisecondsBinding(\.pingTimeoutMs, minimum: 1),
                                    format: .number
                                )
                                .labelsHidden()
                                .frame(width: 80)
                                Text("ms")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("DNS") {
                            HStack(spacing: 4) {
                                TextField(
                                    "DNS",
                                    value: positiveMillisecondsBinding(\.dnsIntervalMs, minimum: 1),
                                    format: .number
                                )
                                .labelsHidden()
                                .frame(width: 80)
                                Text("ms")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("DNS Query Target") {
                            TextField("", text: binding(\.dnsProbeHostname))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(
                                    "Hostname for A-record probes to each resolver (shown in the endpoint detail DNS log). Default is captive.apple.com."
                                )
                        }
                    }

                    Section("Thresholds") {
                        LabeledContent("Blazing") {
                            HStack(spacing: 4) {
                                TextField(
                                    "Blazing",
                                    value: binding(\.blazingThresholdMs),
                                    format: .number
                                )
                                .labelsHidden()
                                .frame(width: 80)
                                Text("ms")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Healthy") {
                            HStack(spacing: 4) {
                                TextField(
                                    "Healthy",
                                    value: binding(\.healthyThresholdMs),
                                    format: .number
                                )
                                .labelsHidden()
                                .frame(width: 80)
                                Text("ms")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Degraded") {
                            HStack(spacing: 4) {
                                TextField(
                                    "Degraded",
                                    value: binding(\.degradedThresholdMs),
                                    format: .number
                                )
                                .labelsHidden()
                                .frame(width: 80)
                                Text("ms")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Precision") {
                        LabeledContent("Matching checks before status changes") {
                            TextField(
                                "Count",
                                value: intBinding(\.statusChangeConfirmationCount),
                                format: .number
                            )
                            .labelsHidden()
                            .frame(width: 80)
                            .help(
                                "How many probe rounds in a row must agree before the menu bar status changes (higher = steadier, slower to react)."
                            )
                        }
                        LabeledContent("Minimum seconds between status changes") {
                            TextField(
                                "Seconds",
                                value: binding(\.minimumSecondsBetweenStatusChanges),
                                format: .number
                            )
                            .labelsHidden()
                            .frame(width: 80)
                            .help(
                                "After the status actually changes, wait at least this long before another change can register (reduces rapid flip-flop)."
                            )
                        }
                    }

                    Section("Diagnostics & Logs") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(
                                "PingStat records lifecycle and probe events with Apple’s unified logging (the same subsystem Console.app and Terminal’s log(1) use). Lifecycle lines use the category app.lifecycle; probes use probe.ping, probe.dns, and related categories."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            Text(
                                "Enable Debug Logging above for verbose probe detail in that stream. Recent lines are also held in an in-memory ring buffer (about two thousand entries) and embedded in the JSON produced by Export Debug…."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Console filter (subsystem)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(AppVersion.consoleSubsystemFilter)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.primary)
                                Text(AppVersion.logStreamShellExample)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.primary)
                            }

                            HStack(spacing: 12) {
                                Button("Copy Console filter") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        AppVersion.consoleSubsystemFilter,
                                        forType: .string
                                    )
                                }
                                Button("Open Console…") {
                                    DiagnosticsUIActions.openConsoleApp()
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    Section {
                        Button("Reset Defaults") {
                            viewModel.settingsStore.resetDefaults()
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .frame(maxWidth: .infinity, minHeight: 420)
        }
        .padding(12)
        .frame(width: 520, height: 780)
        .onAppear {
            Task { await viewModel.refreshNotificationBannerHelp() }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { viewModel.settingsStore.config[keyPath: keyPath] },
            set: { newValue in
                viewModel.settingsStore.config[keyPath: keyPath] = newValue
            }
        )
    }

    private func positiveMillisecondsBinding(_ keyPath: WritableKeyPath<AppConfig, Double>, minimum: Double) -> Binding<Double> {
        Binding(
            get: { viewModel.settingsStore.config[keyPath: keyPath] },
            set: { newValue in
                viewModel.settingsStore.config[keyPath: keyPath] = max(minimum, newValue)
            }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<AppConfig, Int>) -> Binding<Int> {
        Binding(
            get: { viewModel.settingsStore.config[keyPath: keyPath] },
            set: { newValue in
                viewModel.settingsStore.config[keyPath: keyPath] = max(1, newValue)
            }
        )
    }

    @ViewBuilder
    private func wanTargetDisclosure(title: String, enabled: Binding<Bool>, lowDataMode: Binding<Bool>) -> some View {
        let isExpanded = expandedWanTargets.contains(title)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedWanTargets.remove(title)
                        } else {
                            expandedWanTargets.insert(title)
                        }
                    }
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .center)
                        Text(title)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Toggle("", isOn: enabled)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityHint("Enable or disable monitoring for this resolver")
            }
            if isExpanded {
                Toggle("Use in Low Data Mode", isOn: lowDataMode)
                    .disabled(!enabled.wrappedValue)
                    .help("Allow ICMP and DNS probes for this resolver while Low Data Mode is active.")
                    .padding(.leading, 24)
                    .padding(.trailing, 2)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
            }
        }
    }

    private func customLabelBinding() -> Binding<String> {
        Binding(
            get: { viewModel.settingsStore.config.customTarget?.label ?? "" },
            set: { newValue in
                var target =
                    viewModel.settingsStore.config.customTarget
                    ?? CustomPingTarget(label: "", ipAddress: "", dnsProbesEnabled: false, useInLowDataMode: false)
                target.label = newValue
                if target.label.isEmpty && target.ipAddress.isEmpty {
                    viewModel.settingsStore.config.customTarget = nil
                } else {
                    viewModel.settingsStore.config.customTarget = target
                }
            }
        )
    }

    private func customIPBinding() -> Binding<String> {
        Binding(
            get: { viewModel.settingsStore.config.customTarget?.ipAddress ?? "" },
            set: { newValue in
                var target =
                    viewModel.settingsStore.config.customTarget
                    ?? CustomPingTarget(label: "", ipAddress: "", dnsProbesEnabled: false, useInLowDataMode: false)
                target.ipAddress = newValue
                if target.label.isEmpty && target.ipAddress.isEmpty {
                    viewModel.settingsStore.config.customTarget = nil
                } else {
                    viewModel.settingsStore.config.customTarget = target
                }
            }
        )
    }

    private func customDnsProbesBinding() -> Binding<Bool> {
        Binding(
            get: { viewModel.settingsStore.config.customTarget?.dnsProbesEnabled ?? false },
            set: { newValue in
                guard var target = viewModel.settingsStore.config.customTarget else { return }
                target.dnsProbesEnabled = newValue
                viewModel.settingsStore.config.customTarget = target
            }
        )
    }

    private func customUseInLowDataModeBinding() -> Binding<Bool> {
        Binding(
            get: { viewModel.settingsStore.config.customTarget?.useInLowDataMode ?? false },
            set: { newValue in
                guard var target = viewModel.settingsStore.config.customTarget else { return }
                target.useInLowDataMode = newValue
                viewModel.settingsStore.config.customTarget = target
            }
        )
    }
}

private enum DiagnosticsUIActions {
    static func openConsoleApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
