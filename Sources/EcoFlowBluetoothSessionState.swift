import Foundation

/// Incremental readings belong to one encrypted Bluetooth session. Telemetry
/// can arrive during authentication; keep it private until the owner is accepted.
struct EcoFlowBluetoothSessionState {
    static let maximumStreamSilence: TimeInterval = 15
    static let maximumMeasurementAge: TimeInterval = 90

    enum AuthenticationStage { case awaitingStatus, awaitingOwnerAcknowledgment, authenticated }
    enum PacketAction { case requestOwnerAuthentication, ownerAccepted, telemetryReceived, ignored }
    enum IngestResult { case accepted, ignored, expiredSession }

    private var metrics = EcoFlowWirelessProtocol.Metrics()
    private var fieldDates: [String: Date] = [:]
    private var authenticatedAt: Date?
    private var lastObservationAt: Date?

    var isAuthenticated: Bool { authenticatedAt != nil }

    /// Route decrypted packets without dropping uploads interleaved with the
    /// handshake. This same path is used by the monitor and deterministic tests.
    mutating func receive(_ packet: EcoFlowWirelessProtocol.Packet,
                          stage: AuthenticationStage, at date: Date) throws -> PacketAction {
        if stage == .awaitingStatus, packet.source == 0x35,
           packet.commandSet == 0x35, packet.command == 0x89 {
            return .requestOwnerAuthentication
        }
        if packet.source == 0x35, packet.commandSet == 0x35, packet.command == 0x86 {
            guard stage == .awaitingOwnerAcknowledgment else { return .ignored }
            guard packet.payload == [0] else {
                reset()
                throw EcoFlowWirelessError.authentication
            }
            authenticate(at: date)
            return .ownerAccepted
        }
        guard packet.source == 2, packet.commandSet == 0xfe, packet.command == 0x15 else { return .ignored }
        let update = try EcoFlowWirelessProtocol.metrics(packet.payload)
        switch ingest(update, at: date) {
        case .accepted: return .telemetryReceived
        case .ignored: return .ignored
        case .expiredSession:
            throw EcoFlowWirelessError.message("EcoFlow Bluetooth readings stopped. Reconnecting…")
        }
    }

    @discardableResult
    mutating func ingest(_ update: EcoFlowWirelessProtocol.Metrics, at date: Date) -> IngestResult {
        guard update.changed else { return .ignored }
        // Check before recording this observation: a late battery-only packet
        // must not revive AC retained across a stalled connection or sleep,
        // including a gap while owner authentication is still pending.
        guard !streamIsStale(at: date) else {
            reset()
            return .expiredSession
        }
        if let value = update.battery { metrics.battery = value; fieldDates["battery"] = date }
        if let value = update.acWatts { metrics.acWatts = value; fieldDates["acWatts"] = date }
        if let value = update.totalWatts { metrics.totalWatts = value; fieldDates["totalWatts"] = date }
        // AC presence is an event-like Boolean, not a periodically measured
        // value. Missing fields in later uploads mean unchanged, not unknown.
        if let value = update.acConnected { metrics.acConnected = value }
        lastObservationAt = date
        return .accepted
    }

    mutating func authenticate(at date: Date) {
        authenticatedAt = date
    }

    mutating func reset() { self = Self() }

    func streamIsStale(at date: Date) -> Bool {
        guard let activity = lastObservationAt ?? authenticatedAt else { return false }
        return date.timeIntervalSince(activity) > Self.maximumStreamSilence
    }

    func snapshot(deviceName: String, at date: Date) -> PowerTelemetry? {
        guard isAuthenticated, let observation = lastObservationAt,
              (-5...Self.maximumStreamSilence).contains(date.timeIntervalSince(observation)) else { return nil }
        func fresh(_ field: String) -> Bool {
            guard let observed = fieldDates[field] else { return false }
            return (-5...Self.maximumMeasurementAge).contains(date.timeIntervalSince(observed))
        }
        return PowerTelemetry(
            deviceName: deviceName,
            batteryPercentage: fresh("battery") ? metrics.battery : nil,
            acInputWatts: fresh("acWatts") ? metrics.acWatts : nil,
            totalInputWatts: fresh("totalWatts") ? metrics.totalWatts : nil,
            acConnected: metrics.acConnected,
            sourceDescription: "Bluetooth · direct local connection",
            timestamp: observation
        )
    }
}
