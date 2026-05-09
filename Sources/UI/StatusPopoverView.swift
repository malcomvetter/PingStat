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

    private var isShowingEndpointDetail: Bool { selectedEndpointID != nil }

    /// Extra vertical room for the detail `ScrollView` from DNS + ICMP line counts (capped so the popover still fits on screen).
    private var detailScrollMaxHeightForSelection: CGFloat? {
        guard let ep = selectedEndpoint else { return nil }
        let dnsCount = viewModel.dnsProbeLogLines(for: ep).count
        return Self.detailScrollAreaMaxHeight(dnsLineCount: dnsCount, icmpSampleCount: ep.last10.count)
    }

    private var popoverDetailContentMaxHeight: CGFloat? {
        guard let scroll = detailScrollMaxHeightForSelection else { return nil }
        return min(780, scroll + 155)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let selected = selectedEndpoint {
                endpointDetail(selected)
                detailFooterVersionRow
            } else {
                summaryList
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, isShowingEndpointDetail ? 16 : 12)
        .padding(.bottom, 16)
        .frame(maxWidth: 400)
        .fixedSize(horizontal: true, vertical: !isShowingEndpointDetail)
        .frame(maxHeight: isShowingEndpointDetail ? popoverDetailContentMaxHeight : nil, alignment: .top)
        .background(
            PopoverLayoutRefreshTrigger(token: selectedEndpointID ?? "__summary__")
        )
    }

    private var selectedEndpoint: EndpointStatus? {
        guard let selectedEndpointID else { return nil }
        return viewModel.endpoints.first(where: { $0.id == selectedEndpointID })
    }

    private var networkHealthSubtitle: String {
        let base = "Network \(viewModel.snapshot.state.title)"
        guard viewModel.lowDataModePathActive else { return base }
        return "\(base) – Low Data Mode"
    }

    /// Row is master-shown but all probes are off because Low Data Mode is active (popover shows a compact gray status).
    private func endpointFullyLDMPaused(_ endpoint: EndpointStatus) -> Bool {
        viewModel.lowDataModePathActive && !endpoint.icmpProbingActive && !endpoint.dnsProbingActive
    }

    @ViewBuilder
    private func lowDataModePausedTrailing(showChevron: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "network.slash")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Low Data Mode")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var detailFooterVersionRow: some View {
        Text("Version \(AppVersion.marketing)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: HealthAppearance.statusHealthSymbolName(
                    startupMark: !viewModel.statusBarIconReflectsLiveHealth,
                    health: viewModel.snapshot.state
                ))
                // Match `NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)` on the status item.
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(HealthAppearance.statusHealthMarkColor(
                    startupMark: !viewModel.statusBarIconReflectsLiveHealth,
                    health: viewModel.snapshot.state
                ))
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppBranding.productName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(networkHealthSubtitle)
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
                .contextMenu {
                    Button("Disable \(endpoint.label)") {
                        disableWanTarget(endpoint.kind)
                    }
                }
            }
            ForEach(customEndpointsForSummary) { endpoint in
                if endpoint.isFullyProbePaused {
                    consolidatedCustomRow(endpoint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button {
                        selectedEndpointID = endpoint.id
                    } label: {
                        consolidatedCustomRow(endpoint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            summaryFooterRow
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Local row always contributes one DNS cell (primary resolver), same as the list above.
    private var summaryPrimaryDnsIsGreen: Bool {
        guard let gw = gatewayEndpoint, gw.dnsProbingActive else { return false }
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return false }
        guard let resolver = viewModel.context.dnsServers.first, !resolver.isEmpty else { return false }
        return !dns.timedOutServers.contains(resolver)
    }

    private func summaryCustomRowShowsDNS(_ endpoint: EndpointStatus) -> Bool {
        endpoint.kind == .custom && (viewModel.settingsStore.config.customTarget?.dnsProbesEnabled == true)
    }

    private var summaryDnsGreenCount: Int {
        var n = 0
        if summaryPrimaryDnsIsGreen { n += 1 }
        for ep in wanEndpointsForSummary
            where ep.dnsProbingActive && viewModel.dnsStatus.fallbackAnsweredByServer[ep.host] == true {
            n += 1
        }
        for ep in customEndpointsForSummary {
            guard summaryCustomRowShowsDNS(ep), ep.dnsProbingActive else { continue }
            if viewModel.dnsStatus.customNameserverProbes[ep.host] == true { n += 1 }
        }
        return n
    }

    private var summaryDnsTotalCount: Int {
        var n = 0
        if gatewayEndpoint?.dnsProbingActive == true { n += 1 }
        n += wanEndpointsForSummary.filter(\.dnsProbingActive).count
        n += customEndpointsForSummary.filter { summaryCustomRowShowsDNS($0) && $0.dnsProbingActive }.count
        return n
    }

    private var summaryMeanPingAcrossActiveMs: Double? {
        var values: [Double] = []
        if let gw = gatewayEndpoint, gw.icmpProbingActive, gw.latest?.success == true, let m = gw.meanLast5Ms {
            values.append(m)
        }
        for ep in wanEndpointsForSummary {
            guard ep.icmpProbingActive, ep.latest?.success == true, let m = ep.meanLast5Ms else { continue }
            values.append(m)
        }
        for ep in customEndpointsForSummary {
            guard ep.icmpProbingActive, ep.latest?.success == true, let m = ep.meanLast5Ms else { continue }
            values.append(m)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var summaryFooterRow: some View {
        let dnsPart = summaryDnsTotalCount == 0 ? "—" : "\(summaryDnsGreenCount)/\(summaryDnsTotalCount)"
        let pingPart: String
        if let avg = summaryMeanPingAcrossActiveMs {
            pingPart = "\(Int(avg.rounded())) ms"
        } else {
            pingPart = "—"
        }
        return HStack(alignment: .center, spacing: 8) {
            Text("Version \(AppVersion.marketing)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(dnsPart)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
                Text(pingPart)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
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
        let centuryLink = viewModel.endpoints.first { $0.kind == .level3 }
        let q9 = viewModel.endpoints.first { $0.kind == .quad9 }
        return [cf, gg, od, centuryLink, q9].compactMap { $0 }
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
            let pingVisual = summaryPingVisual(for: gw)
            Button {
                selectedEndpointID = gatewayID
            } label: {
                consolidatedRow(
                    leading: { SummaryRowLeading.localNetwork },
                    title: "Local Network",
                    subtitle: gw.host,
                    pingIcon: pingVisual.icon,
                    pingTint: pingVisual.color,
                    pingMsText: summaryPingMsText(for: gw),
                    dnsSymbol: primaryDNSSymbol(gateway: gw),
                    dnsTint: primaryDNSTint(gatewayForTeal: gw),
                    showChevron: true,
                    dnsColumnActive: gw.dnsProbingActive,
                    pingColumnActive: gw.icmpProbingActive
                        || (viewModel.lowDataModePathActive && gw.dnsProbingActive),
                    showLowDataModePausedIndicator: endpointFullyLDMPaused(gw)
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
                dnsSymbol: primaryDNSSymbol(gateway: nil),
                dnsTint: primaryDNSTint(gatewayForTeal: nil),
                showChevron: false,
                dnsColumnActive: true,
                pingColumnActive: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func consolidatedWanRow(_ endpoint: EndpointStatus) -> some View {
        let pingVisual = summaryPingVisual(for: endpoint)
        return consolidatedRow(
            leading: {
                switch endpoint.kind {
                case .cloudflare:
                    SummaryRowLeading.cloudflare
                case .google:
                    SummaryRowLeading.google
                case .openDNS:
                    SummaryRowLeading.openDNS
                case .level3:
                    SummaryRowLeading.centuryLink
                case .quad9:
                    SummaryRowLeading.quad9
                default:
                    SummaryRowLeading.wanRemote
                }
            },
            title: endpoint.label,
            subtitle: endpoint.host,
            pingIcon: pingVisual.icon,
            pingTint: pingVisual.color,
            pingMsText: summaryPingMsText(for: endpoint),
            dnsSymbol: fallbackDNSSymbol(endpoint: endpoint),
            dnsTint: fallbackDNSTint(endpoint: endpoint),
            showChevron: true,
            dnsColumnActive: endpoint.dnsProbingActive,
            pingColumnActive: endpoint.icmpProbingActive,
            showLowDataModePausedIndicator: endpointFullyLDMPaused(endpoint)
        )
    }

    private func consolidatedCustomRow(_ endpoint: EndpointStatus) -> some View {
        let dnsOn = viewModel.settingsStore.config.customTarget?.dnsProbesEnabled == true
        let pingVisual = summaryPingVisual(for: endpoint)
        return consolidatedRow(
            leading: { SummaryRowLeading.customTarget },
            title: endpoint.label,
            subtitle: endpoint.host,
            pingIcon: pingVisual.icon,
            pingTint: pingVisual.color,
            pingMsText: summaryPingMsText(for: endpoint),
            dnsSymbol: dnsOn ? customDNSSymbol(endpoint: endpoint) : "minus.circle.fill",
            dnsTint: dnsOn ? customDNSTint(endpoint: endpoint) : .secondary,
            showChevron: !endpoint.isFullyProbePaused,
            dnsLabel: dnsOn ? "DNS" : "—",
            showDNSColumn: dnsOn,
            dnsColumnActive: endpoint.dnsProbingActive,
            pingColumnActive: endpoint.icmpProbingActive,
            showLowDataModePausedIndicator: endpointFullyLDMPaused(endpoint)
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
        showDNSColumn: Bool = true,
        dnsColumnActive: Bool = true,
        pingColumnActive: Bool = true,
        showLowDataModePausedIndicator: Bool = false
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
            Group {
                if showLowDataModePausedIndicator {
                    lowDataModePausedTrailing(showChevron: showChevron)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if showDNSColumn {
                            Group {
                                Image(systemName: dnsSymbol)
                                    .foregroundColor(dnsTint)
                                    .font(.body.weight(.medium))
                                Text(dnsLabel)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .opacity(dnsColumnActive ? 1 : 0.42)
                        }
                        Group {
                            Image(systemName: pingIcon)
                                .foregroundColor(pingTint)
                                .font(.body.weight(.medium))
                            Text(pingMsText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .opacity(pingColumnActive ? 1 : 0.42)
                        if showChevron {
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
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

    private func summaryPingMsText(for endpoint: EndpointStatus) -> String {
        guard endpoint.icmpProbingActive else { return "—" }
        return viewModel.meanText(for: endpoint)
    }

    private func summaryPingVisual(for endpoint: EndpointStatus) -> (icon: String, color: Color) {
        guard endpoint.icmpProbingActive else {
            if viewModel.lowDataModePathActive,
               endpoint.kind == .gateway,
               endpoint.dnsProbingActive {
                return ("network.slash", Color.secondary)
            }
            return ("minus.circle.fill", Color.secondary)
        }
        return (endpointIcon(endpoint), endpointColor(endpoint))
    }

    private func primaryDNSSymbol(gateway: EndpointStatus?) -> String {
        if let gateway, !gateway.dnsProbingActive {
            return "minus.circle.fill"
        }
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return "ellipsis.circle.fill" }
        guard let resolver = viewModel.context.dnsServers.first, !resolver.isEmpty else {
            return "ellipsis.circle.fill"
        }
        return dns.timedOutServers.contains(resolver) ? "xmark.circle.fill" : "checkmark.circle.fill"
    }

    /// Primary DNS column: teal when resolver answered and gateway ICMP mean matches blazing threshold (same rule as ``HealthEvaluator`` WAN blazing contributor).
    private func primaryDNSTint(gatewayForTeal: EndpointStatus?) -> Color {
        if let gatewayForTeal, !gatewayForTeal.dnsProbingActive {
            return .secondary
        }
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return .secondary }
        guard let resolver = viewModel.context.dnsServers.first, !resolver.isEmpty else { return .secondary }
        if dns.timedOutServers.contains(resolver) {
            return .red
        }
        if let gw = gatewayForTeal, primaryDnsAnsweredOK, gw.icmpProbingActive, pingMeanQualifiesBlazing(gw) {
            return HealthAppearance.blazingAccentColor()
        }
        return HealthAppearance.successGreen(for: colorScheme)
    }

    private var primaryDnsAnsweredOK: Bool {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return false }
        guard let resolver = viewModel.context.dnsServers.first, !resolver.isEmpty else { return false }
        return !dns.timedOutServers.contains(resolver)
    }

    private func fallbackDNSSymbol(endpoint: EndpointStatus) -> String {
        guard endpoint.dnsProbingActive else { return "minus.circle.fill" }
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return "ellipsis.circle.fill" }
        guard let ok = dns.fallbackAnsweredByServer[endpoint.host] else { return "questionmark.circle.fill" }
        return ok ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func fallbackDNSTint(endpoint: EndpointStatus) -> Color {
        guard endpoint.dnsProbingActive else { return .secondary }
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return .secondary }
        guard let ok = dns.fallbackAnsweredByServer[endpoint.host] else { return .orange }
        if ok, endpoint.icmpProbingActive, pingMeanQualifiesBlazing(endpoint) {
            return HealthAppearance.blazingAccentColor()
        }
        return ok ? HealthAppearance.successGreen(for: colorScheme) : .red
    }

    private func customDNSSymbol(endpoint: EndpointStatus) -> String {
        guard endpoint.dnsProbingActive else { return "minus.circle.fill" }
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return "ellipsis.circle.fill" }
        guard let ok = dns.customNameserverProbes[endpoint.host] else { return "questionmark.circle.fill" }
        return ok ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func customDNSTint(endpoint: EndpointStatus) -> Color {
        guard endpoint.dnsProbingActive else { return .secondary }
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return .secondary }
        guard let ok = dns.customNameserverProbes[endpoint.host] else { return .orange }
        if ok, endpoint.icmpProbingActive, pingMeanQualifiesBlazing(endpoint) {
            return HealthAppearance.blazingAccentColor()
        }
        return ok ? HealthAppearance.successGreen(for: colorScheme) : .red
    }

    /// Same inequality as ``HealthEvaluator.isBlazing(wanMeansMs:config:)`` per row: mean(5) strictly below blazing threshold.
    private func pingMeanQualifiesBlazing(_ endpoint: EndpointStatus) -> Bool {
        guard endpoint.latest?.success == true, let mean = endpoint.meanLast5Ms else { return false }
        return mean < viewModel.settingsStore.config.blazingThresholdMs
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
        if dns.systemResolverProbesSkipped {
            lines.append("Some Connection Targets are Paused (Low Data Mode)")
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

    /// Default scroll region is taller when ICMP/DNS lines exist; caps keep the popover from exceeding the window.
    private static func detailScrollAreaMaxHeight(dnsLineCount: Int, icmpSampleCount: Int) -> CGFloat {
        let hasTerminalContent = dnsLineCount > 0 || icmpSampleCount > 0
        if !hasTerminalContent {
            return 420
        }
        let estimated =
            CGFloat(dnsLineCount) * 21
            + CGFloat(icmpSampleCount) * 17
            + 180
        return min(620, max(520, estimated))
    }

    private func endpointDetail(_ endpoint: EndpointStatus) -> some View {
        let dnsLines = viewModel.dnsProbeLogLines(for: endpoint)
        let scrollMax = Self.detailScrollAreaMaxHeight(
            dnsLineCount: dnsLines.count,
            icmpSampleCount: endpoint.last10.count
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button {
                        selectedEndpointID = nil
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.bottom, 10)

                Group {
                    if endpoint.kind == .gateway {
                        Text("Local Network")
                            .font(.headline)
                        Text("\(endpoint.host) • mean(5): \(viewModel.meanText(for: endpoint))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    } else {
                        Text("\(endpoint.label) (\(endpoint.host))")
                            .font(.headline)
                    }
                }
                .padding(.bottom, 14)

                VStack(alignment: .leading, spacing: 8) {
                    if !dnsLines.isEmpty {
                        Text("Last 2 DNS Queries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(dnsLines.enumerated()), id: \.offset) { _, line in
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(line)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundColor(terminalTextColor)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Text("Last 10 ICMP pings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, dnsLines.isEmpty ? 0 : 10)
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
                .padding(10)
                .background(terminalBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Color.clear
                    .frame(height: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: scrollMax, alignment: .top)
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
            if pingMeanQualifiesBlazing(endpoint) {
                return HealthAppearance.blazingAccentColor()
            }
            let threshold = viewModel.settingsStore.config.healthyThresholdMs
            if let mean = endpoint.meanLast5Ms, mean > threshold {
                return .orange
            }
            return HealthAppearance.successGreen(for: colorScheme)
        }
        if endpoint.latest?.timedOut == true {
            return .red
        }
        return .orange
    }

    /// Matches Settings → WAN targets: turns off the toggle and drops the row after `rebuildEndpoints`.
    private func disableWanTarget(_ kind: EndpointKind) {
        if let id = Self.wanEndpointSelectionId(for: kind), selectedEndpointID == id {
            selectedEndpointID = nil
        }
        var c = viewModel.settingsStore.config
        switch kind {
        case .cloudflare:
            c.pingCloudflareEnabled = false
        case .google:
            c.pingGoogleEnabled = false
        case .openDNS:
            c.pingOpenDNSEnabled = false
        case .level3:
            c.pingLevel3Enabled = false
        case .quad9:
            c.pingQuad9Enabled = false
        case .gateway, .custom:
            return
        }
        viewModel.settingsStore.config = c
    }

    private static func wanEndpointSelectionId(for kind: EndpointKind) -> String? {
        switch kind {
        case .cloudflare: return "cloudflare"
        case .google: return "google"
        case .openDNS: return "opendns"
        case .level3: return "level3"
        case .quad9: return "quad9"
        case .gateway, .custom: return nil
        }
    }

    private static let icmpSampleTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func sampleLine(_ sample: PingSample) -> String {
        let ts = Self.icmpSampleTimeFormatter.string(from: sample.timestamp)
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

    /// Asset catalog bitmap when bundled; otherwise classic blue shield fallback.
    static var openDNS: some View {
        Group {
            if let img = BrandMarkImageLoader.nsImage(named: "OpenDNSMark") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color(red: 0.0, green: 0.42, blue: 0.72), Color(red: 0.55, green: 0.78, blue: 0.95))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel("OpenDNS")
    }

    /// Asset catalog bitmap when bundled; otherwise green SF Symbol fallback (legacy Level3 hop).
    static var centuryLink: some View {
        Group {
            if let img = BrandMarkImageLoader.nsImage(named: "CenturyLinkMark") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "arrow.triangle.swap")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color(red: 0.32, green: 0.72, blue: 0.38))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel("CenturyLink")
    }

    /// Asset catalog bitmap when bundled; otherwise teal shield fallback.
    static var quad9: some View {
        Group {
            if let img = BrandMarkImageLoader.nsImage(named: "Quad9Mark") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "shield.checkered")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        HealthAppearance.blazingAccentColor(),
                        Color(red: 0.62, green: 0.96, blue: 0.92)
                    )
            }
        }
        .frame(width: 24, height: 24)
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
