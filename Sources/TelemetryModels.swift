import Foundation

/// A read-only observation of an EcoFlow attached directly by USB.
/// `nil` means unknown, never an implicit zero or an unplug event.
struct PowerTelemetry: Sendable {
    let deviceName: String
    let batteryPercentage: Double?
    /// Dedicated AC measurement, when exposed by the device's firmware.
    let acInputWatts: Double?
    /// Combined input measurement; this can include non-AC sources.
    let totalInputWatts: Double?
    let acConnected: Bool?
    let sourceDescription: String
    /// Timestamp of this USB observation, used for freshness and confirmation.
    let timestamp: Date

    /// AC presence is required before a positive input can finish a reminder.
    /// Some firmware exposes only combined input, matching the original rule.
    var reminderInputWatts: Double? {
        switch acConnected {
        case .some(false): return 0
        case .some(true): return acInputWatts ?? totalInputWatts
        case .none: return nil
        }
    }
}
