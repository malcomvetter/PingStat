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
        popover.contentSize = NSSize(width: 420, height: 340)
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(viewModel: viewModel)
        )
    }

    @objc
    private func statusItemClicked(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(sender)
            showContextMenu(relativeTo: button)
        } else {
            togglePopover(sender)
        }
    }

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu(title: AppBranding.productName)

        let titleItem = NSMenuItem(
            title: AppBranding.productName,
            action: nil,
            keyEquivalent: ""
        )
        titleItem.isEnabled = false
        menu.addItem(titleItem)
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
}
