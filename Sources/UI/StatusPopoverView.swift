import SwiftUI
import AppKit

/// NSPopover + `NSHostingController` does not always pick up new SwiftUI intrinsic height when the root subtree swaps (summary ↔ detail). Invalidate when that token changes.
private struct PopoverLayoutRefreshTrigger: NSViewRepresentable {
    var token: String

    final class Coordinator {
        var previousToken: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.isHidden = true
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.previousToken != token else { return }
        coordinator.previousToken = token
        DispatchQueue.main.async {
            var node: NSView? = nsView
            while let current = node {
                let name = NSStringFromClass(type(of: current))
                if name.contains("NSHostingView") {
                    current.invalidateIntrinsicContentSize()
                    current.layoutSubtreeIfNeeded()
                    break
                }
                node = current.superview
            }
        }
    }
}

struct StatusPopoverView: View {
    @ObservedObject var viewModel: NetworkMonitorViewModel
    @State private var selectedEndpointID: String?
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
        }
        .padding(12)
        .frame(maxWidth: 400)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            PopoverLayoutRefreshTrigger(token: selectedEndpointID ?? "__summary__")
        )
    }

    private var selectedEndpoint: EndpointStatus? {
        guard let selectedEndpointID else { return nil }
        return viewModel.endpoints.first(where: { $0.id == selectedEndpointID })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: filledHealthSystemImage(for: viewModel.snapshot.state))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(viewModel.latestStateColor(for: viewModel.snapshot.state, colorScheme: colorScheme))
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppBranding.productName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Network \(viewModel.snapshot.state.title)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Settings") {
                    SettingsWindowController.shared.show(viewModel: viewModel)
                }
            }
            if viewModel.statusBarIconReflectsLiveHealth, !dnsFootnoteLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(dnsFootnoteLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func filledHealthSystemImage(for state: NetworkHealthState) -> String {
        switch state {
        case .offline:
            return "xmark.octagon.fill"
        case .degraded:
            return "exclamationmark.triangle.fill"
        case .healthy:
            return "checkmark.circle.fill"
        case .blazing:
            return "bolt.fill"
        }
    }

    private var summaryList: some View {
        summaryListRows
    }

    @ViewBuilder
    private var summaryListRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            consolidatedLocalNetworkRow
            ForEach(wanEndpointsForSummary) { endpoint in
                Button {
                    selectedEndpointID = endpoint.id
                } label: {
                    consolidatedWanRow(endpoint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            ForEach(customEndpointsForSummary) { endpoint in
                Button {
                    selectedEndpointID = endpoint.id
                } label: {
                    consolidatedCustomRow(endpoint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gatewayEndpoint: EndpointStatus? {
        viewModel.endpoints.first(where: { $0.kind == .gateway })
    }

    private var gatewayEndpointID: String? {
        gatewayEndpoint?.id
    }

    private var wanEndpointsForSummary: [EndpointStatus] {
        let cf = viewModel.endpoints.first { $0.kind == .cloudflare }
        let gg = viewModel.endpoints.first { $0.kind == .google }
        let od = viewModel.endpoints.first { $0.kind == .openDNS }
        let l3 = viewModel.endpoints.first { $0.kind == .level3 }
        let q9 = viewModel.endpoints.first { $0.kind == .quad9 }
        return [cf, gg, od, l3, q9].compactMap { $0 }
    }

    private var customEndpointsForSummary: [EndpointStatus] {
        viewModel.endpoints.filter { $0.kind == .custom }
    }

    private var localNetworkSubtitleIP: String {
        if let ip = viewModel.context.gatewayIP, !ip.isEmpty {
            return ip
        }
        return "—"
    }

    @ViewBuilder
    private var consolidatedLocalNetworkRow: some View {
        if let gatewayID = gatewayEndpointID, let gw = gatewayEndpoint {
            Button {
                selectedEndpointID = gatewayID
            } label: {
                consolidatedRow(
                    leading: { SummaryRowLeading.localNetwork },
                    title: "Local Network",
                    subtitle: gw.host,
                    pingIcon: endpointIcon(gw),
                    pingTint: endpointColor(gw),
                    pingMsText: viewModel.meanText(for: gw),
                    dnsSymbol: primaryDNSSymbol,
                    dnsTint: primaryDNSTint,
                    showChevron: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        } else {
            consolidatedRow(
                leading: { SummaryRowLeading.localNetwork },
                title: "Local Network",
                subtitle: localNetworkSubtitleIP,
                pingIcon: viewModel.context.connected ? "checkmark.circle.fill" : "xmark.octagon.fill",
                pingTint: viewModel.context.connected ? HealthAppearance.successGreen(for: colorScheme) : .red,
                pingMsText: "—",
                dnsSymbol: primaryDNSSymbol,
                dnsTint: primaryDNSTint,
                showChevron: false
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func consolidatedWanRow(_ endpoint: EndpointStatus) -> some View {
        consolidatedRow(
            leading: {
                switch endpoint.kind {
                case .cloudflare:
                    SummaryRowLeading.cloudflare
                case .google:
                    SummaryRowLeading.google
                case .openDNS:
                    SummaryRowLeading.openDNS
                case .level3:
                    SummaryRowLeading.level3
                case .quad9:
                    SummaryRowLeading.quad9
                default:
                    SummaryRowLeading.wanRemote
                }
            },
            title: endpoint.label,
            subtitle: endpoint.host,
            pingIcon: endpointIcon(endpoint),
            pingTint: endpointColor(endpoint),
            pingMsText: viewModel.meanText(for: endpoint),
            dnsSymbol: fallbackDNSSymbol(host: endpoint.host),
            dnsTint: fallbackDNSTint(host: endpoint.host),
            showChevron: true
        )
    }

    private func consolidatedCustomRow(_ endpoint: EndpointStatus) -> some View {
        let dnsOn = viewModel.settingsStore.config.customTarget?.dnsProbesEnabled == true
        return consolidatedRow(
            leading: { SummaryRowLeading.customTarget },
            title: endpoint.label,
            subtitle: endpoint.host,
            pingIcon: endpointIcon(endpoint),
            pingTint: endpointColor(endpoint),
            pingMsText: viewModel.meanText(for: endpoint),
            dnsSymbol: dnsOn ? customDNSSymbol(host: endpoint.host) : "minus.circle.fill",
            dnsTint: dnsOn ? customDNSTint(host: endpoint.host) : .secondary,
            showChevron: true,
            dnsLabel: dnsOn ? "DNS" : "—",
            showDNSColumn: dnsOn
        )
    }

    private func consolidatedRow<L: View>(
        @ViewBuilder leading: () -> L,
        title: String,
        subtitle: String,
        pingIcon: String,
        pingTint: Color,
        pingMsText: String,
        dnsSymbol: String,
        dnsTint: Color,
        showChevron: Bool,
        dnsLabel: String = "DNS",
        showDNSColumn: Bool = true
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            leading()
                .frame(width: 34, height: 34, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showDNSColumn {
                    Image(systemName: dnsSymbol)
                        .foregroundColor(dnsTint)
                        .font(.body.weight(.medium))
                    Text(dnsLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: pingIcon)
                    .foregroundColor(pingTint)
                    .font(.body.weight(.medium))
                Text(pingMsText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var primaryDNSSymbol: String {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return "ellipsis.circle.fill" }
        guard let resolver = viewModel.context.dnsServers.first, !resolver.isEmpty else {
            return "ellipsis.circle.fill"
        }
        return dns.timedOutServers.contains(resolver) ? "xmark.circle.fill" : "checkmark.circle.fill"
    }

    private var primaryDNSTint: Color {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return .secondary }
        guard let resolver = viewModel.context.dnsServers.first, !resolver.isEmpty else { return .secondary }
        return dns.timedOutServers.contains(resolver) ? .red : HealthAppearance.successGreen(for: colorScheme)
    }

    private func fallbackDNSSymbol(host: String) -> String {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return "ellipsis.circle.fill" }
        guard let ok = dns.fallbackAnsweredByServer[host] else { return "questionmark.circle.fill" }
        return ok ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func fallbackDNSTint(host: String) -> Color {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return .secondary }
        guard let ok = dns.fallbackAnsweredByServer[host] else { return .orange }
        return ok ? HealthAppearance.successGreen(for: colorScheme) : .red
    }

    private func customDNSSymbol(host: String) -> String {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return "ellipsis.circle.fill" }
        guard let ok = dns.customNameserverProbes[host] else { return "questionmark.circle.fill" }
        return ok ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func customDNSTint(host: String) -> Color {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return .secondary }
        guard let ok = dns.customNameserverProbes[host] else { return .orange }
        return ok ? HealthAppearance.successGreen(for: colorScheme) : .red
    }

    private var dnsFootnoteLines: [String] {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return [] }
        var lines: [String] = []
        if dns.resolvedPrivateIP {
            lines.append("Probe hostname resolved to a private IP (possible captive portal).")
        }
        if dns.allConfiguredTimedOut, dns.fallbackWorked {
            lines.append("System resolver timed out; public DNS fallback probes still succeed.")
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
                    Text("Local Network")
                        .font(.headline)
                    Text("\(endpoint.host) • mean(5): \(viewModel.meanText(for: endpoint))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(endpoint.label) (\(endpoint.host))")
                        .font(.headline)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if !viewModel.dnsProbeHistoryLines.isEmpty {
                    Text("Recent DNS probes (last \(viewModel.dnsProbeHistoryLines.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(viewModel.dnsProbeHistoryLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundColor(terminalTextColor)
                            .textSelection(.enabled)
                    }
                }
                Text("Last 10 ICMP pings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, viewModel.dnsProbeHistoryLines.isEmpty ? 0 : 4)
                ForEach(Array(endpoint.last10.enumerated()), id: \.offset) { _, sample in
                    Text(sampleLine(sample))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundColor(terminalTextColor)
                        .textSelection(.enabled)
                }
                if endpoint.last10.isEmpty {
                    Text("No ICMP samples yet")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(terminalTextColor.opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
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
            return "checkmark.circle.fill"
        }
        if endpoint.latest?.timedOut == true {
            return "xmark.octagon.fill"
        }
        return "questionmark.circle.fill"
    }

    private func endpointColor(_ endpoint: EndpointStatus) -> Color {
        if endpoint.latest?.success == true {
            return HealthAppearance.successGreen(for: colorScheme)
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
            return "\(ts) ICMP reply time=\(Int(rtt.rounded()))ms"
        }
        return "\(ts) timeout \(sample.message)"
    }
}

/// Loads PNG/PDF from the asset catalog or loose resources in the app bundle.
private enum BrandMarkImageLoader {
    static func nsImage(named resourceName: String) -> NSImage? {
        if let img = NSImage(named: resourceName) {
            return img
        }
        for ext in ["png", "jpg", "jpeg", "pdf"] {
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: ext) else { continue }
            if let img = NSImage(contentsOf: url) {
                return img
            }
        }
        return nil
    }
}

private enum SummaryRowLeading {
    static var localNetwork: some View {
        Image(systemName: "rectangle.connected.to.line.below")
            .font(.system(size: 24, weight: .heavy))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
    }

    /// Asset catalog bitmap when bundled; otherwise same placeholder as early revisions (**SF Symbol** `cloud.fill`, orange).
    static var cloudflare: some View {
        Group {
            if let img = BrandMarkImageLoader.nsImage(named: "CloudflareMark") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "cloud.fill")
                    .font(.title2)
                    .foregroundStyle(Color(red: 0.96, green: 0.45, blue: 0.13))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel("Cloudflare")
    }

    /// Asset catalog bitmap when bundled; otherwise same placeholder as early revisions (**SwiftUI shapes**: four `RoundedRectangle` bars, Google-like colors).
    static var google: some View {
        Group {
            if let img = BrandMarkImageLoader.nsImage(named: "GoogleMark") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                SummaryGoogleFallbackMark()
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel("Google")
    }

    static var openDNS: some View {
        Image(systemName: "checkmark.shield.fill")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color(red: 0.0, green: 0.42, blue: 0.72), Color(red: 0.55, green: 0.78, blue: 0.95))
            .accessibilityLabel("OpenDNS")
    }

    static var level3: some View {
        Image(systemName: "arrow.triangle.swap")
            .font(.title2)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color(red: 0.42, green: 0.28, blue: 0.58))
            .accessibilityLabel("Level3")
    }

    /// Quad9-style teal shield (no bundled mark asset yet).
    static var quad9: some View {
        Image(systemName: "shield.checkered")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color(red: 0.12, green: 0.48, blue: 0.52), Color(red: 0.75, green: 0.88, blue: 0.90))
            .accessibilityLabel("Quad9")
    }

    static var wanRemote: some View {
        Image(systemName: "antenna.radiowaves.left.and.right.fill")
            .font(.title2)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
    }

    static var customTarget: some View {
        Image(systemName: "globe")
            .font(.title2)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Custom target")
    }
}

private struct SummaryGoogleFallbackMark: View {
    private static let barColors: [Color] = [
        Color(red: 0.26, green: 0.52, blue: 0.96),
        Color(red: 0.92, green: 0.26, blue: 0.21),
        Color(red: 0.98, green: 0.74, blue: 0.02),
        Color(red: 0.13, green: 0.59, blue: 0.35)
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Self.barColors[i])
                    .frame(width: 3, height: 16)
            }
        }
    }
}
