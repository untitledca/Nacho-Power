import AppKit

@main
struct DockStatusChecks {
    static func main() throws {
        let now = Date()
        func reading(_ battery: Double?, ac: Bool?, age: TimeInterval = 0) -> PowerTelemetry {
            PowerTelemetry(deviceName: "Test DELTA", batteryPercentage: battery,
                           acInputWatts: 0, totalInputWatts: 500, acConnected: ac,
                           sourceDescription: "Fixture", timestamp: now.addingTimeInterval(-age))
        }
        func status(_ battery: Double?, ac: Bool?, age: TimeInterval = 0, connected: Bool = true) -> DockPowerStatus {
            DockPowerStatus(telemetry: reading(battery, ac: ac, age: age), isConnected: connected, now: now)
        }
        precondition(status(99.6, ac: true).percentageText == "100%")
        precondition(status(0, ac: false).percentageText == "0%")
        precondition(status(78, ac: true).acState == .connected, "AC remains green at zero AC watts")
        precondition(status(78, ac: false).acState == .disconnected, "Positive solar/DC watts cannot make the Dock green")
        precondition(status(78, ac: nil).acState == .unknown, "Missing AC state cannot imply an outage")
        for battery in [Double.nan, .infinity, -1, 101] {
            precondition(status(battery, ac: true).percentageText == "—", "Invalid battery cannot become a percentage")
        }
        for unavailable in [status(78, ac: false, connected: false),
                            status(78, ac: true, age: DockPowerStatus.maximumReadingAge),
                            DockPowerStatus(telemetry: nil, isConnected: true, now: now)] {
            precondition(unavailable.percentageText == "—" && unavailable.acState == .unknown,
                         "Disconnected or stale telemetry must show gray/unknown")
        }
        precondition(status(78, ac: true, age: 29).acState == .connected)

        let mixedTitle = DockStatusIcon.menuBarTitle(for: status(87, ac: true), second: status(42, ac: false))
        precondition(mixedTitle.string == " 87% · 42%", "Each station keeps its own percentage in order")
        let secondRange = (mixedTitle.string as NSString).range(of: "42%")
        precondition((mixedTitle.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor) == DockStatusIcon.color(for: .connected))
        precondition((mixedTitle.attribute(.foregroundColor, at: secondRange.location, effectiveRange: nil) as? NSColor) == DockStatusIcon.color(for: .disconnected), "One green station cannot recolor a red station")
        let unknownTitle = DockStatusIcon.menuBarTitle(for: status(87, ac: true), second: status(nil, ac: nil))
        precondition(unknownTitle.string == " 87% · —")
        precondition((unknownTitle.attribute(.foregroundColor, at: unknownTitle.length - 1, effectiveRange: nil) as? NSColor) == DockStatusIcon.color(for: .unknown))
        precondition(DockStatusIcon.menuBarTitle(for: status(87, ac: true), second: nil).string == " 87%")

        if let previewPath = CommandLine.arguments.dropFirst().first {
            let folder = URL(fileURLWithPath: previewPath, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let logo = NSImage(contentsOfFile: "Resources/NachoPowerLogo.png")
            let previews = [("ac-connected", status(78, ac: true)),
                            ("ac-disconnected", status(78, ac: false)),
                            ("unavailable", status(nil, ac: nil)),
                            ("full-battery", status(100, ac: true))]
            let mixed = DockStatusIcon.image(for: status(87, ac: true), second: status(42, ac: false), logo: logo)
            precondition(mixed.size == NSSize(width: 512, height: 512))
            for size in [512, 64, 48] {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSGraphicsContext.current?.imageInterpolation = .high
                mixed.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
                NSGraphicsContext.restoreGraphicsState()
                try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("two-stations-\(size).png"))
            }
            for (name, value) in previews {
                let menuImage = DockStatusIcon.menuBarImage(for: value)
                if let data = menuImage.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: data),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: folder.appendingPathComponent("menu-\(name).png"))
                }
                for size in [512, 64, 48] {
                    let image = DockStatusIcon.image(for: value, logo: logo)
                    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                                        bitsPerPixel: 0),
                          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                        fatalError("Could not render Dock preview")
                    }
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    context.imageInterpolation = .high
                    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
                    NSGraphicsContext.restoreGraphicsState()
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        fatalError("Could not encode Dock preview")
                    }
                    let suffix = size == 512 ? "" : "-\(size)"
                    try png.write(to: folder.appendingPathComponent("\(name)\(suffix).png"))
                }
            }
        }
        print("Dock status checks passed")
    }
}
