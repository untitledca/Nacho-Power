import Foundation
import AppKit
@preconcurrency import CoreBluetooth

@MainActor
final class EcoFlowBluetoothMonitor: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private enum Phase { case idle, scanning, connecting, services, notifying, publicKey, sessionKey, authStatus, authenticating, ready }
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var advertisement: EcoFlowWirelessProtocol.Advertisement?
    private var phase = Phase.idle
    private var phaseStarted = Date.distantPast
    private var configuration = EcoFlowConnectionConfiguration()
    private var keyExchange: EcoFlowWirelessProtocol.KeyExchange?
    private var sessionKey: [UInt8] = []
    private var iv: [UInt8] = []
    private var frames = EcoFlowWirelessProtocol.FrameBuffer()
    private var metrics = EcoFlowWirelessProtocol.Metrics()
    private var fieldDates: [String: Date] = [:]
    private var lastReading = Date.distantPast
    private var latest: PowerTelemetry?
    private var failure: Error?
    private var retryAfter = Date.distantPast
    private var pendingWrites: [Data] = []
    private var writeInProgress = false
    private var generation = 0
    private var scanCandidates: [UUID: (CBPeripheral, EcoFlowWirelessProtocol.Advertisement)] = [:]

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
        guard !configuration.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EcoFlowWirelessError.message("Sign in to your EcoFlow account in Connection settings to enable Bluetooth.")
        }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        if central.state == .unauthorized { throw EcoFlowWirelessError.message("Allow Bluetooth for Nacho Power in System Settings → Privacy & Security → Bluetooth.") }
        if central.state == .poweredOff { throw EcoFlowWirelessError.message("Turn on Bluetooth to connect to the EcoFlow.") }
        if central.state == .unsupported { throw EcoFlowWirelessError.message("Bluetooth Low Energy is unavailable on this Mac.") }
        if phase == .ready && Date().timeIntervalSince(lastReading) > 15 {
            fail(EcoFlowWirelessError.message("EcoFlow Bluetooth readings stopped. Reconnecting…"))
        }
        if phase != .idle && phase != .ready && Date().timeIntervalSince(phaseStarted) > 20 {
            fail(EcoFlowWirelessError.message("Bluetooth connection timed out. Close the EcoFlow app and keep the DELTA nearby."))
        }
        if phase == .idle, Date() >= retryAfter, central.state == .poweredOn { scan() }
        let currentGeneration = generation
        // Keep the app responsive; notification callbacks run while this awaits.
        for _ in 0..<25 {
            try Task.checkCancellation()
            guard currentGeneration == generation else { throw failure ?? EcoFlowWirelessError.message("Bluetooth reconnecting…") }
            if let latest, phase == .ready, Date().timeIntervalSince(latest.timestamp) <= 15 { return latest }
            if let failure, phase == .idle { throw failure }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw failure ?? EcoFlowWirelessError.message(status)
    }

    private var status: String {
        switch phase {
        case .idle, .scanning: return "Looking for your EcoFlow DELTA over Bluetooth. Close the EcoFlow app."
        case .ready: return "Waiting for fresh EcoFlow Bluetooth readings…"
        default: return "Connecting and authenticating with the EcoFlow…"
        }
    }

    func stop() {
        generation += 1
        central?.stopScan()
        if let peripheral { peripheral.delegate = nil; central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; writeCharacteristic = nil; advertisement = nil
        keyExchange = nil; sessionKey = []; iv = []; frames = .init(); metrics = .init(); fieldDates = [:]
        latest = nil; lastReading = .distantPast; pendingWrites = []; writeInProgress = false
        scanCandidates = [:]; phase = .idle; failure = nil
    }

    private func setPhase(_ value: Phase) { phase = value; phaseStarted = Date() }
    private func fail(_ error: Error, delay: TimeInterval = 5) {
        stop(); failure = error; retryAfter = Date().addingTimeInterval(delay)
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
        central.stopScan()
        guard scanCandidates.count == 1, let candidate = scanCandidates.values.first else {
            fail(EcoFlowWirelessError.message("Multiple EcoFlow stations found. Enter the DELTA serial number in Connection settings."), delay: 30); return
        }
        guard candidate.1.supported else { fail(EcoFlowWirelessError.unsupportedDevice, delay: 60); return }
        guard candidate.1.encryption == 7 else {
            fail(EcoFlowWirelessError.message("This DELTA uses an unsupported Bluetooth security version. Use USB or Wi-Fi cloud."), delay: 60); return
        }
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
        let selectedSerial = configuration.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard selectedSerial.isEmpty || advert.serial.uppercased() == selectedSerial else { return }
        scanCandidates[peripheral.identifier] = (peripheral, advert)
        if !selectedSerial.isEmpty || Date().timeIntervalSince(phaseStarted) >= 3 { chooseCandidate() }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        setPhase(.services); peripheral.discoverServices(Self.services)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        fail(EcoFlowWirelessError.message("Could not connect to the EcoFlow. Close its official app and retry."))
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        fail(EcoFlowWirelessError.message("EcoFlow Bluetooth disconnected. Reconnecting…"))
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
        peripheral.writeValue(pendingWrites.removeFirst(), for: writeCharacteristic, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil else { fail(EcoFlowWirelessError.message("EcoFlow Bluetooth request failed. Reconnecting…")); return }
        writeInProgress = false; sendNext()
    }
    private func sendAuth(command: UInt8, payload: [UInt8] = []) throws {
        let packet = EcoFlowWirelessProtocol.authPacket(command: command, payload: payload)
        send(EcoFlowWirelessProtocol.wrap(try EcoFlowWirelessProtocol.crypt(packet, key: sessionKey, iv: iv, encrypt: true), encrypted: true))
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, let data = characteristic.value else { return }
        guard error == nil else { fail(EcoFlowWirelessError.message("EcoFlow Bluetooth read failed.")); return }
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
            if phase == .authStatus {
                guard packet.source == 0x35, packet.commandSet == 0x35, packet.command == 0x89, let advertisement else { return }
                let digest = EcoFlowWirelessProtocol.md5(Array((configuration.userID + advertisement.serial).utf8))
                let auth = digest.map { String(format: "%02X", $0) }.joined()
                setPhase(.authenticating); try sendAuth(command: 0x86, payload: Array(auth.utf8)); return
            }
            if packet.source == 0x35, packet.commandSet == 0x35, packet.command == 0x86 {
                guard packet.payload == [0] else { throw EcoFlowWirelessError.authentication }
                setPhase(.ready); lastReading = Date(); return
            }
            guard packet.source == 2, packet.commandSet == 0xfe, packet.command == 0x15 else { return }
            let update = try EcoFlowWirelessProtocol.metrics(packet.payload)
            guard update.changed, let advertisement else { return }
            setPhase(.ready); lastReading = Date()
            if let value = update.battery { metrics.battery = value; fieldDates["battery"] = lastReading }
            if let value = update.acConnected { metrics.acConnected = value; fieldDates["ac"] = lastReading }
            if let value = update.acWatts { metrics.acWatts = value; fieldDates["acWatts"] = lastReading }
            if let value = update.totalWatts { metrics.totalWatts = value; fieldDates["totalWatts"] = lastReading }
            func fresh(_ field: String) -> Bool { lastReading.timeIntervalSince(fieldDates[field] ?? .distantPast) <= 90 }
            // Reset at every disconnect; incremental updates retain prior values
            // only inside the same authenticated, actively transmitting session.
            latest = PowerTelemetry(deviceName: advertisement.deviceName, batteryPercentage: fresh("battery") ? metrics.battery : nil,
                acInputWatts: fresh("acWatts") ? metrics.acWatts : nil, totalInputWatts: fresh("totalWatts") ? metrics.totalWatts : nil,
                acConnected: fresh("ac") ? metrics.acConnected : nil,
                sourceDescription: "Bluetooth · direct local connection", timestamp: lastReading)
        default: break
        }
    }
}
