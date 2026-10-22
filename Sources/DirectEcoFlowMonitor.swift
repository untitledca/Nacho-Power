import Foundation
import AppKit
import IOKit
import IOUSBHost
import Darwin

enum DirectEcoFlowError: LocalizedError {
    case powerManagerRunning
    case noDevice
    case multipleDevices
    case unsupportedDevice
    case unavailable
    case invalidReport
    case serialBusy
    case serialTimeout

    var errorDescription: String? {
        switch self {
        case .powerManagerRunning: return "Quit EcoFlow PowerManager so Nacho Power can read the USB connection directly."
        case .noDevice: return "Connect a supported EcoFlow power station to this Mac by USB."
        case .multipleDevices: return "Choose an EcoFlow station in Connection settings when several are connected by USB."
        case .unsupportedDevice: return "This EcoFlow does not expose the supported USB power readings."
        case .unavailable: return "Waiting for the EcoFlow USB connection."
        case .invalidReport: return "The EcoFlow returned an unreadable power reading."
        case .serialBusy: return "Another app is using the EcoFlow USB telemetry connection."
        case .serialTimeout: return "Waiting for fresh EcoFlow input-power readings."
        }
    }
}

/// Direct, local USB monitoring using only macOS system frameworks. The only
/// USB requests are GET_DESCRIPTOR and GET_REPORT; the CDC packet is the
/// documented read-only telemetry query. No configuration/output controls exist.
final class DirectEcoFlowMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "EcoFlowCat.directUSB", qos: .utility)
    private var sequence: UInt32 = 0
    private let generationLock = NSLock()
    private var generation = 0

    func snapshot(serialNumber: String = "") async throws -> PowerTelemetry {
        try Task.checkCancellation()
        let requestGeneration = currentGeneration
        let reading = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard currentGeneration == requestGeneration else { throw CancellationError() }
                    let reading = try readSnapshot(serialNumber: serialNumber)
                    guard currentGeneration == requestGeneration else { throw CancellationError() }
                    continuation.resume(returning: reading)
                }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return reading
    }

    /// In-flight system transfers have short deadlines; stopping this instance
    /// discards their result and prevents its queued reads from starting.
    func stop() {
        generationLock.lock(); defer { generationLock.unlock() }
        generation &+= 1
    }

    private var currentGeneration: Int {
        generationLock.lock(); defer { generationLock.unlock() }
        return generation
    }

    private func readSnapshot(serialNumber: String) throws -> PowerTelemetry {
        guard !Self.powerManagerIsRunning else { throw DirectEcoFlowError.powerManagerRunning }
        let service = try EcoFlowUSBDiscovery.deviceService(serialNumber: serialNumber)
        defer { IOObjectRelease(service) }
        // No DeviceCapture/DeviceSeize, SET_CONFIGURATION, reset, SET_REPORT,
        // output report, or access to unrelated USB devices.
        let device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
        defer { device.destroy() }
        let name = EcoFlowUSBDiscovery.stringProperty(service, "USB Product Name") ?? "EcoFlow"
        let interface = try EcoFlowUSBDescriptor.hidInterface(device: device)
        let descriptor = try Self.getDescriptor(device: device, interface: interface)
        let fields = try EcoFlowHIDDescriptor.fields(descriptor)
        guard let capacity = fields.first(where: { $0.page == 0x85 && $0.usage == 0x66 && $0.kind == 3 }),
              let present = fields.first(where: { $0.page == 0x85 && $0.usage == 0xd0 && $0.kind == 3 }) else {
            throw DirectEcoFlowError.unsupportedDevice
        }
        var reports: [UInt8: Data] = [:]
        for reportID in Set([capacity.reportID, present.reportID]) {
            reports[reportID] = try Self.getFeature(device: device, interface: interface, reportID: reportID)
        }
        let charge = try capacity.value(in: reports[capacity.reportID]!)
        let acFlag = try present.value(in: reports[present.reportID]!)
        guard (0...100).contains(charge), [0, 1].contains(acFlag) else { throw DirectEcoFlowError.invalidReport }
        if let fault = fields.first(where: { $0.page == 0x84 && $0.usage == 0x73 && $0.kind == 3 }) {
            let report: Data
            if let cached = reports[fault.reportID] { report = cached }
            else { report = try Self.getFeature(device: device, interface: interface, reportID: fault.reportID) }
            guard try fault.value(in: report) == 0 else { throw DirectEcoFlowError.unavailable }
        }
        let hidTime = Date()
        var input: EcoFlowCDCMetrics?
        // Watts are optional only when this device/firmware cannot answer CDC.
        // A failed query never invents watts from the AC-present boolean.
        if let registryID = EcoFlowUSBDiscovery.registryID(service),
           let path = EcoFlowUSBDiscovery.serialPath(deviceRegistryID: registryID) {
            sequence &+= 1
            input = try? EcoFlowSerialReader.read(path: path, sequence: sequence)
        }
        return PowerTelemetry(
            deviceName: name.replacingOccurrences(of: "EF_UPS_", with: "EcoFlow "),
            batteryPercentage: Double(charge),
            acInputWatts: input?.acInputWatts,
            totalInputWatts: input?.totalInputWatts,
            acConnected: acFlag == 1,
            sourceDescription: input?.acInputWatts != nil ? "Direct USB · AC input measured"
                : (input?.totalInputWatts != nil ? "Direct USB · input measured" : "Direct USB · input watts unavailable"),
            timestamp: input?.timestamp ?? hidTime
        )
    }

    static var powerManagerIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            ($0.bundleURL?.path.lowercased().contains("powermanager") ?? false)
                || $0.localizedName?.lowercased() == "powermanager"
        }
    }

    private static func getDescriptor(device: IOUSBHostDevice, interface: UInt8) throws -> Data {
        try transfer(device: device, requestType: 0x81, request: 6, value: 0x2200, interface: interface, length: 4096)
    }

    private static func getFeature(device: IOUSBHostDevice, interface: UInt8, reportID: UInt8) throws -> Data {
        try transfer(device: device, requestType: 0xa1, request: 1, value: 0x0300 | UInt16(reportID), interface: interface, length: 128)
    }

    private static func transfer(device: IOUSBHostDevice, requestType: UInt8, request: UInt8,
                                 value: UInt16, interface: UInt8, length: Int) throws -> Data {
        guard let data = NSMutableData(length: length) else { throw DirectEcoFlowError.unavailable }
        var transferred = 0
        let query = IOUSBDeviceRequest(bmRequestType: requestType, bRequest: request, wValue: value,
                                       wIndex: UInt16(interface), wLength: UInt16(length))
        try device.__send(query, data: data, bytesTransferred: &transferred, completionTimeout: 1)
        guard transferred > 0, transferred <= length else { throw DirectEcoFlowError.invalidReport }
        return (data as Data).prefix(transferred)
    }
}

