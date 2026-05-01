import SwiftUI
import AppKit

struct StatusPopoverView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel
    @State private var selectedEndpointID: String?
    @State private var exportMessage: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let selected = selectedEndpoint {
                endpointDetail(selected)
            } else {
                summaryList
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 420, height: 400)
    }

    private var selectedEndpoint: EndpointStatus? {
        guard let selectedEndpointID else { return nil }
        return viewModel.endpoints.first(where: { $0.id == selectedEndpointID })
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppBranding.productName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: viewModel.snapshot.state.systemImageName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(viewModel.latestStateColor(for: viewModel.snapshot.state))
                    Text("Network \(viewModel.snapshot.state.title)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if !dnsFootnoteLines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(dnsFootnoteLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
            Button("Settings") {
                SettingsWindowController.shared.show(viewModel: viewModel)
            }
        }
    }

    private var summaryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                interfaceRowView
                ForEach(summaryEndpointsExcludingGatewayIfLinked) { endpoint in
                    Button {
                        selectedEndpointID = endpoint.id
                    } label: {
                        endpointRow(endpoint)
                    }
                    .buttonStyle(.plain)
                }
                dnsStatusSection
                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Export Debug") {
                        Task { await exportDebug() }
                    }
                }
            }
        }
        .frame(maxHeight: 300)
    }

    private var gatewayEndpoint: EndpointStatus? {
        viewModel.endpoints.first(where: { $0.kind == .gateway })
    }

    private var gatewayEndpointID: String? {
        gatewayEndpoint?.id
    }

    /// Gateway ping history opens from Primary Interface; avoid duplicating a second Gateway row.
    private var summaryEndpointsExcludingGatewayIfLinked: [EndpointStatus] {
        if gatewayEndpointID != nil {
            return viewModel.endpoints.filter { $0.kind != .gateway }
        }
        return viewModel.endpoints
    }

    @ViewBuilder
    private var interfaceRowView: some View {
        if let gatewayID = gatewayEndpointID {
            Button {
                selectedEndpointID = gatewayID
            } label: {
                interfaceRowContent(showChevron: true, gateway: gatewayEndpoint)
            }
            .buttonStyle(.plain)
        } else {
            interfaceRowContent(showChevron: false, gateway: nil)
        }
    }

    private func interfaceRowContent(showChevron: Bool, gateway: EndpointStatus?) -> some View {
        let rowBackground = (gateway != nil ? 0.2 : 0.3)
        return HStack(spacing: 10) {
            if let gw = gateway {
                Image(systemName: endpointIcon(gw))
                    .foregroundColor(endpointColor(gw))
            } else {
                let connected = viewModel.context.connected
                Image(systemName: connected ? "checkmark.circle.fill" : "stop.circle.fill")
                    .foregroundColor(connected ? .green : .red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Primary Interface")
                    .font(.body.weight(.semibold))
                Text(interfaceSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let gw = gateway {
                    Text("\(gw.host) • mean(5): \(viewModel.meanText(for: gw))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showChevron {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(rowBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var dnsStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DNS status")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            dnsStatusLine(
                title: "Primary DNS",
                detail: primaryDNSDetail,
                symbol: primaryDNSSymbol,
                tint: primaryDNSTint
            )
            dnsStatusLine(
                title: "Cloudflare",
                detail: fallbackDNSDetail(host: "1.1.1.1"),
                symbol: fallbackDNSSymbol(host: "1.1.1.1"),
                tint: fallbackDNSTint(host: "1.1.1.1")
            )
            dnsStatusLine(
                title: "Google",
                detail: fallbackDNSDetail(host: "8.8.8.8"),
                symbol: fallbackDNSSymbol(host: "8.8.8.8"),
                tint: fallbackDNSTint(host: "8.8.8.8")
            )
        }
    }

    private func dnsStatusLine(title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundColor(tint)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var primaryDNSDetail: String {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else {
            return "Waiting for first probe…"
        }
        guard let resolver = viewModel.context.dnsServers.first, !resolver.isEmpty else {
            return "Automatic (DHCP / encrypted DNS — no resolver IPs in system list)"
        }
        if dns.timedOutServers.contains(resolver) {
            return "\(resolver) · no answer"
        }
        return "\(resolver) · OK"
    }

    private var primaryDNSSymbol: String {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return "ellipsis.circle" }
        guard let resolver = viewModel.context.dnsServers.first, !resolver.isEmpty else {
            return "ellipsis.circle"
        }
        return dns.timedOutServers.contains(resolver) ? "xmark.circle.fill" : "checkmark.circle.fill"
    }

    private var primaryDNSTint: Color {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return .secondary }
        guard let resolver = viewModel.context.dnsServers.first, !resolver.isEmpty else { return .secondary }
        return dns.timedOutServers.contains(resolver) ? .red : .green
    }

    private func fallbackDNSDetail(host: String) -> String {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return "\(host) · …" }
        if let ok = dns.fallbackAnsweredByServer[host] {
            return ok ? "\(host) · DNS probe OK" : "\(host) · DNS probe no answer"
        }
        return "\(host) · —"
    }

    private func fallbackDNSSymbol(host: String) -> String {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return "ellipsis.circle" }
        guard let ok = dns.fallbackAnsweredByServer[host] else { return "questionmark.circle" }
        return ok ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func fallbackDNSTint(host: String) -> Color {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return .secondary }
        guard let ok = dns.fallbackAnsweredByServer[host] else { return .orange }
        return ok ? .green : .red
    }

    private var dnsFootnoteLines: [String] {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return [] }
        var lines: [String] = []
        if dns.resolvedPrivateIP {
            lines.append("Probe hostname resolved to a private IP (possible captive portal).")
        }
        if dns.allConfiguredTimedOut, dns.fallbackWorked {
            lines.append("System resolver timed out; Cloudflare/Google DNS probes still succeed.")
        }
        if dns.allConfiguredTimedOut, !dns.fallbackWorked, !dns.configuredServers.isEmpty {
            lines.append("All configured DNS servers and fallbacks failed the probe.")
        }
        let reason = viewModel.snapshot.reason
        let state = viewModel.snapshot.state
        if (state == .degraded || state == .offline), lines.isEmpty,
           reason.localizedCaseInsensitiveContains("dns")
            || reason.localizedCaseInsensitiveContains("captive")
            || reason.localizedCaseInsensitiveContains("resolver") {
            lines.append(reason)
        }
        return lines
    }

    private var interfaceSubtitle: String {
        let name = viewModel.context.interfaceName ?? "Unknown"
        let type = viewModel.context.interfaceType ?? "Unknown"
        let ipPart: String
        if let ip = viewModel.context.localIP, !ip.isEmpty {
            ipPart = ip
        } else if viewModel.context.interfaceName != nil {
            ipPart = "No IPv4"
        } else {
            ipPart = "—"
        }
        return "\(name) (\(type)) • \(ipPart)"
    }

    private func endpointRow(_ endpoint: EndpointStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: endpointIcon(endpoint))
                .foregroundColor(endpointColor(endpoint))
            VStack(alignment: .leading) {
                Text(endpoint.label)
                    .font(.body.weight(.semibold))
                Text("\(endpoint.host) • mean(5): \(viewModel.meanText(for: endpoint))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func endpointDetail(_ endpoint: EndpointStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    selectedEndpointID = nil
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
            }

            Group {
                if endpoint.kind == .gateway {
                    Text("Primary Interface")
                        .font(.headline)
                    Text("Gateway \(endpoint.host)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(endpoint.label) (\(endpoint.host))")
                        .font(.headline)
                }
            }
            Text("Last 10 pings")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(endpoint.last10.enumerated()), id: \.offset) { _, sample in
                        Text(sampleLine(sample))
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundColor(terminalTextColor)
                    }
                    if endpoint.last10.isEmpty {
                        Text("No samples yet")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(terminalTextColor.opacity(0.75))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(terminalBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var terminalBackgroundColor: Color {
        colorScheme == .dark ? .black : Color(nsColor: .textBackgroundColor)
    }

    private var terminalTextColor: Color {
        colorScheme == .dark ? .green : .black
    }

    private func endpointIcon(_ endpoint: EndpointStatus) -> String {
        if endpoint.latest?.success == true {
            return "checkmark.circle"
        }
        if endpoint.latest?.timedOut == true {
            return "xmark.octagon"
        }
        return "questionmark.circle"
    }

    private func endpointColor(_ endpoint: EndpointStatus) -> Color {
        if endpoint.latest?.success == true {
            return .green
        }
        if endpoint.latest?.timedOut == true {
            return .red
        }
        return .orange
    }

    private func sampleLine(_ sample: PingSample) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: sample.timestamp)
        if sample.success, let rtt = sample.rttMs {
            return "\(ts) reply time=\(Int(rtt.rounded()))ms"
        }
        return "\(ts) timeout \(sample.message)"
    }

    private func exportDebug() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        let result = panel.runModal()
        guard result == .OK, let directory = panel.url else {
            exportMessage = "Export canceled."
            return
        }

        do {
            let fileURL = try await viewModel.exportDebugData(to: directory)
            exportMessage = "Exported to \(fileURL.lastPathComponent)"
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
