import Foundation

/// Incremental readings belong to one encrypted Bluetooth session. Telemetry
/// can arrive during authentication; keep it private until the owner is accepted.
struct EcoFlowBluetoothSessionState {
    static let maximumStreamSilence: TimeInterval = 15
    static let maximumMeasurementAge: TimeInterval = 90
    static let maximumVoltageAge: TimeInterval = 6
    static let runtimePollInterval: TimeInterval = 2

    enum AuthenticationStage { case awaitingStatus, awaitingOwnerAcknowledgment, authenticated }
    enum PacketAction { case requestOwnerAuthentication, ownerAccepted, telemetryReceived, ignored }
    enum IngestResult { case accepted, ignored, expiredSession }

    private var metrics = EcoFlowWirelessProtocol.Metrics()
    private var fieldDates: [String: Date] = [:]
    private var authenticatedAt: Date?
    private var lastObservationAt: Date?
    private var lastRuntimeRequestAt: Date?

    var isAuthenticated: Bool { authenticatedAt != nil }
    var needsRuntimePolling: Bool { isAuthenticated && metrics.acConnected == nil }

    /// Claim a polling slot without making requests count as received telemetry.
    /// The monitor uses this for both the initial request and its repeating task.
    mutating func takeRuntimeRequest(at date: Date) -> Bool {
        guard needsRuntimePolling, !streamIsStale(at: date) else { return false }
        if let previous = lastRuntimeRequestAt,
           date.timeIntervalSince(previous) < Self.runtimePollInterval { return false }
        lastRuntimeRequestAt = date
        return true
    }

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
        guard packet.source == 2, packet.commandSet == 0xfe else { return .ignored }
        let update: EcoFlowWirelessProtocol.Metrics
        switch packet.command {
        case 0x15: update = try EcoFlowWirelessProtocol.metrics(packet.payload)
        case 0x16: update = try EcoFlowWirelessProtocol.runtimeMetrics(packet.payload)
        default: return .ignored
        }
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
        if let value = update.acInputVoltage {
            metrics.acInputVoltage = value; fieldDates["acInputVoltage"] = date
        }
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

    /// A read-only support view of field presence and freshness. It never
    /// exposes device/account identifiers or pre-authentication measurements.
    func diagnosticDetails(at date: Date) -> [String: Any] {
        let reading = snapshot(deviceName: "", at: date)
        var details: [String: Any] = [
            "authenticated": isAuthenticated, "hasBattery": metrics.battery != nil,
            "hasACFlag": metrics.acConnected != nil, "hasACVoltage": metrics.acInputVoltage != nil,
            "hasACWatts": metrics.acWatts != nil, "hasTotalWatts": metrics.totalWatts != nil,
            "acStatus": reading?.acConnected.map { $0 ? "connected" : "disconnected" } ?? "unknown",
            "isStale": streamIsStale(at: date)
        ]
        func addAge(_ key: String, observed: Date?) {
            guard let observed else { return }
            let age = date.timeIntervalSince(observed)
            if age.isFinite, age >= 0 { details[key] = age }
        }
        addAge("streamAge", observed: lastObservationAt ?? authenticatedAt)
        addAge("batteryAge", observed: fieldDates["battery"])
        addAge("acVoltageAge", observed: fieldDates["acInputVoltage"])
        if !isAuthenticated { details["reason"] = "not_authenticated" }
        else if streamIsStale(at: date) { details["reason"] = "stream_stale" }
        else if lastObservationAt == nil { details["reason"] = "field_missing" }
        else if metrics.acConnected != nil { details["reason"] = "explicit_flag" }
        else if let voltage = metrics.acInputVoltage, let observed = fieldDates["acInputVoltage"] {
            let age = date.timeIntervalSince(observed)
            if !age.isFinite || age < 0 { details["reason"] = "voltage_invalid" }
            else if age > Self.maximumVoltageAge { details["reason"] = "voltage_stale" }
            else if (0...10).contains(voltage) || (80...300).contains(voltage) { details["reason"] = "input_voltage" }
            else { details["reason"] = "voltage_ambiguous" }
        } else { details["reason"] = "voltage_missing" }
        if isAuthenticated {
            // Retain the last measured values alongside their ages, so a report
            // distinguishes stale voltage from a genuinely absent field.
            if let value = metrics.battery { details["batteryPercentage"] = value }
            if let value = metrics.acWatts { details["acInputWatts"] = value }
            if let value = metrics.totalWatts { details["totalInputWatts"] = value }
            if let value = metrics.acInputVoltage { details["acInputVoltage"] = value }
            if let value = reading?.acConnected { details["acConnected"] = value }
        }
        return details
    }