struct EcoFlowUSBDiscoveredDevice: Equatable, Sendable {
    let registryID: UInt64
    let serialNumber: String
    let name: String
}

enum EcoFlowUSBDiscovery {
    struct SerialEndpoint: Equatable {
        let path: String
        let deviceRegistryID: UInt64
    }
    /// Registry metadata only: listing stations never opens a USB device or CDC
    /// port, and never sends a request to a station.
    static func availableDevices() -> [EcoFlowUSBDiscoveredDevice] {
        guard let devices = try? deviceServices() else { return [] }
        defer { devices.forEach { IOObjectRelease($0) } }
        return devices.compactMap { service in
            guard let registryID = registryID(service) else { return nil }
            return EcoFlowUSBDiscoveredDevice(registryID: registryID,
                serialNumber: serialNumber(service),
                name: (stringProperty(service, "USB Product Name") ?? "EcoFlow")
                    .replacingOccurrences(of: "EF_UPS_", with: "EcoFlow "))
        }
    }

    static func deviceService(serialNumber: String = "") throws -> io_service_t {
        let devices = try deviceServices()
        let selected: Int
        do { selected = try selectedDeviceIndex(serialNumbers: devices.map { self.serialNumber($0) }, selectedSerial: serialNumber) }
        catch {
            devices.forEach { IOObjectRelease($0) }
            throw error
        }
        for (index, service) in devices.enumerated() where index != selected { IOObjectRelease(service) }
        return devices[selected]
    }

