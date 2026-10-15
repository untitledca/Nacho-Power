import AppKit
import Foundation
import Darwin

// Package the generated logo as a complete macOS icon family.
// Usage: swift tools/make-app-icon.swift [project-directory]
let projectDirectory = CommandLine.arguments.dropFirst().first.map {
    URL(fileURLWithPath: $0, isDirectory: true)
} ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let iconsetDirectory = projectDirectory.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
let resourceDirectory = projectDirectory.appendingPathComponent("Resources", isDirectory: true)
let iconURL = resourceDirectory.appendingPathComponent("AppIcon.icns")
let logoURL = resourceDirectory.appendingPathComponent("NachoPowerLogo.png")

func renderIcon(pixels: Int, image: NSImage) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                       pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "EcoFlowCat.Icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Unable to create the app icon."])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    graphics.imageInterpolation = .high
    let side = CGFloat(pixels)
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
               from: .zero, operation: .sourceOver, fraction: 1,
               respectFlipped: false, hints: nil)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "EcoFlowCat.Icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Unable to encode the app icon."])
    }
    return png
}

do {
    guard let logo = NSImage(contentsOf: logoURL) else {
        throw NSError(domain: "EcoFlowCat.Icon", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Missing NachoPowerLogo.png."])
    }
    try FileManager.default.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            let pngURL = iconsetDirectory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
            try renderIcon(pixels: size * scale, image: logo).write(to: pngURL, options: .atomic)
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetDirectory.path, "-o", iconURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "EcoFlowCat.Icon", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "iconutil could not package the app icon."])
    }
    print("Created \(iconURL.path)")
} catch {
    fputs("Icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
