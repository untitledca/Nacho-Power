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

        print("PASS Bluetooth early telemetry routing, authentication gating, incremental AC continuity, resets, and stalled-session checks")
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, "FAIL \(message)")
    }
}
