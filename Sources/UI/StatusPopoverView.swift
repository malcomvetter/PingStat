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
        .frame(width: 420, height: 340)
    }

    private var selectedEndpoint: EndpointStatus? {
        guard let selectedEndpointID else { return nil }
        return viewModel.endpoints.first(where: { $0.id == selectedEndpointID })
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppBranding.productName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Label(
                    "Network \(viewModel.snapshot.state.title)",
                    systemImage: viewModel.snapshot.state.systemImageName
                )
                .foregroundColor(viewModel.latestStateColor(for: viewModel.snapshot.state))
            }
            Spacer()
            Button("Settings") {
                SettingsWindowController.shared.show(viewModel: viewModel)
            }
        }
    }

    private var summaryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            interfaceRow
            ForEach(viewModel.endpoints) { endpoint in
                Button {
                    selectedEndpointID = endpoint.id
                } label: {
                    endpointRow(endpoint)
                }
                .buttonStyle(.plain)
            }
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

    private var interfaceRow: some View {
        HStack {
            let connected = viewModel.context.connected
            Image(systemName: connected ? "checkmark.circle.fill" : "stop.circle.fill")
                .foregroundColor(connected ? .green : .red)
            VStack(alignment: .leading) {
                Text("Primary Interface")
                    .font(.headline)
                Text(interfaceSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

            Text("\(endpoint.label) (\(endpoint.host))")
                .font(.headline)
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
        return .yellow
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
