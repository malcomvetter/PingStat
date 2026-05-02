import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel

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

                    Section("WAN targets") {
                        Toggle("Cloudflare", isOn: binding(\.pingCloudflareEnabled))
                        Toggle("Google", isOn: binding(\.pingGoogleEnabled))
                        Toggle("OpenDNS", isOn: binding(\.pingOpenDNSEnabled))
                        Toggle("Level3", isOn: binding(\.pingLevel3Enabled))
                        Toggle("Quad9", isOn: binding(\.pingQuad9Enabled))
                    }

                    Section("Custom Target") {
                        TextField("Label", text: customLabelBinding())
                        TextField("IP Address", text: customIPBinding())
                        Toggle("Use DNS probes", isOn: customDnsProbesBinding())
                            .disabled(viewModel.settingsStore.config.customTarget == nil)
                            .help(
                                viewModel.settingsStore.config.customTarget == nil
                                    ? "Enter a label or IP address to enable this option."
                                    : "When on, DNS resolution for this target’s hostnames uses your custom nameservers (same as the popover “DNS” column)."
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
                        LabeledContent("Enter downgrade count") {
                            TextField(
                                "Enter count",
                                value: intBinding(\.antiFlapEnterCount),
                                format: .number
                            )
                            .labelsHidden()
                            .frame(width: 80)
                        }
                        LabeledContent("Recover count") {
                            TextField(
                                "Recover count",
                                value: intBinding(\.antiFlapRecoverCount),
                                format: .number
                            )
                            .labelsHidden()
                            .frame(width: 80)
                        }
                        LabeledContent("Min dwell (s)") {
                            TextField(
                                "Min dwell",
                                value: binding(\.minimumStateDwellSeconds),
                                format: .number
                            )
                            .labelsHidden()
                            .frame(width: 80)
                        }
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
        .frame(width: 520, height: 704)
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

    private func customLabelBinding() -> Binding<String> {
        Binding(
            get: { viewModel.settingsStore.config.customTarget?.label ?? "" },
            set: { newValue in
                var target = viewModel.settingsStore.config.customTarget ?? CustomPingTarget(label: "", ipAddress: "", dnsProbesEnabled: false)
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
                var target = viewModel.settingsStore.config.customTarget ?? CustomPingTarget(label: "", ipAddress: "", dnsProbesEnabled: false)
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
}
