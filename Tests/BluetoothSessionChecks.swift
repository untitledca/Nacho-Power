import Foundation

@main
private struct BluetoothSessionChecks {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func time(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        func update(battery: Double? = nil, ac: Bool? = nil, watts: Double? = nil,
                    total: Double? = nil) -> EcoFlowWirelessProtocol.Metrics {
            .init(battery: battery, acWatts: watts, totalWatts: total, acConnected: ac)
        }
        func snapshot(_ state: EcoFlowBluetoothSessionState, _ seconds: TimeInterval) -> PowerTelemetry? {
            state.snapshot(deviceName: "Fixture DELTA 3 Plus", at: time(seconds))
        }

        var state = EcoFlowBluetoothSessionState()
        check(!state.isAuthenticated && snapshot(state, 0) == nil, "empty session cannot display telemetry")
        state.ingest(update(battery: 87, ac: true, watts: 0, total: 400), at: time(0))
        check(!state.isAuthenticated && snapshot(state, 1) == nil, "early full upload is private before owner authentication")
        state.ingest(update(battery: 86.9), at: time(1))
        check(snapshot(state, 1) == nil, "incremental upload cannot authorize display")
        state.authenticate(at: time(2))
        let initial = snapshot(state, 2)
        check(initial?.batteryPercentage == 86.9 && initial?.acConnected == true,
              "authentication reveals merged early full and incremental uploads")
        check(initial?.acInputWatts == 0 && initial?.totalInputWatts == 400,
              "AC presence remains true at zero AC watts with independent solar/DC input")
        check(initial?.timestamp == time(1), "authentication never fabricates a newer observation timestamp")
        state.ingest(update(battery: 86.8), at: time(3))
        check(snapshot(state, 3)?.batteryPercentage == 86.8 && snapshot(state, 3)?.acConnected == true,
              "battery-only upload after auth preserves AC from the early full upload")

        var delayedAuth = EcoFlowBluetoothSessionState()
        delayedAuth.ingest(update(battery: 87, ac: true), at: time(0))
        delayedAuth.authenticate(at: time(16))
        check(snapshot(delayedAuth, 16) == nil && delayedAuth.streamIsStale(at: time(16)),
              "late auth success cannot refresh or reveal stale pre-auth telemetry")

        // Firmware need not repeat an unchanged AC Boolean with each battery update.
        for second in stride(from: 10, through: 130, by: 10) {
            state.ingest(update(battery: 86), at: time(Double(second)))
            check(snapshot(state, Double(second))?.acConnected == true,
                  "continuous incremental telemetry retains AC beyond ninety seconds")
        }
        let retained = snapshot(state, 130)
        check(retained?.acInputWatts == nil && retained?.totalInputWatts == nil,
              "periodic watt measurements still expire independently")
        state.ingest(update(ac: false, watts: 0), at: time(131))
        check(snapshot(state, 131)?.acConnected == false, "explicit false immediately overrides retained true at zero watts")
        state.ingest(update(battery: 85), at: time(140))
        check(snapshot(state, 140)?.acConnected == false, "missing field preserves explicit disconnected status")
        state.ingest(update(ac: true, watts: 0), at: time(141))
        check(snapshot(state, 141)?.acConnected == true, "reconnect at zero watts immediately restores AC presence")

        check(!state.streamIsStale(at: time(156)) && snapshot(state, 156) != nil,
              "fifteen-second boundary matches stream watchdog")
        check(state.streamIsStale(at: time(156.01)) && snapshot(state, 156.01) == nil,
              "stalled stream suppresses every reading after fifteen seconds")
        state.ingest(update(), at: time(157))
        check(state.streamIsStale(at: time(157)) && snapshot(state, 157) == nil,
              "empty/unrecognized metrics cannot keep a session alive")

        let expired = state.ingest(update(battery: 84), at: time(200))
        check(expired == .expiredSession && !state.isAuthenticated && snapshot(state, 200) == nil,
              "late battery packet cannot revive retained AC before the polling watchdog runs")
        state.ingest(update(battery: 83), at: time(201))
        check(snapshot(state, 201) == nil, "expired session needs a new owner acknowledgment")
        state.authenticate(at: time(202))
        check(snapshot(state, 202)?.acConnected == nil, "fresh authentication after expiry cannot recover old AC")

        state.reset()
        check(!state.isAuthenticated && snapshot(state, 158) == nil, "disconnect clears authentication and readings")
        state.ingest(update(battery: 84), at: time(159))
        state.authenticate(at: time(160))
        check(snapshot(state, 160)?.batteryPercentage == 84 && snapshot(state, 160)?.acConnected == nil,
              "new session cannot inherit the prior station's AC flag")
        state.ingest(update(watts: 1000, total: 1500), at: time(161))
        check(snapshot(state, 161)?.acConnected == nil, "missing initial AC flag cannot be inferred from input watts")

        var rejected = EcoFlowBluetoothSessionState()
        rejected.ingest(update(battery: 87, ac: true), at: time(0))
        rejected.reset() // The monitor's failure path always tears down the session.
        rejected.authenticate(at: time(2))
        check(snapshot(rejected, 2) == nil, "failed authentication clears buffered data before another attempt")
        check(!rejected.streamIsStale(at: time(17)) && rejected.streamIsStale(at: time(17.01)),
              "successful auth without readings gets a bounded fifteen-second startup grace")

        var batteryAge = EcoFlowBluetoothSessionState()
        batteryAge.ingest(update(battery: 90, ac: false), at: time(0))
        batteryAge.authenticate(at: time(1))
        for second in stride(from: 10, through: 100, by: 10) {
            batteryAge.ingest(update(watts: 0), at: time(Double(second)))
        }
        check(snapshot(batteryAge, 100)?.batteryPercentage == nil && snapshot(batteryAge, 100)?.acConnected == false,
              "old battery expires while live session preserves known AC")
        // Exercise the monitor's actual packet-routing seam. Field 202's
        // explicit true is a varint; field 262 battery is fixed32/Float.
        let fullPacket = EcoFlowWirelessProtocol.Packet(source: 2, commandSet: 0xfe, command: 0x15,
            payload: [0xd0, 0x0c, 1, 0xb5, 0x10, 0, 0, 0xae, 0x42]) // AC true, battery 87
        let batteryPacket = EcoFlowWirelessProtocol.Packet(source: 2, commandSet: 0xfe, command: 0x15,
            payload: [0xb5, 0x10, 0, 0, 0xac, 0x42]) // battery 86
        let statusReply = EcoFlowWirelessProtocol.Packet(source: 0x35, commandSet: 0x35, command: 0x89, payload: [0])
        let ownerReply = EcoFlowWirelessProtocol.Packet(source: 0x35, commandSet: 0x35, command: 0x86, payload: [0])
        var routed = EcoFlowBluetoothSessionState()
        check(try routed.receive(fullPacket, stage: .awaitingStatus, at: time(0)) == .telemetryReceived,
              "full upload preceding auth-status reply follows real telemetry route")
        check(snapshot(routed, 0) == nil, "routed early upload is hidden")
        check(try routed.receive(ownerReply, stage: .awaitingStatus, at: time(0.5)) == .ignored && !routed.isAuthenticated,
              "unsolicited owner acknowledgment before owner request cannot authorize display")
        check(try routed.receive(statusReply, stage: .awaitingStatus, at: time(1)) == .requestOwnerAuthentication,
              "auth-status reply requests owner authentication")
        check(try routed.receive(batteryPacket, stage: .awaitingOwnerAcknowledgment, at: time(2)) == .telemetryReceived,
              "incremental upload during owner authentication is retained")
        check(snapshot(routed, 2) == nil, "telemetry during owner authentication cannot promote readiness")
        check(try routed.receive(ownerReply, stage: .awaitingOwnerAcknowledgment, at: time(3)) == .ownerAccepted,
              "only valid owner acknowledgment exposes the merged session")
        check(snapshot(routed, 3)?.acConnected == true && snapshot(routed, 3)?.batteryPercentage == 86,
              "routing retains early AC while accepting later battery value")
        do {
            _ = try routed.receive(batteryPacket, stage: .authenticated, at: time(19))
            preconditionFailure("Late routed upload must require reconnection")
        } catch { }
        check(!routed.isAuthenticated && snapshot(routed, 19) == nil,
              "real packet route resets a stale session before rejecting late telemetry")

        var stalledBeforeOwner = EcoFlowBluetoothSessionState()
        _ = try stalledBeforeOwner.receive(fullPacket, stage: .awaitingStatus, at: time(0))
        do {
            _ = try stalledBeforeOwner.receive(batteryPacket, stage: .awaitingOwnerAcknowledgment, at: time(16))
            preconditionFailure("Late pre-auth battery upload must require reconnection")
        } catch { }
        check(!stalledBeforeOwner.isAuthenticated && snapshot(stalledBeforeOwner, 16) == nil,
              "pre-auth stream gap clears buffered AC before accepting a partial upload")
        _ = try stalledBeforeOwner.receive(ownerReply, stage: .awaitingOwnerAcknowledgment, at: time(17))
        check(snapshot(stalledBeforeOwner, 17) == nil,
              "owner acknowledgment after a rejected pre-auth partial cannot expose old AC")

        var failedOwner = EcoFlowBluetoothSessionState()
        _ = try failedOwner.receive(fullPacket, stage: .awaitingStatus, at: time(0))
        let rejection = EcoFlowWirelessProtocol.Packet(source: 0x35, commandSet: 0x35, command: 0x86, payload: [1])
        do {
            _ = try failedOwner.receive(rejection, stage: .awaitingOwnerAcknowledgment, at: time(1))
            preconditionFailure("Failed owner acknowledgment must reject the session")
        } catch { }
        _ = try failedOwner.receive(ownerReply, stage: .awaitingOwnerAcknowledgment, at: time(2))
        check(snapshot(failedOwner, 2) == nil, "actual rejected acknowledgment clears early AC and battery")

        // RuntimePropertyUpload field 68 is the AC-input voltage, independently
        // refreshed by polling. Field 67 is output voltage and must be ignored.
        func runtimePacket(_ voltage: Float, field: UInt8 = 0xa5) -> EcoFlowWirelessProtocol.Packet {
            let bits = voltage.bitPattern
            return .init(source: 2, commandSet: 0xfe, command: 0x16,
                         payload: [field, 0x04] + (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
        }
        var voltage = EcoFlowBluetoothSessionState()
        check(!voltage.takeRuntimeRequest(at: time(0)), "never poll before authentication")
        check(try voltage.receive(runtimePacket(121), stage: .awaitingStatus, at: time(0)) == .telemetryReceived,
              "runtime-only upload uses the same early-telemetry buffering route")
        check(snapshot(voltage, 0) == nil && !voltage.takeRuntimeRequest(at: time(0)),
              "early runtime data cannot authorize display or polling")
        _ = try voltage.receive(ownerReply, stage: .awaitingOwnerAcknowledgment, at: time(0.5))
        check(snapshot(voltage, 0.5)?.acConnected == true && snapshot(voltage, 0.5)?.batteryPercentage == nil,
              "fresh 121V AC-input fixture reports connected after owner acknowledgment")
        check(voltage.takeRuntimeRequest(at: time(0.5)), "first authenticated runtime request is immediate")
        check(!voltage.takeRuntimeRequest(at: time(0.5)) && !voltage.takeRuntimeRequest(at: time(2.49)),
              "repeated callers cannot request more often than two seconds")
        check(voltage.takeRuntimeRequest(at: time(2.5)), "runtime request is eligible at two seconds")
        check(snapshot(voltage, 2.5)?.timestamp == time(0), "polling does not fabricate a telemetry observation")
        _ = try voltage.receive(batteryPacket, stage: .authenticated, at: time(6))
        check(snapshot(voltage, 6)?.acConnected == true, "six-second voltage freshness boundary is inclusive")
        _ = try voltage.receive(batteryPacket, stage: .authenticated, at: time(6.01))
        check(snapshot(voltage, 6.01)?.acConnected == nil && snapshot(voltage, 6.01)?.batteryPercentage == 86,
              "continuing battery uploads cannot refresh expired voltage")
        _ = try voltage.receive(runtimePacket(0), stage: .authenticated, at: time(7))
        check(snapshot(voltage, 7)?.acConnected == false, "explicit zero-voltage fixture immediately reports unplugged")
        _ = try voltage.receive(runtimePacket(121), stage: .authenticated, at: time(8))
        check(snapshot(voltage, 8)?.acConnected == true, "fresh mains voltage reports reconnected")
        _ = try voltage.receive(runtimePacket(1.8669419), stage: .authenticated, at: time(8.1))
        check(snapshot(voltage, 8.1)?.acConnected == false,
              "observed unplugged residual voltage reports disconnected")
        _ = try voltage.receive(runtimePacket(10), stage: .authenticated, at: time(8.2))
        check(snapshot(voltage, 8.2)?.acConnected == false, "near-zero upper boundary is disconnected")
        _ = try voltage.receive(runtimePacket(10.1), stage: .authenticated, at: time(8.3))
        check(snapshot(voltage, 8.3)?.acConnected == nil, "voltage above the near-zero boundary is unknown")
        _ = try voltage.receive(runtimePacket(79.9), stage: .authenticated, at: time(8.4))
        check(snapshot(voltage, 8.4)?.acConnected == nil, "voltage below the mains boundary is unknown")
        _ = try voltage.receive(runtimePacket(25), stage: .authenticated, at: time(9))
        check(snapshot(voltage, 9)?.acConnected == nil, "ambiguous low voltage clears the voltage-derived known state")
        _ = try voltage.receive(runtimePacket(80), stage: .authenticated, at: time(10))
        check(snapshot(voltage, 10)?.acConnected == true, "conservative mains lower bound is accepted")
        _ = try voltage.receive(runtimePacket(300), stage: .authenticated, at: time(11))
        check(snapshot(voltage, 11)?.acConnected == true, "conservative mains upper bound is accepted")
        for invalid: Float in [.nan, .infinity, -.infinity, -1, 301] {
            check(try voltage.receive(runtimePacket(invalid), stage: .authenticated, at: time(12)) == .ignored,
                  "invalid voltage cannot replace or refresh a valid observation")
        }
        _ = try voltage.receive(batteryPacket, stage: .authenticated, at: time(17.01))
        check(snapshot(voltage, 17.01)?.acConnected == nil,
              "invalid voltage did not extend the previous valid voltage lifetime")

        for explicitFlag in [false, true] {
            let flagPacket = EcoFlowWirelessProtocol.Packet(source: 2, commandSet: 0xfe, command: 0x15,
                payload: [0xd0, 0x0c, explicitFlag ? 1 : 0])
            let contradictoryVoltage = runtimePacket(explicitFlag ? 0 : 121)
            for runtimeFirst in [false, true] {
                var priority = EcoFlowBluetoothSessionState()
                priority.authenticate(at: time(0))
                let packets = runtimeFirst ? [contradictoryVoltage, flagPacket] : [flagPacket, contradictoryVoltage]
                for packet in packets { _ = try priority.receive(packet, stage: .authenticated, at: time(1)) }
                check(snapshot(priority, 1)?.acConnected == explicitFlag,
                      "explicit legacy presence wins in either packet order, including explicit false")
                check(!priority.needsRuntimePolling && !priority.takeRuntimeRequest(at: time(2)),
                      "a known legacy flag stops voltage polling")
            }
        }

        var runtimeOnly = EcoFlowBluetoothSessionState()
        runtimeOnly.authenticate(at: time(0))
        check(try runtimeOnly.receive(runtimePacket(121, field: 0x9d), stage: .authenticated, at: time(1)) == .ignored,
              "AC-output voltage does not enter the AC-input route or refresh liveness")
        check(snapshot(runtimeOnly, 1) == nil, "output voltage alone cannot create a status snapshot")
        for second in stride(from: 2, through: 20, by: 2) {
            _ = try runtimeOnly.receive(runtimePacket(121), stage: .authenticated, at: time(Double(second)))
        }
        check(snapshot(runtimeOnly, 20)?.acConnected == true && !runtimeOnly.streamIsStale(at: time(20)),
              "valid runtime voltage independently keeps the authenticated telemetry stream alive")
        do {
            _ = try runtimeOnly.receive(runtimePacket(0), stage: .authenticated, at: time(36))
            preconditionFailure("Late runtime upload must require reconnection")
        } catch { }
        check(!runtimeOnly.isAuthenticated && snapshot(runtimeOnly, 36) == nil,
              "runtime uploads cannot revive a stalled session")
        runtimeOnly.authenticate(at: time(37))
        check(snapshot(runtimeOnly, 37) == nil && runtimeOnly.takeRuntimeRequest(at: time(37)),
              "reset clears voltage and the old polling cadence")
        for second in stride(from: 39, through: 51, by: 2) {
            check(runtimeOnly.takeRuntimeRequest(at: time(Double(second))), "read-only polling remains eligible during startup")
        }
        check(runtimeOnly.streamIsStale(at: time(52.01)) && !runtimeOnly.takeRuntimeRequest(at: time(52.01)),
              "requests without replies cannot postpone the fifteen-second stream watchdog")

        var rejectedVoltage = EcoFlowBluetoothSessionState()
        _ = try rejectedVoltage.receive(runtimePacket(121), stage: .awaitingOwnerAcknowledgment, at: time(0))
        do {
            _ = try rejectedVoltage.receive(rejection, stage: .awaitingOwnerAcknowledgment, at: time(1))
            preconditionFailure("Rejected owner acknowledgment must clear early voltage")
        } catch { }
        _ = try rejectedVoltage.receive(ownerReply, stage: .awaitingOwnerAcknowledgment, at: time(2))
        check(snapshot(rejectedVoltage, 2) == nil, "failed owner authentication erases buffered runtime voltage")

        print("PASS Bluetooth authentication, incremental legacy AC, runtime-voltage freshness, polling cadence, resets, and stalled-session checks")
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, "FAIL \(message)")
    }
}
