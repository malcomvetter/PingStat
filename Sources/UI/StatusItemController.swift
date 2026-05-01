import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController: NSObject {
    private let viewModel: NetworkMonitorViewModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: NetworkMonitorViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()
    }

    func setup() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusIcon(for: viewModel.snapshot.state)
        viewModel.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.updateStatusIcon(for: snapshot.state)
            }
            .store(in: &cancellables)

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 400)
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(viewModel: viewModel)
        )
    }

    @objc
    private func statusItemClicked(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        let controlLeft = event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true
        if event?.type == .rightMouseUp || controlLeft {
            popover.performClose(sender)
            showContextMenu(relativeTo: button)
        } else {
            togglePopover(sender)
        }
    }

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu(title: AppBranding.productName)

        let headerItem = NSMenuItem(
            title: AppBranding.productName,
            action: nil,
            keyEquivalent: ""
        )
        headerItem.isEnabled = false
        if #available(macOS 14.4, *) {
            headerItem.subtitle = "Network \(viewModel.snapshot.state.title)"
        }
        menu.addItem(headerItem)
        if #unavailable(macOS 14.4) {
            let stateItem = NSMenuItem(
                title: "Network \(viewModel.snapshot.state.title)",
                action: nil,
                keyEquivalent: ""
            )
            stateItem.isEnabled = false
            menu.addItem(stateItem)
        }
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "Quit \(AppBranding.productName)",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.addItem(.separator())
        addDNSStatusItems(to: menu)

        let origin = NSPoint(x: button.bounds.midX, y: button.bounds.minY)
        menu.popUp(positioning: nil, at: origin, in: button)
    }

    @objc
    private func openSettings() {
        SettingsWindowController.shared.show(viewModel: viewModel)
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusIcon(for state: NetworkHealthState) {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: state.systemImageName, accessibilityDescription: state.title)
        image?.isTemplate = true
        button.image = image
        button.toolTip = "\(AppBranding.productName): \(state.title)"
    }

    private func addDNSStatusItems(to menu: NSMenu) {
        let heading = NSMenuItem(title: "DNS status", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        let primary = primaryDNSRow()
        addStatusMenuRow(to: menu, title: "Primary DNS", detail: primary.detail, state: primary.state)

        for kind in [EndpointKind.cloudflare, EndpointKind.google] {
            guard let ep = viewModel.endpoints.first(where: { $0.kind == kind }) else { continue }
            let row = resolverWANMenuRow(ep, compact: true)
            addStatusMenuRow(to: menu, title: ep.label, detail: row.detail, state: row.state)
        }

        if let note = dnsSituationNotesSingleLine(maxCharacters: 72) {
            let noteItem = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            noteItem.isEnabled = false
            menu.addItem(noteItem)
        }
    }

    /// Explanations when DNS probes explain degraded/offline behavior (status bar menus often omit `subtitle`).
    private func dnsSituationNotes() -> [String] {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return [] }

        var lines: [String] = []
        if dns.resolvedPrivateIP {
            lines.append("Why: probe hostname resolved to a private IP (captive / filtered response).")
        }
        if dns.allConfiguredTimedOut, dns.fallbackWorked {
            lines.append("Why: system resolver did not answer; Cloudflare/Google DNS probes still work.")
        }
        if dns.allConfiguredTimedOut, !dns.fallbackWorked, !dns.configuredServers.isEmpty {
            lines.append("Why: no DNS server answered the probe (offline or blocked).")
        }
        if let resolver = viewModel.context.dnsServers.first, !resolver.isEmpty,
           dns.timedOutServers.contains(resolver),
           !lines.contains(where: { $0.contains("system resolver") }) {
            lines.append("Why: \(resolver) did not respond to the DNS probe.")
        }

        let reason = viewModel.snapshot.reason
        let state = viewModel.snapshot.state
        if state == .degraded || state == .offline {
            let mentionsDNS =
                reason.localizedCaseInsensitiveContains("dns")
                || reason.localizedCaseInsensitiveContains("captive")
                || reason.localizedCaseInsensitiveContains("resolver")
            if mentionsDNS, lines.isEmpty {
                lines.append("Health: \(reason)")
            }
        }

        return lines
    }

    private func primaryDNSRow() -> (detail: String, state: StatusMenuRowState) {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else {
            return ("Waiting for first check…", .pending)
        }
        guard let resolver = viewModel.context.dnsServers.first, !resolver.isEmpty else {
            return ("Automatic / encrypted (no resolver IPs)", .pending)
        }
        if dns.timedOutServers.contains(resolver) {
            return ("\(resolver) · No answer", .bad)
        }
        return ("\(resolver) · OK", .good)
    }

    /// WAN row for the menu. `compact` uses shorter ICMP text so the menu stays short (fewer wrapped lines / less vertical scroll).
    private func resolverWANMenuRow(_ ep: EndpointStatus, compact: Bool = false) -> (detail: String, state: StatusMenuRowState) {
        let dnsPart = dnsProbeLabel(for: ep.host)
        let icmpState = icmpEndpointState(ep)
        let icmpPart: String
        switch icmpState {
        case .good:
            if compact {
                icmpPart = viewModel.meanText(for: ep).replacingOccurrences(of: " ", with: "")
            } else {
                icmpPart = "ICMP mean(5): \(viewModel.meanText(for: ep))"
            }
        case .bad:
            icmpPart = compact
                ? (ep.latest?.timedOut == true ? "timeout" : "fail")
                : (ep.latest?.timedOut == true ? "ICMP timeout" : "ICMP \(ep.latest?.message ?? "fail")")
        case .pending:
            icmpPart = compact ? "…" : "ICMP …"
        }
        let detail = "\(ep.host) · \(dnsPart) · \(icmpPart)"
        return (detail, icmpState)
    }

    /// Joins DNS situation notes into one line, clipped so menu rows stay single-line where possible.
    private func dnsSituationNotesSingleLine(maxCharacters: Int) -> String? {
        let parts = dnsSituationNotes()
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " ")
        let prefix = "Note: "
        let full = prefix + joined
        guard full.count > maxCharacters else { return full }
        let ellipsis = "…"
        let budget = max(8, maxCharacters - ellipsis.count)
        return String(full.prefix(budget)) + ellipsis
    }

    private func dnsProbeLabel(for host: String) -> String {
        let dns = viewModel.dnsStatus
        guard dns.lastCheck != nil else { return "DNS …" }
        if let answered = dns.fallbackAnsweredByServer[host] {
            return answered ? "DNS OK" : "DNS no answer"
        }
        return "DNS —"
    }

    private func icmpEndpointState(_ ep: EndpointStatus) -> StatusMenuRowState {
        guard let latest = ep.latest else { return .pending }
        if latest.success { return .good }
        if latest.timedOut { return .bad }
        return .bad
    }

    private func addStatusMenuRow(to menu: NSMenu, title: String, detail: String, state: StatusMenuRowState) {
        // Use a single `title` string: NSStatusItem context menus often do not show `subtitle` reliably.
        let full = "\(title): \(detail)"
        let clipped = Self.clipMenuRowTitle(full, maxCharacters: 64)
        let item = NSMenuItem(title: clipped, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let base = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: nil) {
            if #available(macOS 12.0, *) {
                let config = NSImage.SymbolConfiguration(paletteColors: [state.tintColor])
                item.image = base.withSymbolConfiguration(config) ?? base
            } else {
                item.image = base
                item.image?.isTemplate = true
            }
        }
        menu.addItem(item)
    }

    private static func clipMenuRowTitle(_ full: String, maxCharacters: Int) -> String {
        guard full.count > maxCharacters else { return full }
        let ellipsis = "…"
        let budget = max(12, maxCharacters - ellipsis.count)
        return String(full.prefix(budget)) + ellipsis
    }

    private enum StatusMenuRowState {
        case good
        case bad
        case pending

        var symbolName: String {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .bad: return "xmark.circle.fill"
            case .pending: return "ellipsis.circle"
            }
        }

        var tintColor: NSColor {
            switch self {
            case .good: return .systemGreen
            case .bad: return .systemRed
            case .pending: return .secondaryLabelColor
            }
        }
    }
}
