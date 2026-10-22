import Foundation
import Combine
@preconcurrency import CoreBluetooth

/// Serial numbers are used locally to target connections, never in diagnostics.
/// The visible label contains only a short suffix to distinguish nearby units.
struct EcoFlowDiscoveredStation: Identifiable, Equatable, Sendable {
    let serialNumber: String
    let name: String
    let transport: EcoFlowTransport

    var id: String { EcoFlowWirelessProtocol.normalizedSerial(serialNumber) }
    var userDisplayName: String { "\(name) · …\(id.suffix(6)) (\(transport.title))" }

    /// A station visible over both transports is one picker entry. Automatic
    /// connections prefer USB, so its discovery label does too.
    static func merging(_ station: Self, into existing: [Self]) -> [Self] {
        guard !station.id.isEmpty else { return existing }
        var result = existing.filter { $0.id != station.id }
        if let previous = existing.first(where: { $0.id == station.id }) {
            let transport: EcoFlowTransport = previous.transport == .usb || station.transport == .usb ? .usb : station.transport
            let name = station.transport == .bluetooth ? station.name : previous.name
            result.append(Self(serialNumber: station.id, name: name, transport: transport))
        } else {
            result.append(Self(serialNumber: station.id, name: station.name, transport: station.transport))
        }
        return result.sorted {
            let comparison = $0.userDisplayName.localizedStandardCompare($1.userDisplayName)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

/// Discovery only reads USB registry metadata and BLE advertisements. It never
/// opens a telemetry port, authenticates, connects to, or controls a station.
@MainActor
final class EcoFlowStationDiscovery: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    @Published private(set) var stations: [EcoFlowDiscoveredStation] = []
    @Published private(set) var isScanning = false
    @Published private(set) var message = "Scan for nearby stations, then choose the EcoFlow to monitor."

    private var central: CBCentralManager?
    private var timeoutTask: Task<Void, Never>?
    private var generation = 0

    func scan() {
        stop()
        stations = []
        for device in EcoFlowUSBDiscovery.availableDevices() where !device.serialNumber.isEmpty {
            stations = EcoFlowDiscoveredStation.merging(.init(serialNumber: device.serialNumber,
                name: device.name, transport: .usb), into: stations)
        }
        isScanning = true
        message = "Looking for nearby EcoFlow stations…"
        let currentGeneration = generation
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, self.generation == currentGeneration, self.isScanning else { return }
            self.finish()
        }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else {
            beginBluetoothScanIfReady()
        }
    }

    func stop() {
        generation &+= 1
        timeoutTask?.cancel(); timeoutTask = nil
        central?.stopScan()
        isScanning = false
    }

    private func finish(message: String? = nil) {
        stop()
        if let message { self.message = message }
        else if stations.isEmpty {
            self.message = "No supported stations found. Keep the EcoFlow nearby and close other apps connected to it, then scan again."
        } else {
            self.message = stations.count == 1 ? "Found one station. Choose it below." : "Found \(stations.count) stations. Choose the units to monitor."
        }
    }

    private func beginBluetoothScanIfReady() {
        guard isScanning, let central else { return }
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .poweredOff:
            finish(message: "Turn on Bluetooth to find nearby stations. Available USB stations are listed below.")
        case .unauthorized:
            finish(message: "Allow Bluetooth for Nacho Power in System Settings → Privacy & Security → Bluetooth. Available USB stations are listed below.")
        case .unsupported:
            finish(message: "This Mac cannot scan Bluetooth stations. Available USB stations are listed below.")
        case .unknown, .resetting: break
        @unknown default: finish(message: "Bluetooth is unavailable. Available USB stations are listed below.")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { beginBluetoothScanIfReady() }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isScanning,
              let bytes = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let advertisement = EcoFlowWirelessProtocol.Advertisement.parse(bytes), advertisement.compatible else { return }
        stations = EcoFlowDiscoveredStation.merging(.init(serialNumber: advertisement.serial,
            name: advertisement.deviceName, transport: .bluetooth), into: stations)
        message = stations.count == 1 ? "Found one station. Looking for more…" : "Found \(stations.count) stations. Looking for more…"
    }
}
