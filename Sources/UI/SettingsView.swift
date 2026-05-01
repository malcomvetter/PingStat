import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppBranding.productName)
                .font(.title2.weight(.semibold))

            Form {
            Section("Intervals") {
                LabeledContent("Ping interval (s)") {
                    TextField(
                        "Ping interval",
                        value: binding(\.pingIntervalSeconds),
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 80)
                }
                LabeledContent("DNS interval (s)") {
                    TextField(
                        "DNS interval",
                        value: binding(\.dnsIntervalSeconds),
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 80)
                }
                LabeledContent("Timeout (ms)") {
                    TextField(
                        "Timeout",
                        value: intBinding(\.pingTimeoutMs),
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 80)
                }
            }

            Section("Thresholds") {
                LabeledContent("Degraded if WAN mean >") {
                    TextField(
                        "Degraded threshold",
                        value: binding(\.degradedThresholdMs),
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 80)
                }
                LabeledContent("Healthy if WAN mean <=") {
                    TextField(
                        "Healthy threshold",
                        value: binding(\.healthyThresholdMs),
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 80)
                }
                LabeledContent("Blazing gateway <") {
                    TextField(
                        "Blazing gateway",
                        value: binding(\.blazingGatewayThresholdMs),
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 80)
                }
                LabeledContent("Blazing WAN <") {
                    TextField(
                        "Blazing WAN",
                        value: binding(\.blazingWanThresholdMs),
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 80)
                }
            }

            Section("Anti-flap and notifications") {
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
                LabeledContent("Notification cooldown (s)") {
                    TextField(
                        "Cooldown",
                        value: binding(\.notificationCooldownSeconds),
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 80)
                }
            }

            Section("Alert banners") {
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

            Section("Custom target") {
                TextField("Label", text: customLabelBinding())
                TextField("IP Address", text: customIPBinding())
                Button("Clear custom target") {
                    viewModel.settingsStore.config.customTarget = nil
                }
            }

            Section("Behavior") {
                Toggle("Launch at login", isOn: binding(\.launchAtLoginEnabled))
                Toggle("Enable debug logging", isOn: binding(\.debugLoggingEnabled))
            }

            Button("Reset defaults") {
                viewModel.settingsStore.resetDefaults()
            }
            }
            .formStyle(.grouped)
        }
        .padding(12)
        .frame(width: 520, height: 520)
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
                var target = viewModel.settingsStore.config.customTarget ?? CustomPingTarget(label: "", ipAddress: "")
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
                var target = viewModel.settingsStore.config.customTarget ?? CustomPingTarget(label: "", ipAddress: "")
                target.ipAddress = newValue
                if target.label.isEmpty && target.ipAddress.isEmpty {
                    viewModel.settingsStore.config.customTarget = nil
                } else {
                    viewModel.settingsStore.config.customTarget = target
                }
            }
        )
    }
}
