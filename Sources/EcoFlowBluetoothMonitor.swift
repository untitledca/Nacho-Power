import Foundation
import AppKit
@preconcurrency import CoreBluetooth

@MainActor
final class EcoFlowBluetoothMonitor: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private enum Phase: String { case idle, scanning, connecting, services, notifying, publicKey, sessionKey, authStatus, authenticating, ready }
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var advertisement: EcoFlowWirelessProtocol.Advertisement?
    private var phase = Phase.idle
    private var phaseStarted = Date.distantPast
    private var configuration = EcoFlowConnectionConfiguration()
    private var stationPreference = EcoFlowWirelessProtocol.StationPreference()
    private var keyExchange: EcoFlowWirelessProtocol.KeyExchange?
    private var sessionKey: [UInt8] = []
    private var iv: [UInt8] = []
    private var frames = EcoFlowWirelessProtocol.FrameBuffer()
    private var readings = EcoFlowBluetoothSessionState()
    private var failure: Error?
    private var retryAfter = Date.distantPast
    private var pendingWrites: [Data] = []
    private var writeInProgress = false
    private var generation = 0
    private var runtimePollTask: Task<Void, Never>?
    private var scanCandidates: [UUID: (CBPeripheral, EcoFlowWirelessProtocol.Advertisement)] = [:]
    private var diagnosticThrottle = SupportDiagnosticThrottle()
    private var diagnosticStatus = ""
    private var writeStartedAt: Date?
    private var diagnosticWriteCount = 0
    private var diagnosticFrameCount = 0

    static let service = CBUUID(string: "00000001-0000-1000-8000-00805f9b34fb")
    // Firmware uses either the 0001/0002/0003 or 0005/0006/0007 GATT family.
    private static let services = [CBUUID(string: "00000001-0000-1000-8000-00805f9b34fb"), CBUUID(string: "00000005-0000-1000-8000-00805f9b34fb")]
    private static let writes = [CBUUID(string: "00000002-0000-1000-8000-00805f9b34fb"), CBUUID(string: "00000006-0000-1000-8000-00805f9b34fb")]
    private static let notifications = [CBUUID(string: "00000003-0000-1000-8000-00805f9b34fb"), CBUUID(string: "00000007-0000-1000-8000-00805f9b34fb")]

    override init() {
        super.init()
        // Deferred until a Bluetooth transport is actually requested.
    }

    func snapshot(configuration newConfiguration: EcoFlowConnectionConfiguration) async throws -> PowerTelemetry {
        if configuration != newConfiguration { stop(); configuration = newConfiguration }
        stationPreference.configure(accountID: configuration.userID, load: EcoFlowCredentialStore.read)
        guard !configuration.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EcoFlowWirelessError.message("Sign in to your EcoFlow account in Connection settings to enable Bluetooth.")
        }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        if central.state == .unauthorized { throw EcoFlowWirelessError.message("Allow Bluetooth for Nacho Power in System Settings → Privacy & Security → Bluetooth.") }
        if central.state == .poweredOff { throw EcoFlowWirelessError.message("Turn on Bluetooth to connect to the EcoFlow.") }
        if central.state == .unsupported { throw EcoFlowWirelessError.message("Bluetooth Low Energy is unavailable on this Mac.") }
        if phase == .ready && readings.streamIsStale(at: Date()) {
            fail(EcoFlowWirelessError.message("EcoFlow Bluetooth readings stopped. Reconnecting…"), reason: "stream_stale")
        }
        if phase != .idle && phase != .ready && Date().timeIntervalSince(phaseStarted) > 20 {
            if phase == .scanning, targetSerial != nil {
                fail(EcoFlowWirelessError.message("Waiting for your selected EcoFlow DELTA. Keep it on and nearby, and close other apps connected to it. To use another station, choose it in Connection settings."),
                     reason: selectionMode == "remembered" ? "remembered_station_missing" : "timeout")
            } else {
                fail(EcoFlowWirelessError.message("Bluetooth connection timed out. Close the EcoFlow app and keep the DELTA nearby."), reason: "timeout")
            }
        }
        if phase == .idle, Date() >= retryAfter, central.state == .poweredOn { scan() }
        let currentGeneration = generation
        // Keep the app responsive; notification callbacks run while this awaits.
        for _ in 0..<25 {
            try Task.checkCancellation()
            guard currentGeneration == generation else { throw failure ?? EcoFlowWirelessError.message("Bluetooth reconnecting…") }
            if phase == .ready, let advertisement,
               let latest = readings.snapshot(deviceName: advertisement.deviceName, at: Date()) {
                recordSessionStatus()
                return latest
            }
            if let failure, phase == .idle { throw failure }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw failure ?? EcoFlowWirelessError.message(status)
    }

    private var status: String {
        switch phase {
        case .idle, .scanning:
            if targetSerial != nil { return "Waiting for your selected EcoFlow DELTA. Close other apps connected to it and keep it nearby." }
            return "Looking for your EcoFlow DELTA over Bluetooth. Close the EcoFlow app."
        case .ready: return "Waiting for fresh EcoFlow Bluetooth readings…"
        default: return "Connecting and authenticating with the EcoFlow…"
        }
    }

    private var targetSerial: String? { stationPreference.targetSerial(explicitSerial: configuration.serialNumber) }
    private var selectionMode: String {
        if !EcoFlowWirelessProtocol.normalizedSerial(configuration.serialNumber).isEmpty { return "explicit" }
        return stationPreference.rememberedSerial.isEmpty ? "automatic" : "remembered"
    }

    func stop() {
        if phase != .idle { recordDiagnostic("stop", details: ["reason": "cancelled"], interval: 0) }
        generation += 1
        runtimePollTask?.cancel(); runtimePollTask = nil
        central?.stopScan()
        if let peripheral { peripheral.delegate = nil; central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; writeCharacteristic = nil; advertisement = nil
        keyExchange = nil; sessionKey = []; iv = []; frames = .init(); readings.reset()
        pendingWrites = []; writeInProgress = false
        scanCandidates = [:]; phase = .idle; failure = nil
        diagnosticThrottle.reset(); diagnosticStatus = ""
        writeStartedAt = nil; diagnosticWriteCount = 0; diagnosticFrameCount = 0
    }

    private func setPhase(_ value: Phase) {
        let changed = phase != value
        phase = value; phaseStarted = Date()
        if changed { recordDiagnostic("phase_changed", interval: 0) }
    }
    private func fail(_ error: Error, delay: TimeInterval = 5, reason: String? = nil,
                      diagnosticError: Error? = nil) {
        var details = SupportDiagnostics.errorDetails(diagnosticError ?? error)
        details["reason"] = reason ?? Self.diagnosticErrorReason(error)
        recordDiagnostic("failure", details: details, interval: 0)
        stop(); failure = error; retryAfter = Date().addingTimeInterval(delay)
    }

    private static func diagnosticErrorReason(_ error: Error) -> String {
        guard let wireless = error as? EcoFlowWirelessError else { return "other" }
        switch wireless {
        case .authentication: return "authentication"
        case .invalidPacket: return "invalid_packet"
        case .unsupportedDevice: return "unsupported"
        case .message: return "other"
        }
    }

    private func recordDiagnostic(_ event: String, details extra: [String: Any] = [:],
                                  interval: TimeInterval = 30, key: String? = nil) {
        let now = Date()
        guard diagnosticThrottle.shouldRecord(key ?? event, at: now, interval: interval) else { return }
        var details = readings.diagnosticDetails(at: now)
        details["transport"] = "bluetooth"
        details["phase"] = phase.rawValue
        details["queueDepth"] = pendingWrites.count
        details["writeInProgress"] = writeInProgress
        details["writeCount"] = diagnosticWriteCount
        details["frameCount"] = diagnosticFrameCount
        details["hasRememberedStation"] = !stationPreference.rememberedSerial.isEmpty
        details["selectionMode"] = selectionMode
        details["deviceCount"] = Set(scanCandidates.values.filter { $0.1.compatible }
            .map { EcoFlowWirelessProtocol.normalizedSerial($0.1.serial) }).count
        if let writeStartedAt { details["writeAge"] = max(0, now.timeIntervalSince(writeStartedAt)) }
        if let advertisement, advertisement.supported {
            details["deviceModel"] = advertisement.deviceName == "EcoFlow DELTA 3 Plus" ? "DELTA 3 Plus" : "DELTA 3"
        }
        details.merge(extra) { _, new in new }
        SupportDiagnostics.shared.record(category: "bluetooth", event: event, details: details)
    }

    private func recordSessionStatus() {
        let details = readings.diagnosticDetails(at: Date())
        let status = details["acStatus"] as? String ?? "unknown"
        let reason = details["reason"] as? String ?? "unknown"
        let signature = status + ":" + reason
        let changed = signature != diagnosticStatus
        let previous = diagnosticStatus
        diagnosticStatus = signature
        let event = changed && status == "unknown" ? "ac_unknown"
            : (changed && previous.hasPrefix("unknown:") ? "ac_recovered" : "snapshot")
        recordDiagnostic(event, details: details, interval: changed ? 0 : 30, key: "session_status")
    }

    private func scan() {
        failure = nil; scanCandidates = [:]; setPhase(.scanning)
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let currentGeneration = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.generation == currentGeneration, self.phase == .scanning else { return }
            self.chooseCandidate()
        }
    }

    private func chooseCandidate() {
        guard !scanCandidates.isEmpty else { return }
        let choice = EcoFlowWirelessProtocol.chooseStation(scanCandidates.values.map { $0.1 }, targetSerial: targetSerial)
        let serial: String
        switch choice {
        case .waiting: return
        case .multiple:
            fail(EcoFlowWirelessError.message("Multiple EcoFlow stations found. Enter the DELTA serial number in Connection settings."), delay: 30, reason: "multiple_devices"); return
        case .unsupported:
            fail(EcoFlowWirelessError.unsupportedDevice, delay: 60); return
        case .incompatibleSecurity:
            fail(EcoFlowWirelessError.message("This DELTA uses an unsupported Bluetooth security version. Use USB or Wi-Fi cloud."), delay: 60, reason: "unsupported"); return
        case .station(let selected): serial = selected
        }
        guard let candidate = scanCandidates.values.first(where: {
            $0.1.compatible && EcoFlowWirelessProtocol.normalizedSerial($0.1.serial) == serial
        }) else { return }
        central.stopScan()
        advertisement = candidate.1; peripheral = candidate.0
        peripheral?.delegate = self; setPhase(.connecting)
        central.connect(candidate.0, options: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            stop()
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .scanning,
              let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let advert = EcoFlowWirelessProtocol.Advertisement.parse(manufacturerData) else { return }
        if let targetSerial {
            guard EcoFlowWirelessProtocol.normalizedSerial(advert.serial) == targetSerial else { return }
        } else {
            guard advert.compatible else { return }
        }
        scanCandidates[peripheral.identifier] = (peripheral, advert)
        if targetSerial != nil || Date().timeIntervalSince(phaseStarted) >= 3 { chooseCandidate() }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        setPhase(.services); peripheral.discoverServices(Self.services)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        fail(EcoFlowWirelessError.message("Could not connect to the EcoFlow. Close its official app and retry."), reason: "not_connected", diagnosticError: error)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        fail(EcoFlowWirelessError.message("EcoFlow Bluetooth disconnected. Reconnecting…"), reason: "disconnected", diagnosticError: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else { fail(EcoFlowWirelessError.unsupportedDevice); return }
        for service in services { peripheral.discoverCharacteristics(Self.writes + Self.notifications, for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil else { fail(EcoFlowWirelessError.message("EcoFlow Bluetooth services are unavailable.")); return }
        let chars = service.characteristics ?? []
        guard let write = chars.first(where: { Self.writes.contains($0.uuid) && $0.properties.contains(.write) }),
              let notify = chars.first(where: { Self.notifications.contains($0.uuid) && $0.properties.contains(.notify) }) else {
            fail(EcoFlowWirelessError.unsupportedDevice); return
        }
        writeCharacteristic = write; setPhase(.notifying)
        peripheral.setNotifyValue(true, for: notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, phase == .notifying else { return }
        guard error == nil, characteristic.isNotifying else { fail(EcoFlowWirelessError.message("Could not subscribe to EcoFlow Bluetooth readings.")); return }
        do {
            let exchange = try EcoFlowWirelessProtocol.KeyExchange(); keyExchange = exchange
            setPhase(.publicKey); send(EcoFlowWirelessProtocol.wrap([1, 0] + exchange.publicKey))
        } catch { fail(error) }
    }

    private func send(_ bytes: [UInt8]) {
        guard let peripheral else { return }
        let limit = peripheral.maximumWriteValueLength(for: .withResponse)
        guard limit > 0 else { fail(EcoFlowWirelessError.invalidPacket); return }
        for offset in stride(from: 0, to: bytes.count, by: limit) {
            pendingWrites.append(Data(bytes[offset..<min(bytes.count, offset + limit)]))
        }
        sendNext()
    }
    private func sendNext() {
        guard !writeInProgress, !pendingWrites.isEmpty, let peripheral, let writeCharacteristic else { return }
        writeInProgress = true
        writeStartedAt = Date()
        diagnosticWriteCount += 1
        recordDiagnostic("write_started")
        peripheral.writeValue(pendingWrites.removeFirst(), for: writeCharacteristic, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil else { fail(EcoFlowWirelessError.message("EcoFlow Bluetooth request failed. Reconnecting…"), reason: "write_failed"); return }
        writeInProgress = false
        recordDiagnostic("write_acknowledged")
        writeStartedAt = nil
        sendNext()
    }
    private func sendAuth(command: UInt8, payload: [UInt8] = []) throws {
        let packet = EcoFlowWirelessProtocol.authPacket(command: command, payload: payload)
        send(EcoFlowWirelessProtocol.wrap(try EcoFlowWirelessProtocol.crypt(packet, key: sessionKey, iv: iv, encrypt: true), encrypted: true))
    }

    private func pollRuntimeIfNeeded() throws {
        guard phase == .ready else { return }
        let now = Date()
        guard !readings.streamIsStale(at: now) else {
            throw EcoFlowWirelessError.message("EcoFlow Bluetooth readings stopped. Reconnecting…")
        }
        // A stalled characteristic must not accumulate status requests while
        // the previous encrypted write is still being acknowledged.
        guard !writeInProgress, pendingWrites.isEmpty else {
            let reason = writeInProgress ? "write_pending" : "queue_pending"
            recordDiagnostic("poll_skipped", details: ["reason": reason], interval: 15, key: "poll_skipped:" + reason)
            return
        }
        guard readings.takeRuntimeRequest(at: now) else {
            let reason = readings.needsRuntimePolling ? "poll_interval" : "polling_not_needed"
            recordDiagnostic("poll_skipped", details: ["reason": reason], key: "poll_skipped:" + reason)
            return
        }
        let packet = EcoFlowWirelessProtocol.runtimeUploadRequest()
        let encrypted = try EcoFlowWirelessProtocol.crypt(packet, key: sessionKey, iv: iv, encrypt: true)
        recordDiagnostic("poll_requested", details: ["commandSet": 254, "commandID": 17])
        send(EcoFlowWirelessProtocol.wrap(encrypted, encrypted: true))
    }

    private func startRuntimePolling() throws {
        runtimePollTask?.cancel(); runtimePollTask = nil
        try pollRuntimeIfNeeded()
        guard phase == .ready, readings.needsRuntimePolling else { return }
        let currentGeneration = generation
        runtimePollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(EcoFlowBluetoothSessionState.runtimePollInterval * 1_000_000_000))
                } catch { return }
                guard let self, self.generation == currentGeneration, self.phase == .ready else { return }
                guard self.readings.needsRuntimePolling else {
                    self.runtimePollTask = nil
                    return
                }
                do { try self.pollRuntimeIfNeeded() }
                catch { self.fail(error); return }
            }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, let data = characteristic.value else { return }
        guard error == nil else { fail(EcoFlowWirelessError.message("EcoFlow Bluetooth read failed."), reason: "read_failed"); return }
        do {
            for frame in try frames.append(data) {
                if frame.command && [.authStatus, .authenticating, .ready].contains(phase) { continue }
                if phase == .sessionKey && frame.command && frame.payload.first == 1 { continue }
                try process(frame.payload)
            }
        }
        catch { fail(error) }
    }
    private func process(_ payload: [UInt8]) throws {
        switch phase {
        case .publicKey:
            guard payload.count >= 43, payload[0] == 1, payload[1] == 0, payload[2] == 0, let keyExchange else {
                throw EcoFlowWirelessError.authentication
            }
            let shared = try keyExchange.sharedSecret(peer: Array(payload[3..<43]))
            iv = EcoFlowWirelessProtocol.md5(shared); sessionKey = Array(shared.prefix(16)); self.keyExchange = nil
            setPhase(.sessionKey); send(EcoFlowWirelessProtocol.wrap([2]))
        case .sessionKey:
            guard payload.first == 2 else { throw EcoFlowWirelessError.authentication }
            let decoded = try EcoFlowWirelessProtocol.crypt(Array(payload.dropFirst()), key: sessionKey, iv: iv, encrypt: false)
            sessionKey = try EcoFlowWirelessProtocol.sessionKey(decoded)
            setPhase(.authStatus); try sendAuth(command: 0x89)
        case .authStatus, .authenticating, .ready:
            let plain = try EcoFlowWirelessProtocol.crypt(payload, key: sessionKey, iv: iv, encrypt: false)
            let packet = try EcoFlowWirelessProtocol.parsePacket(plain)
            let stage: EcoFlowBluetoothSessionState.AuthenticationStage
            switch phase {
            case .authStatus: stage = .awaitingStatus
            case .authenticating: stage = .awaitingOwnerAcknowledgment
            default: stage = .authenticated
            }
            let action = try readings.receive(packet, stage: stage, at: Date())
            diagnosticFrameCount += 1
            if packet.source == 2, packet.commandSet == 0xfe {
                let details = EcoFlowBluetoothSessionState.diagnosticPacketDetails(packet)
                let fields = details["fieldIDs"] as? [Int] ?? []
                let key = "telemetry:\(packet.command):" + fields.map(String.init).joined(separator: ",")
                recordDiagnostic("telemetry_received", details: details, key: key)
            }
            switch action {
            case .requestOwnerAuthentication:
                guard let advertisement else { return }
                let digest = EcoFlowWirelessProtocol.md5(Array((configuration.userID + advertisement.serial).utf8))
                let auth = digest.map { String(format: "%02X", $0) }.joined()
                setPhase(.authenticating); try sendAuth(command: 0x86, payload: Array(auth.utf8))
            case .ownerAccepted:
                if let advertisement {
                    stationPreference.rememberAuthenticated(advertisement) { serial, key in
                        try EcoFlowCredentialStore.write(serial, for: key)
                    }
                }
                setPhase(.ready)
                recordDiagnostic("authenticated", interval: 0)
                try startRuntimePolling()
            case .telemetryReceived, .ignored:
                // Early uploads remain private until the owner reply succeeds.
                if !readings.needsRuntimePolling {
                    runtimePollTask?.cancel(); runtimePollTask = nil
                }
                break
            }
        default: break
        }
    }
}
