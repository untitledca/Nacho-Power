import Foundation

@main
struct DirectEcoFlowChecks {
    static func main() async throws {
        try protocolChecks()
        try descriptorChecks()
        telemetryDecisionChecks()
        if CommandLine.arguments.contains("--live") {
            let monitor = DirectEcoFlowMonitor()
            for _ in 0..<3 {
                let sample = try await monitor.snapshot()
                check(sample.batteryPercentage != nil && sample.acConnected != nil, "Live USB battery/AC state")
                print("Live: \(sample.deviceName), battery=\(sample.batteryPercentage!), AC=\(sample.acConnected!), input=\(sample.totalInputWatts.map(String.init(describing:)) ?? "unknown")")
            }
        }
        print("Direct EcoFlow checks passed")
    }

    static func telemetryDecisionChecks() {
        func reading(_ connected: Bool?, total: Double?, dedicated: Double? = nil) -> PowerTelemetry {
            PowerTelemetry(deviceName: "Test EcoFlow", batteryPercentage: 49,
                           acInputWatts: dedicated, totalInputWatts: total,
                           acConnected: connected, sourceDescription: "Test", timestamp: Date())
        }
        check(reading(false, total: 84).reminderInputWatts == 0, "Solar input does not imply AC connected")
        check(reading(true, total: 981).reminderInputWatts == 981, "Verified firmware uses combined input with AC present")
        check(reading(true, total: 84, dedicated: 0).reminderInputWatts == 0, "Dedicated AC zero takes precedence over solar")
        check(reading(nil, total: 981).reminderInputWatts == nil, "Unknown AC presence cannot finish a reminder")
        check(reading(true, total: nil).reminderInputWatts == nil, "AC present cannot fabricate input watts")
    }

    static func protocolChecks() throws {
        let request = EcoFlowCDCProtocol.request(sequence: 0)
        check(request == hex("aa030000de2d00000000ffff22020101660286ef"), "Published read-only telemetry request")
        check(EcoFlowCDCProtocol.crc(request) == 0, "Request CRC")
        let sample = try EcoFlowCDCProtocol.metrics(frame: fixture(total: 84, ac: 0, sequence: 23), sequence: 23)
        check(sample.totalInputWatts == 84 && sample.acInputWatts == 0, "Solar is distinct from AC watts")
        let charging = try EcoFlowCDCProtocol.metrics(frame: fixture(total: 1200, ac: 1200, sequence: 24), sequence: 24)
        check(charging.acInputWatts == 1200, "Positive dedicated AC watts")
        let minimal = try EcoFlowCDCProtocol.metrics(frame: fixture(total: 0, ac: nil, sequence: 25), sequence: 25)
        check(minimal.totalInputWatts == 0 && minimal.acInputWatts == nil, "Absent AC field remains unknown")
        let malformed = try EcoFlowCDCProtocol.metrics(frame: fixture(total: .nan, ac: -.infinity, sequence: 26), sequence: 26)
        check(malformed.totalInputWatts == nil && malformed.acInputWatts == nil, "Non-finite watts rejected")
        let absurd = try EcoFlowCDCProtocol.metrics(frame: fixture(total: .greatestFiniteMagnitude, ac: 100_001, sequence: 36), sequence: 36)
        check(absurd.totalInputWatts == nil && absurd.acInputWatts == nil, "Absurd finite watts rejected")
        var corrupt = fixture(total: 0, ac: 0, sequence: 27)
        corrupt[23] ^= 1
        rejects("Bad CRC") { _ = try EcoFlowCDCProtocol.metrics(frame: corrupt, sequence: 27) }
        rejects("Wrong response sequence") { _ = try EcoFlowCDCProtocol.metrics(frame: fixture(total: 0, ac: 0, sequence: 28), sequence: 29) }
        rejects("Truncated packet") { _ = try EcoFlowCDCProtocol.metrics(frame: Array(fixture(total: 0, ac: 0, sequence: 30).dropLast()), sequence: 30) }
        var wrongCommand = fixture(total: 0, ac: 0, sequence: 31)
        wrongCommand[16] = 0x67
        wrongCommand.removeLast(2)
        let crc = EcoFlowCDCProtocol.crc(wrongCommand)
        wrongCommand += [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8)]
        rejects("Wrong response opcode") { _ = try EcoFlowCDCProtocol.metrics(frame: wrongCommand, sequence: 31) }
    }

    static func descriptorChecks() throws {
        // Standard HID short items: Battery System page; report12 capacity;
        // report7 Charging/Discharging/ACPresent/BatteryPresent feature bits.
        let bytes: [UInt8] = [0x05, 0x85, 0x85, 12, 0x75, 8, 0x95, 1, 0x09, 0x66, 0xb1, 2,
                             0x85, 7, 0x75, 1, 0x95, 4,
                             0x09, 0x44, 0x09, 0x45, 0x09, 0xd0, 0x09, 0xd1, 0xb1, 2]
        let fields = try EcoFlowHIDDescriptor.fields(Data(bytes))
        let capacity = fields.first { $0.usage == 0x66 }!
        let ac = fields.first { $0.usage == 0xd0 }!
        check(capacity.reportID == 12 && capacity.offset == 0 && capacity.kind == 3, "Battery feature mapping")
        check(ac.reportID == 7 && ac.offset == 2 && ac.size == 1 && ac.kind == 3, "AC-present feature mapping")
        try check(capacity.value(in: Data([12, 95])) == 95, "Verified DELTA3Plus battery report")
        try check(ac.value(in: Data([7, 8, 0])) == 0, "Verified DELTA3Plus absent-AC flag")
        try check(ac.value(in: Data([7, 12, 0])) == 1, "AC-present bit")
        rejects("Wrong HID report ID") { _ = try ac.value(in: Data([12, 12, 0])) }
        rejects("Truncated HID report") { _ = try capacity.value(in: Data([12])) }
        rejects("Malformed HID descriptor") { _ = try EcoFlowHIDDescriptor.fields(Data([0x75])) }
        rejects("Invalid report size") { _ = try EcoFlowHIDDescriptor.fields(Data([0x75, 64, 0x95, 1, 0x09, 0x66, 0xb1, 2])) }
    }

    static func fixture(total: Float, ac: Float?, sequence: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [0xaa, 3, 0, 0, 0x39, 0x2f]
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) }
        bytes += [1, 0x44, 2, 0x22, 1, 1, 0x66, 2, 1, 1, 0, 0]
        for (tag, value) in [(UInt8(8), total)] + (ac.map { [(UInt8(9), $0)] } ?? []) {
            bytes += [tag, 0, 4]
            bytes += (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
        }
        let variable = bytes.count + 2 - 20
        bytes[2] = UInt8(truncatingIfNeeded: variable); bytes[3] = UInt8(variable >> 8)
        for index in 18..<bytes.count { bytes[index] ^= UInt8(truncatingIfNeeded: sequence) }
        let crc = EcoFlowCDCProtocol.crc(bytes)
        bytes += [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8)]
        return bytes
    }

    static func hex(_ string: String) -> [UInt8] {
        stride(from: 0, to: string.count, by: 2).map { index in
            let start = string.index(string.startIndex, offsetBy: index)
            return UInt8(string[start..<string.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    static func check(_ result: @autoclosure () throws -> Bool, _ message: String) rethrows {
        let value = try result()
        precondition(value, message)
    }

    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Accepted invalid data: \(message)") }
        catch { }
    }
}
