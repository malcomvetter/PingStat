#!/usr/bin/env swift
import AppKit
import Foundation

/// Renders PingStat.app icons: black canvas, centered ``cellularbars`` SF Symbol in blazing teal
/// (same as ``HealthAppearance.blazingAccentNSColor()``). No wordmark.
///
/// Run from repo root: `swift scripts/GenerateAppIcon.swift`
/// Writes `Design/PingStat-app-icon-master.png` and all entries in `Assets.xcassets/AppIcon.appiconset/`.

func blazingTeal() -> NSColor {
    // Match `HealthAppearance.blazingAccentNSColor()` (single profile for all appearances).
    NSColor(calibratedRed: 0.15, green: 0.88, blue: 0.82, alpha: 1)
}

func renderMaster(side: CGFloat) -> NSImage {
    let teal = blazingTeal()
    let size = NSSize(width: side, height: side)
    return NSImage(size: size, flipped: false) { rect in
        NSColor.black.setFill()
        rect.fill()

        let s = min(rect.width, rect.height)
        let margin = s * 0.06
        let inner = min(rect.width - 2 * margin, rect.height - 2 * margin)
        // Single centered glyph; scale to fit inside margins (matches prior max ~58% of width feel).
        let pointSize = inner * 0.58
        let symCfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [teal]))
        guard let raw = NSImage(systemSymbolName: "cellularbars", accessibilityDescription: nil),
              let symbol = raw.withSymbolConfiguration(symCfg) else {
            return false
        }
        let symSize = symbol.size
        let symX = rect.midX - symSize.width / 2
        let symY = rect.midY - symSize.height / 2
        symbol.draw(
            in: NSRect(x: symX, y: symY, width: symSize.width, height: symSize.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        return true
    }
}

func pngData(from image: NSImage, pixelSide: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSide,
        pixelsHigh: pixelSide,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "GenerateAppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "bitmap rep"])
    }
    rep.size = NSSize(width: pixelSide, height: pixelSide)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSide, height: pixelSide),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1
    )
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateAppIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encode"])
    }
    return data
}

func main() throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let dest = cwd.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
    let designDir = cwd.appendingPathComponent("Design")
    try FileManager.default.createDirectory(at: designDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

    let masterSide: CGFloat = 1024
    let master = renderMaster(side: masterSide)
    let masterURL = designDir.appendingPathComponent("PingStat-app-icon-master.png")
    try pngData(from: master, pixelSide: 1024).write(to: masterURL)

    let exports: [(name: String, px: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for item in exports {
        let url = dest.appendingPathComponent(item.name)
        try pngData(from: master, pixelSide: item.px).write(to: url)
        print(url.path)
    }
    print("Wrote master \(masterURL.path)")
}

do {
    try main()
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
