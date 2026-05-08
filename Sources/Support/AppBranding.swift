import AppKit
import Foundation
import SwiftUI

enum AppBranding {
    static let productName = "PingStat"
    static var settingsWindowTitle: String { "\(productName) Settings" }

    /// Template PDF/PNG names in `Assets.xcassets` for the menu bar extra (mark + overlay). Add images to the catalog to replace SF Symbol fallbacks.
    enum MenuBarMark {
        static let startup = "PingStatMenuStartup"
        static func healthImageName(for state: NetworkHealthState) -> String {
            switch state {
            case .blazing:
                return "PingStatMenuBlazing"
            case .healthy:
                return "PingStatMenuHealthy"
            case .degraded:
                return "PingStatMenuDegraded"
            case .offline:
                return "PingStatMenuOffline"
            }
        }
    }
}

/// Shared “healthy / success” green and blazing teal: **light and dark both use the original dark-chrome palette** (system green and vivid cyan-teal) so the UI stays bright and consistent across appearances.
enum HealthAppearance {
    static func successGreen(for _: ColorScheme) -> Color {
        .green
    }

    /// Matches ``successGreen(for:)`` for `NSMenu` / `NSImage` symbol palette colors.
    static func successGreenNSColor() -> NSColor {
        .systemGreen
    }

    /// Teal used for global ``NetworkHealthState.blazing`` and per-row “blazing-class” ping/DNS accents in the popover.
    static func blazingAccentNSColor() -> NSColor {
        NSColor(calibratedRed: 0.15, green: 0.88, blue: 0.82, alpha: 1)
    }

    static func blazingAccentColor() -> Color {
        Color(nsColor: blazingAccentNSColor())
    }

    // MARK: - Status bar / popover health mark (must stay in sync)

    /// SF Symbol for the menu bar and main popover: always `cellularbars`. Live menu bar tint uses palette colors in ``StatusItemController``; startup uses a **template** image there. Popover tint uses ``statusHealthMarkNSColor`` / ``statusHealthMarkColor``.
    static func statusHealthSymbolName(startupMark _: Bool, health _: NetworkHealthState) -> String {
        "cellularbars"
    }

    /// Single palette color for ``statusHealthSymbolName(startupMark:health:)`` — same logic as the status item image.
    static func statusHealthMarkNSColor(startupMark: Bool, health: NetworkHealthState) -> NSColor {
        if startupMark {
            // Popover header while stabilizing; menu bar uses a template symbol (``StatusItemController``).
            return .labelColor
        }
        switch health {
        case .offline:
            return .systemRed
        case .degraded:
            return .systemOrange
        case .healthy:
            return successGreenNSColor()
        case .blazing:
            return blazingAccentNSColor()
        }
    }

    /// SwiftUI tint matching ``statusHealthMarkNSColor(startupMark:health:)``.
    static func statusHealthMarkColor(startupMark: Bool, health: NetworkHealthState) -> Color {
        Color(nsColor: statusHealthMarkNSColor(startupMark: startupMark, health: health))
    }
}
