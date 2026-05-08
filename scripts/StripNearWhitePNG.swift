#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes near-white pixels transparent (for logo PNGs on white canvas).
/// Usage: swift scripts/StripNearWhitePNG.swift <path.png> [...]

func stripNearWhite(url: URL) throws {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else {
        throw NSError(domain: "StripNearWhite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read \(url.path)"])
    }

    let w = cgImage.width
    let h = cgImage.height
    let bpp = 4
    let bpr = bpp * w
    var data = [UInt8](repeating: 0, count: h * bpr)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: &data,
              width: w,
              height: h,
              bitsPerComponent: 8,
              bytesPerRow: bpr,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
        throw NSError(domain: "StripNearWhite", code: 2, userInfo: [NSLocalizedDescriptionKey: "Context failed"])
    }

    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Un-premultiply to judge original color; then write straight RGBA with new alpha.
    for y in 0..<h {
        for x in 0..<w {
            let i = y * bpr + x * bpp
            var r = Float(data[i]) / 255
            var g = Float(data[i + 1]) / 255
            var b = Float(data[i + 2]) / 255
            let aIn = max(Float(data[i + 3]) / 255, 1e-6)
            r = min(1, r / aIn)
            g = min(1, g / aIn)
            b = min(1, b / aIn)

            let mx = max(r, max(g, b))
            let mn = min(r, min(g, b))
            let chroma = mx - mn
            let luma = (r + g + b) / 3

            // White / light gray background: low chroma, high luma.
            var aOut: Float = 1
            if chroma < 0.14, luma >= 0.88 {
                // Hard cut for solid white; soft edge for anti-alias fringe.
                let u = (luma - 0.88) / 0.12 // 0 at 0.88, 1 at 1.0
                aOut = max(0, 1 - min(1, u * 1.15 + (0.14 - chroma) * 2))
            }

            let pmR = UInt8(min(255, r * aOut * 255))
            let pmG = UInt8(min(255, g * aOut * 255))
            let pmB = UInt8(min(255, b * aOut * 255))
            let pmA = UInt8(min(255, aOut * 255))
            data[i] = pmR
            data[i + 1] = pmG
            data[i + 2] = pmB
            data[i + 3] = pmA
        }
    }

    guard let outCtx = CGContext(
        data: &data,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: bpr,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ),
        let outCG = outCtx.makeImage()
    else {
        throw NSError(domain: "StripNearWhite", code: 3, userInfo: [NSLocalizedDescriptionKey: "Encode failed"])
    }

    let dest = NSMutableData()
    guard let destRef = CGImageDestinationCreateWithData(dest, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "StripNearWhite", code: 4, userInfo: [NSLocalizedDescriptionKey: "Destination failed"])
    }
    CGImageDestinationAddImage(destRef, outCG, nil)
    guard CGImageDestinationFinalize(destRef) else {
        throw NSError(domain: "StripNearWhite", code: 5, userInfo: [NSLocalizedDescriptionKey: "Finalize failed"])
    }
    try (dest as Data).write(to: url, options: .atomic)
}

let args = CommandLine.arguments.dropFirst()
guard !args.isEmpty else {
    fputs("usage: \(CommandLine.arguments[0]) <file.png> [...]\n", stderr)
    exit(1)
}

for path in args {
    let url = URL(fileURLWithPath: path)
    do {
        try stripNearWhite(url: url)
        print("OK \(path)")
    } catch {
        fputs("error \(path): \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
