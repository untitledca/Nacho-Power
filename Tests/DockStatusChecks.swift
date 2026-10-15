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

        if let previewPath = CommandLine.arguments.dropFirst().first {
            let folder = URL(fileURLWithPath: previewPath, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let logo = NSImage(contentsOfFile: "Resources/NachoPowerLogo.png")
            let previews = [("ac-connected", status(78, ac: true)),
                            ("ac-disconnected", status(78, ac: false)),
                            ("unavailable", status(nil, ac: nil)),
                            ("full-battery", status(100, ac: true))]
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
