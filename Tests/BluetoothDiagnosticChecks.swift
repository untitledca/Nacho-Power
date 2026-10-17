import Foundation

/// Pure session/packet inspection. No CoreBluetooth manager, live device,
/// installed app, or default support log is opened by this executable.
@main
private struct BluetoothDiagnosticChecks {
    static func main() throws {
        var state = EcoFlowBluetoothSessionState()
        state.ingest(.init(battery: 87, acWatts: 0, totalWatts: 0, acInputVoltage: 121), at: time(0))
        let early = state.diagnosticDetails(at: time(0))
        check(early["reason"] as? String == "not_authenticated" && early["authenticated"] as? Bool == false,
              "A pre-auth diagnostic does not imply an authorized connection")
        check(early["batteryPercentage"] == nil && early["acInputVoltage"] == nil && early["acConnected"] == nil,
              "Buffered measurements remain private until owner authentication succeeds")
        state.authenticate(at: time(0))
        let fresh = state.diagnosticDetails(at: time(2))
        check(fresh["reason"] as? String == "input_voltage" && fresh["acStatus"] as? String == "connected",
              "Fresh input voltage explains AC detection")
        check(fresh["acVoltageAge"] as? Double == 2 && fresh["streamAge"] as? Double == 2 &&
              fresh["hasACFlag"] as? Bool == false && fresh["hasACVoltage"] as? Bool == true,
              "Diagnostics distinguish voltage fallback from an explicit AC flag")
        check(state.takeRuntimeRequest(at: time(0.5)), "Inspecting diagnostics does not consume a runtime-poll slot")
        state.ingest(.init(battery: 87), at: time(7))
        let stale = state.diagnosticDetails(at: time(7))
        check(stale["reason"] as? String == "voltage_stale" && stale["acStatus"] as? String == "unknown" &&
              stale["acVoltageAge"] as? Double == 7 && stale["streamAge"] as? Double == 0,
              "Stale voltage is visible even when battery packets keep the connection alive")
        check(stale["acInputVoltage"] as? Double == 121 && stale["acConnected"] == nil,
              "An aged measurement is reported with its age, without asserting current AC presence")
        state.ingest(.init(acInputVoltage: 25), at: time(8))
        check(state.diagnosticDetails(at: time(8))["reason"] as? String == "voltage_ambiguous",
              "An ambiguous live input voltage has a distinct reason")
        state.ingest(.init(acInputVoltage: 0), at: time(9))
        check(state.diagnosticDetails(at: time(9))["acStatus"] as? String == "disconnected",
              "Valid near-zero input voltage is reported as disconnected")
        state.ingest(.init(acInputVoltage: 121), at: time(10))
        state.ingest(.init(acConnected: false), at: time(11))
        let explicit = state.diagnosticDetails(at: time(11))
        check(explicit["reason"] as? String == "explicit_flag" && explicit["acConnected"] as? Bool == false,
              "Diagnostics preserve the explicit-flag precedence of the production reader")
        check(state.diagnosticDetails(at: time(27))["reason"] as? String == "stream_stale",
              "A completely silent stream is distinguishable from missing voltage alone")
        state.reset()
        check(state.diagnosticDetails(at: time(28))["acInputVoltage"] == nil &&
              state.diagnosticDetails(at: time(28))["hasACVoltage"] as? Bool == false,
              "Diagnostics cannot retain readings across session reset")

        var missing = EcoFlowBluetoothSessionState()
        missing.authenticate(at: time(0))
        check(missing.diagnosticDetails(at: time(0))["reason"] as? String == "field_missing",
              "A newly authenticated session explains its lack of observations")
        missing.ingest(.init(battery: 75), at: time(1))
        check(missing.diagnosticDetails(at: time(1))["reason"] as? String == "voltage_missing",
              "A firmware payload without AC fields has an explicit missing-voltage reason")

        let secret = Array("DO-NOT-RETAIN person@example.com /Users/private".utf8)
        var payload = field(68, wire: 5)
        payload.append(contentsOf: float(121))
        payload.append(contentsOf: field(202, wire: 0))
        payload.append(1)
        payload.append(contentsOf: field(500, wire: 2))
        payload.append(contentsOf: varint(UInt64(secret.count)))
        payload.append(contentsOf: secret)
        let packet = EcoFlowWirelessProtocol.Packet(source: 2, commandSet: 0xfe, command: 0x16, payload: payload)
        let schema = EcoFlowBluetoothSessionState.diagnosticPacketDetails(packet)
        check(schema["commandSet"] as? Int == 254 && schema["commandID"] as? Int == 22 &&
              schema["payloadBytes"] as? Int == payload.count && schema["fieldIDs"] as? [Int] == [68, 202, 500],
              "Packet diagnostics retain numeric schema and size only")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
        check(!json.contains("DO-NOT-RETAIN") && !json.contains("example.com") && !json.contains("/Users/"),
              "Length-delimited payload contents never enter diagnostics")
        let auth = EcoFlowWirelessProtocol.Packet(source: 0x35, commandSet: 0x35, command: 0x86, payload: secret)
        let authDetails = EcoFlowBluetoothSessionState.diagnosticPacketDetails(auth)
        check(authDetails["fieldIDs"] == nil && authDetails["payloadBytes"] as? Int == secret.count,
              "Authentication payloads are never parsed for diagnostic fields")
        let malformed = EcoFlowWirelessProtocol.Packet(source: 2, commandSet: 0xfe, command: 0x16,
            payload: field(68, wire: 5) + [1])
        check(EcoFlowBluetoothSessionState.diagnosticPacketDetails(malformed)["fieldIDs"] as? [Int] == [],
              "A truncated field does not crash inspection or claim successful parsing")
        let many = EcoFlowWirelessProtocol.Packet(source: 2, commandSet: 0xfe, command: 0x16,
            payload: (1...100).flatMap { field($0, wire: 0) + [0] })
        check((EcoFlowBluetoothSessionState.diagnosticPacketDetails(many)["fieldIDs"] as? [Int])?.count == 64,
              "Schema inspection has a fixed bound")
        check(SupportDiagnostics.sanitize(fresh).count == fresh.count && SupportDiagnostics.sanitize(schema).count == schema.count,
              "The logger accepts the supported structured session and schema fields")
        print("PASS Bluetooth diagnostics: authentication privacy, AC freshness reasons, age reporting, explicit-flag precedence, reset isolation, and numeric-only bounded packet schema")
    }

    private static func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_760_000_000 + seconds) }
    private static func field(_ id: Int, wire: Int) -> [UInt8] { varint(UInt64((id << 3) | wire)) }
    private static func float(_ value: Float) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
    }
    private static func varint(_ input: UInt64) -> [UInt8] {
        var value = input, bytes: [UInt8] = []
        repeat {
            let byte = UInt8(value & 0x7f)
            value >>= 7
            bytes.append(value == 0 ? byte : byte | 0x80)
        } while value > 0
        return bytes
    }
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL \(message)\n", stderr)
            exit(1)
        }
    }
}