    /// Pure selection seam used by both USB transport and regression tests.
    /// A missing selected station never falls back to the first USB device.
    static func selectedDeviceIndex(serialNumbers: [String], selectedSerial: String) throws -> Int {
        func normalize(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        let target = normalize(selectedSerial)
        let matches = serialNumbers.indices.filter { target.isEmpty || normalize(serialNumbers[$0]) == target }
        guard matches.count == 1, let selected = matches.first else {
            throw matches.isEmpty ? DirectEcoFlowError.noDevice : DirectEcoFlowError.multipleDevices
        }
        return selected
    }

    private static func deviceServices() throws -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            throw DirectEcoFlowError.unavailable
        }
        defer { IOObjectRelease(iterator) }
        var devices: [io_service_t] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if isEcoFlow(entry) { devices.append(entry) } else { IOObjectRelease(entry) }
        }
        return devices
    }

    static func serialPath(deviceRegistryID: UInt64) -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var endpoints: [SerialEndpoint] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let path = stringProperty(entry, "IOCalloutDevice"), path.hasPrefix("/dev/cu.") else { continue }
            var parent = entry
            IOObjectRetain(parent)
            defer { IOObjectRelease(parent) }
            for _ in 0..<16 {
                if isEcoFlow(parent) {
                    if let registryID = registryID(parent) {
                        endpoints.append(SerialEndpoint(path: path, deviceRegistryID: registryID))
                    }
                    break
                }
                var next: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(parent, kIOServicePlane, &next) == KERN_SUCCESS else { break }
                IOObjectRelease(parent)
                parent = next
            }
        }
        return serialPath(in: endpoints, deviceRegistryID: deviceRegistryID)
    }

    static func serialPath(in endpoints: [SerialEndpoint], deviceRegistryID: UInt64) -> String? {
        endpoints.filter { $0.deviceRegistryID == deviceRegistryID }.map(\.path).sorted().first
    }

    static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    static func registryID(_ entry: io_registry_entry_t) -> UInt64? {
        var value: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &value) == KERN_SUCCESS else { return nil }
        return value
    }

    private static func serialNumber(_ entry: io_registry_entry_t) -> String {
        (stringProperty(entry, "USB Serial Number") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isEcoFlow(_ entry: io_registry_entry_t) -> Bool {
        let vendor = IORegistryEntryCreateCFProperty(entry, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        let product = IORegistryEntryCreateCFProperty(entry, "idProduct" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        return vendor?.intValue == 0x3746 && product?.intValue == 0xffff
    }
}

enum EcoFlowUSBDescriptor {
    static func hidInterface(device: IOUSBHostDevice) throws -> UInt8 {
        guard let configuration = device.configurationDescriptor else { throw DirectEcoFlowError.unsupportedDevice }
        let count = Int(UInt16(littleEndian: configuration.pointee.wTotalLength))
        guard count >= 9, count <= 4096 else { throw DirectEcoFlowError.invalidReport }
        let bytes = [UInt8](Data(bytes: configuration, count: count))
        var index = 0
        while index + 2 <= bytes.count {
            let size = Int(bytes[index])
            guard size >= 2, index + size <= bytes.count else { throw DirectEcoFlowError.invalidReport }
            if bytes[index+1] == 4, size >= 9, bytes[index+5] == 3, bytes[index+3] == 0 { return bytes[index+2] }
            index += size
        }
        throw DirectEcoFlowError.unsupportedDevice
    }
}

struct EcoFlowHIDField {
    let page: UInt32
    let usage: UInt32
    let reportID: UInt8
    let kind: UInt8
    let offset: Int
    let size: Int

    func value(in data: Data) throws -> Int {
        let bytes = [UInt8](data)
        let prefix = reportID == 0 ? 0 : 8
        guard reportID == 0 || bytes.first == reportID,
              size > 0, size <= 32, offset + prefix + size <= bytes.count * 8 else { throw DirectEcoFlowError.invalidReport }
        var result: UInt32 = 0
        for bit in 0..<size {
            let position = prefix + offset + bit
            if (bytes[position / 8] & (1 << (position % 8))) != 0 { result |= 1 << bit }
        }
        return Int(result)
    }
}

/// Parses the standard USB HID descriptor rather than assuming firmware report
/// IDs/bit offsets. Only Feature fields for battery/AC state are queried.
enum EcoFlowHIDDescriptor {
    private struct Global {
        var page: UInt32 = 0
        var size = 0
        var count = 0
        var reportID: UInt8 = 0
    }

    static func fields(_ data: Data) throws -> [EcoFlowHIDField] {
        let bytes = [UInt8](data)
        var global = Global(), stack: [Global] = []
        var usages: [UInt32] = [], minimum: UInt32?, maximum: UInt32?
        var offsets: [String: Int] = [:], result: [EcoFlowHIDField] = []
        var cursor = 0
        while cursor < bytes.count {
            let prefix = bytes[cursor]
            cursor += 1
            if prefix == 0xfe {
                guard cursor + 2 <= bytes.count else { throw DirectEcoFlowError.invalidReport }
                let size = Int(bytes[cursor]); cursor += 2
                guard cursor + size <= bytes.count else { throw DirectEcoFlowError.invalidReport }
                cursor += size; continue
            }
            let size = (prefix & 3) == 3 ? 4 : Int(prefix & 3)
            guard cursor + size <= bytes.count else { throw DirectEcoFlowError.invalidReport }
            var value: UInt32 = 0
            for index in 0..<size { value |= UInt32(bytes[cursor+index]) << (8 * index) }
            cursor += size
            let type = (prefix >> 2) & 3, tag = prefix >> 4
            if type == 1 {
                switch tag {
                case 0: global.page = value
                case 7: global.size = Int(value)
                case 8:
                    guard value > 0, value <= 255 else { throw DirectEcoFlowError.invalidReport }
                    global.reportID = UInt8(value)
                case 9: global.count = Int(value)
                case 10:
                    guard stack.count < 16 else { throw DirectEcoFlowError.invalidReport }
                    stack.append(global)
                case 11:
                    guard let previous = stack.popLast() else { throw DirectEcoFlowError.invalidReport }
                    global = previous
                default: break
                }
            } else if type == 2 {
                let usage = size == 4 ? value : (global.page << 16) | value
                if tag == 0 { usages.append(usage) }
                if tag == 1 { minimum = usage }
                if tag == 2 { maximum = usage }
            } else if type == 0 {
                if [8, 9, 11].contains(tag) {
                    guard global.size >= 0, global.size <= 32, global.count >= 0, global.count <= 1024 else { throw DirectEcoFlowError.invalidReport }
                    let kind: UInt8 = tag == 8 ? 1 : (tag == 9 ? 2 : 3)
                    let key = "\(kind):\(global.reportID)"
                    let start = offsets[key] ?? 0
                    if usages.isEmpty, let minimum, let maximum, maximum >= minimum, maximum - minimum <= 1024 {
                        usages = Array(minimum...maximum)
                    }
                    for index in 0..<global.count {
                        guard let usage = usages.isEmpty ? nil : usages[min(index, usages.count - 1)] else { continue }
                        result.append(EcoFlowHIDField(page: usage >> 16, usage: usage & 0xffff, reportID: global.reportID,
                                                    kind: kind, offset: start + index * global.size, size: global.size))
                    }
                    let end = start + global.count * global.size
                    guard end <= 32768 else { throw DirectEcoFlowError.invalidReport }
                    offsets[key] = end
                }
                usages = []; minimum = nil; maximum = nil
            }
        }
        return result
    }
}

struct EcoFlowCDCMetrics {
    let acInputWatts: Double?
    let totalInputWatts: Double?
    let timestamp: Date
}

/// USB CDC telemetry framing documented by greyltc/r3pcomms (MIT); reads only
/// the total-input and AC-input segments. No serial-number query is performed.
enum EcoFlowCDCProtocol {
    static func request(sequence: UInt32) -> [UInt8] {
        var packet: [UInt8] = [0xaa, 0x03, 0, 0, 0xde, 0x2d]
        packet += (0..<4).map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) }
        packet += [0xff, 0xff, 0x22, 0x02, 0x01, 0x01, 0x66, 0x02]
        let checksum = crc(packet)
        packet += [UInt8(truncatingIfNeeded: checksum), UInt8(checksum >> 8)]
        return packet
    }

    static func crc(_ bytes: [UInt8]) -> UInt16 {
        bytes.reduce(UInt16(0)) { previous, byte in
            var checksum = previous ^ UInt16(byte)
            for _ in 0..<8 { checksum = checksum & 1 == 1 ? (checksum >> 1) ^ 0xa001 : checksum >> 1 }
            return checksum
        }
    }

    static func metrics(frame: [UInt8], sequence: UInt32, now: Date = Date()) throws -> EcoFlowCDCMetrics {
        guard frame.count >= 24, frame.count <= 4096, frame[0] == 0xaa, frame[1] == 0x03,
              frame.count == 20 + Int(frame[2]) + (Int(frame[3]) << 8), crc(frame) == 0,
              frame[16] == 0x66, frame[17] == 0x02 else { throw DirectEcoFlowError.invalidReport }
        let receivedSequence = (0..<4).reduce(UInt32(0)) { $0 | UInt32(frame[6+$1]) << ($1 * 8) }
        guard receivedSequence == sequence else { throw DirectEcoFlowError.invalidReport }
        var decoded = frame
        for index in 18..<(frame.count - 2) { decoded[index] ^= UInt8(truncatingIfNeeded: sequence) }
        var values: [Int: Double] = [:]
        var cursor = 22
        while cursor < decoded.count - 2 {
            guard cursor + 3 <= decoded.count - 2 else { throw DirectEcoFlowError.invalidReport }
            let tag = Int(decoded[cursor]) | Int(decoded[cursor+1]) << 8
            let size = Int(decoded[cursor+2]); cursor += 3
            guard cursor + size <= decoded.count - 2 else { throw DirectEcoFlowError.invalidReport }
            if [8, 9].contains(tag), size == 4 {
                let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(decoded[cursor+$1]) << ($1 * 8) }
                let watts = Double(Float(bitPattern: bits))
                if watts.isFinite && watts >= 0 && watts <= 100_000 { values[tag] = watts }
            }
            cursor += size
        }
        return EcoFlowCDCMetrics(acInputWatts: values[9], totalInputWatts: values[8], timestamp: now)
    }
}

