#!/usr/bin/env swift
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Run from repo root: `swift scripts/GenerateMenuBarMarks.swift`
/// Composites `AppIcon.appiconset/icon_128x128@2x.png` with SF Symbol overlays into template-friendly PNGs.

enum MarkKind: String, CaseIterable {
    case startup
    case blazing
    case healthy
    case degraded
    case offline

    var overlaySymbolName: String? {
        "cellularbars"
    }

    var assetBaseName: String {
        switch self {
        case .startup:
            return "PingStatMenuStartup"
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

func main() throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let baseIcon = cwd
        .appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png")
    guard FileManager.default.fileExists(atPath: baseIcon.path) else {
        fputs("Missing base icon at \(baseIcon.path)\n", stderr)
        exit(1)
    }
    guard let baseNS = NSImage(contentsOf: baseIcon) else {
        fputs("Could not load base icon.\n", stderr)
        exit(1)
    }

    let assetsRoot = cwd.appendingPathComponent("Assets.xcassets")
    let ctx = CIContext(options: [.useSoftwareRenderer: false])

    for kind in MarkKind.allCases {
        let folder = assetsRoot.appendingPathComponent("\(kind.assetBaseName).imageset")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let png1x = try render(kind: kind, pixelSize: 22, baseNS: baseNS, ciContext: ctx)
        let png2x = try render(kind: kind, pixelSize: 44, baseNS: baseNS, ciContext: ctx)
        try png1x.write(to: folder.appendingPathComponent("\(kind.assetBaseName).png"))
        try png2x.write(to: folder.appendingPathComponent("\(kind.assetBaseName)@2x.png"))

        let contents: [String: Any] = [
            "images": [
                ["filename": "\(kind.assetBaseName).png", "idiom": "universal", "scale": "1x"],
                ["filename": "\(kind.assetBaseName)@2x.png", "idiom": "universal", "scale": "2x"],
                ["idiom": "universal", "scale": "3x"]
            ],
            "info": ["author": "xcode", "version": 1],
            "properties": ["template-rendering-intent": "template"]
        ]
        let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("Contents.json"))
        print("Wrote \(folder.path)")
    }
}

func render(kind: MarkKind, pixelSize: Int, baseNS: NSImage, ciContext: CIContext) throws -> Data {
    let size = NSSize(width: CGFloat(pixelSize), height: CGFloat(pixelSize))
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    NSColor.clear.set()
    NSRect(origin: .zero, size: size).fill()

    let monoLogo = monochromeLogo(baseNS, context: ciContext) ?? baseNS
    let logoInset = CGFloat(pixelSize) * 0.06
    let reserveBadge: CGFloat = kind.overlaySymbolName == nil ? 0 : CGFloat(pixelSize) * 0.14
    let logoRect = NSRect(
        x: logoInset,
        y: logoInset,
        width: CGFloat(pixelSize) - logoInset * 2 - reserveBadge,
        height: CGFloat(pixelSize) - logoInset * 2
    )
    NSGraphicsContext.current?.imageInterpolation = .high
    monoLogo.draw(
        in: logoRect,
        from: NSRect(origin: .zero, size: monoLogo.size),
        operation: .sourceOver,
        fraction: 1
    )

    if let symbolName = kind.overlaySymbolName {
        let pointSize = CGFloat(pixelSize) * 0.42
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
           let tinted = sym.withSymbolConfiguration(cfg) {
            let symSize = tinted.size
            let pad = CGFloat(pixelSize) * 0.04
            let symRect = NSRect(
                x: CGFloat(pixelSize) - symSize.width - pad,
                y: pad,
                width: symSize.width,
                height: symSize.height
            )
            NSColor.black.set()
            tinted.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateMenuBarMarks", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    return png
}

func monochromeLogo(_ image: NSImage, context: CIContext) -> NSImage? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let cgSrc = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let ci = CIImage(cgImage: cgSrc)
    let mono = CIFilter.photoEffectMono()
    mono.inputImage = ci
    guard let output = mono.outputImage else { return nil }
    guard let cg = context.createCGImage(output, from: output.extent.integral) else { return nil }
    return NSImage(cgImage: cg, size: image.size)
}

do {
    try main()
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
