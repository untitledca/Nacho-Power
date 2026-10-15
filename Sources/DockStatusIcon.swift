import AppKit

/// The Dock always reflects the DELTA's AC input, never the Mac's power source
/// or a positive combined solar/DC input measurement.
struct DockPowerStatus: Equatable {
    enum ACState: Equatable {
        case connected, disconnected, unknown
    }

    static let maximumReadingAge: TimeInterval = 30
    let batteryPercentage: Int?
    let acState: ACState

    init(telemetry: PowerTelemetry?, isConnected: Bool, now: Date = Date()) {
        guard isConnected, let telemetry,
              now.timeIntervalSince(telemetry.timestamp).isFinite,
              (-5..<Self.maximumReadingAge).contains(now.timeIntervalSince(telemetry.timestamp)) else {
            batteryPercentage = nil
            acState = .unknown
            return
        }
        if let battery = telemetry.batteryPercentage, battery.isFinite, (0...100).contains(battery) {
            batteryPercentage = Int(battery.rounded())
        } else {
            batteryPercentage = nil
        }
        switch telemetry.acConnected {
        case true?: acState = .connected
        case false?: acState = .disconnected
        case nil: acState = .unknown
        }
    }

    var percentageText: String { batteryPercentage.map { "\($0)%" } ?? "—" }

    var accessibilityDescription: String {
        let battery = batteryPercentage.map { "Battery \($0) percent" } ?? "Battery unavailable"
        switch acState {
        case .connected: return "EcoFlow Cat · \(battery) · AC connected"
        case .disconnected: return "EcoFlow Cat · \(battery) · AC disconnected"
        case .unknown: return "EcoFlow Cat · \(battery) · AC status unavailable"
        }
    }
}

enum DockStatusIcon {
    static func menuBarImage(for status: DockPowerStatus) -> NSImage {
        let battery = status.batteryPercentage ?? 0
        let level = battery < 13 ? 0 : battery < 38 ? 25 : battery < 63 ? 50 : battery < 88 ? 75 : 100
        let symbolName = "battery.\(level)percent"
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: status.accessibilityDescription)
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let configured = symbol?.withSymbolConfiguration(configuration) ?? symbol
        let image = NSImage(size: NSSize(width: 25, height: 18), flipped: false) { rect in
            configured?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color(for: status.acState).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func color(for state: DockPowerStatus.ACState) -> NSColor {
        switch state {
        case .connected: return NSColor(srgbRed: 0.06, green: 0.66, blue: 0.27, alpha: 1)
        case .disconnected: return NSColor(srgbRed: 0.90, green: 0.12, blue: 0.17, alpha: 1)
        case .unknown: return NSColor(srgbRed: 0.40, green: 0.44, blue: 0.49, alpha: 1)
        }
    }

    /// Render enough pixels for a magnified Retina Dock while keeping the
    /// percentage large enough to read at the usual 48–64 point Dock size.
    static func image(for status: DockPowerStatus, logo: NSImage?) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            let scale = rect.width / 512
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.translateX(by: rect.minX, yBy: rect.minY)
            transform.scale(by: scale)
            transform.concat()

            let color = color(for: status.acState)
            let outline = NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: 488, height: 488),
                                       xRadius: 112, yRadius: 112)
            color.setFill()
            outline.fill()

            let logoRect = NSRect(x: 31, y: 31, width: 450, height: 450)
            if let logo {
                logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                NSColor(white: 0.12, alpha: 1).setFill()
                NSBezierPath(roundedRect: logoRect, xRadius: 90, yRadius: 90).fill()
                NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)?
                    .draw(in: NSRect(x: 151, y: 225, width: 210, height: 210))
            }

            // This broad colored plate makes power state visible even when
            // the Dock is small; the original cat remains visible above it.
            let plate = NSBezierPath(roundedRect: NSRect(x: 18, y: 12, width: 476, height: 184),
                                     xRadius: 70, yRadius: 70)
            color.setFill()
            plate.fill()
            let text = status.percentageText as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 141, weight: .heavy),
                .foregroundColor: NSColor.white,
                .kern: -5
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (512 - textSize.width) / 2,
                                 y: 20 + (168 - textSize.height) / 2),
                      withAttributes: attributes)
            return true
        }
    }
}