enum EcoFlowSerialReader {
    static func read(path: String, sequence: UInt32) throws -> EcoFlowCDCMetrics {
        try EcoFlowCDCProtocol.metrics(frame: readFrame(path: path, sequence: sequence), sequence: sequence)
    }

    static func readFrame(path: String, sequence: UInt32) throws -> [UInt8] {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw DirectEcoFlowError.serialBusy }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw DirectEcoFlowError.serialBusy }
        defer { flock(fd, LOCK_UN) }
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { throw DirectEcoFlowError.unavailable }
        var settings = original
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetispeed(&settings, speed_t(B115200)); cfsetospeed(&settings, speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else { throw DirectEcoFlowError.unavailable }
        defer { tcsetattr(fd, TCSANOW, &original) }
        tcflush(fd, TCIFLUSH)
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
        let request = EcoFlowCDCProtocol.request(sequence: sequence)
        var sent = 0
        while sent < request.count {
            try ready(fd: fd, events: Int16(POLLOUT), deadline: deadline)
            let count = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress?.advanced(by: sent), request.count - sent) }
            if count < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { continue }
            guard count > 0 else { throw DirectEcoFlowError.unavailable }
            sent += count
        }
        var frame: [UInt8] = []
        var expected = 4
        while frame.count < expected {
            try ready(fd: fd, events: Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: min(4096, expected - frame.count))
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { continue }
            guard count > 0 else { throw DirectEcoFlowError.unavailable }
            frame += bytes.prefix(count)
            if frame.count == 4 {
                expected = 20 + Int(frame[2]) + (Int(frame[3]) << 8)
                guard expected >= 24, expected <= 4096 else { throw DirectEcoFlowError.invalidReport }
            }
        }
        return frame
    }

    private static func ready(fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw DirectEcoFlowError.serialTimeout }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32((deadline - now + 999_999) / 1_000_000)
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result > 0, descriptor.revents & events != 0 else { throw DirectEcoFlowError.serialTimeout }
            return
        }
    }
}