    /// Describe only the telemetry envelope and top-level protobuf field IDs.
    /// Field values, nested messages, authentication packets, and raw bytes are
    /// excluded. Parsing here is observational and cannot alter transport state.
    static func diagnosticPacketDetails(_ packet: EcoFlowWirelessProtocol.Packet) -> [String: Any] {
        var details: [String: Any] = ["commandSet": Int(packet.commandSet),
            "commandID": Int(packet.command), "payloadBytes": packet.payload.count]
        guard packet.source == 2, packet.commandSet == 0xfe,
              packet.command == 0x15 || packet.command == 0x16, packet.payload.count <= 32_768 else { return details }
        let data = packet.payload
        var cursor = 0
        var fields = Set<Int>()
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard cursor < data.count else { return nil }
                let byte = data[cursor]; cursor += 1
                guard index < 9 || byte <= 1 else { return nil }
                value |= UInt64(byte & 0x7f) << (index * 7)
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        parse: while cursor < data.count {
            guard let tag = varint(), tag >> 3 > 0 else { break }
            let field = tag >> 3
            switch tag & 7 {
            case 0: guard varint() != nil else { break parse }
            case 1:
                guard data.count - cursor >= 8 else { break parse }
                cursor += 8
            case 2:
                guard let count = varint(), count <= UInt64(data.count - cursor) else { break parse }
                cursor += Int(count)
            case 5:
                guard data.count - cursor >= 4 else { break parse }
                cursor += 4
            default: break parse
            }
            if field <= 65_535 { fields.insert(Int(field)) }
            if fields.count >= 64 { break }
        }
        details["fieldIDs"] = fields.sorted()
        return details
    }

    func snapshot(deviceName: String, at date: Date) -> PowerTelemetry? {
        guard isAuthenticated, let observation = lastObservationAt,
              (-5...Self.maximumStreamSilence).contains(date.timeIntervalSince(observation)) else { return nil }
        func fresh(_ field: String, maximumAge: TimeInterval = Self.maximumMeasurementAge,
                   minimumAge: TimeInterval = -5) -> Bool {
            guard let observed = fieldDates[field] else { return false }
            return (minimumAge...maximumAge).contains(date.timeIntervalSince(observed))
        }
        // Older firmware's explicit presence flag remains authoritative. Newer
        // firmware omits it, so use only a fresh AC-input voltage measurement.
        // A disconnected input can retain a small residual voltage. Treat only
        // near-zero voltage as disconnected; the range above 10V and below 80V
        // is ambiguous rather than evidence of connected or disconnected mains.
        var acConnected = metrics.acConnected
        if acConnected == nil, fresh("acInputVoltage", maximumAge: Self.maximumVoltageAge, minimumAge: 0),
           let voltage = metrics.acInputVoltage {
            if (0...10).contains(voltage) { acConnected = false }
            else if (80...300).contains(voltage) { acConnected = true }
        }
        return PowerTelemetry(
            deviceName: deviceName,
            batteryPercentage: fresh("battery") ? metrics.battery : nil,
            acInputWatts: fresh("acWatts") ? metrics.acWatts : nil,
            totalInputWatts: fresh("totalWatts") ? metrics.totalWatts : nil,
            acConnected: acConnected,
            sourceDescription: "Bluetooth · direct local connection",
            timestamp: observation
        )
    }
}
