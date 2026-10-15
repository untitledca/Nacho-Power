import Foundation

/// A read-only observation of an EcoFlow over USB, Bluetooth, or Wi-Fi cloud.
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
    /// Timestamp of this source observation, used for freshness and confirmation.
    let timestamp: Date

    /// Watt-only fallback for older observations. An explicit AC presence flag
    /// takes precedence in the reminder engine, even when input is zero.
    var reminderInputWatts: Double? {
        switch acConnected {
        case .some(false): return 0
        case .some(true): return acInputWatts ?? totalInputWatts
        case .none: return nil
        }
    }
}
