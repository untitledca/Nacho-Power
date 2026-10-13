import Foundation
import Darwin

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ context: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard actual == expected else {
        throw TestFailure(description: "\(file):\(line): \(context): expected \(expected), got \(actual)")
    }
}

private func reading(_ watts: Double?, _ battery: Double? = 49, acConnected: Bool? = nil) -> ReminderSample {
    ReminderSample(acInputWatts: watts, batteryPercentage: battery, acConnected: acConnected)
}

@main
private enum ReminderEngineTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("threshold, active latch, and complete playback cycle", testThresholdAndPlaybackCycle),
            ("immediate trigger without battery data", testImmediateWithoutBattery),
            ("AC flicker and unknown readings need fresh confirmation", testConfirmation),
            ("missing and invalid values never mean empty battery or zero AC", testInvalidReadings),
            ("telemetry grace and recovery", testTelemetryGrace),
            ("stalled polling expires through tick", testStalledPolling),
            ("old observations and duplicate deliveries cannot confirm AC", testOldAndDuplicateReadings),
            ("settings changes and disabling", testSettings),
            ("explicit cancellation and safe reset", testCancellation),
            ("connected with zero input holds active until positive input", testConnectedZeroInput),
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                failures += 1
                fputs("FAIL \(name): \(error)\n", stderr)
            }
        }
        print("\(tests.count - failures)/\(tests.count) reminder engine tests passed")
        if failures > 0 { exit(1) }
    }

    private static func testThresholdAndPlaybackCycle() throws {
        var engine = ReminderEngine()
        try expect(engine.ingest(reading(0, 60), at: 0), .none, "first off-AC sample")
        try expect(engine.ingest(reading(0, 50), at: 2), .none, "50% is not below 50%")
        try expect(engine.ingest(reading(0, 49), at: 4), .start, "crossing threshold starts intro")
        try expect(engine.phase, .active, "active reminder phase")
        try expect(engine.ingest(reading(0, 70), at: 6), .none, "battery change cannot stop reminder")
        try expect(engine.ingest(reading(0, 20), at: 8), .none, "intro is not repeated")
        try expect(engine.ingest(reading(200), at: 10), .none, "first positive AC sample")
        try expect(engine.ingest(reading(150), at: 12), .finish, "confirmed positive input plays outro")
        try expect(engine.phase, .outro, "outro phase")
        try expect(engine.ingest(reading(100), at: 14), .none, "outro not repeated")
        engine.outroDidFinish()
        try expect(engine.phase, .idle, "outro completion resets")
        try expect(engine.ingest(reading(0), at: 16), .none, "new outage needs first confirmation")
        try expect(engine.ingest(reading(0), at: 18), .start, "new outage starts new intro")
    }

    private static func testImmediateWithoutBattery() throws {
        var engine = ReminderEngine(trigger: .immediate)
        try expect(engine.ingest(reading(0, nil), at: 0), .none, "confirm AC absence")
        try expect(engine.ingest(reading(0, nil), at: 2), .start, "battery not needed for immediate mode")
        try expect(engine.ingest(reading(0, nil), at: 4), .none, "loop stays active")
        try expect(engine.ingest(reading(0.1, nil), at: 6), .none, "small positive input first sample")
        try expect(engine.ingest(reading(0.1, nil), at: 8), .finish, "any confirmed nonzero input restores AC")
    }

    private static func testConfirmation() throws {
        var engine = ReminderEngine(trigger: .immediate)
        try expect(engine.ingest(reading(0), at: 0), .none, "first zero")
        try expect(engine.ingest(reading(nil), at: 2), .none, "unknown breaks confirmation")
        try expect(engine.ingest(reading(0), at: 4), .none, "first fresh zero")
        try expect(engine.ingest(reading(100), at: 6), .none, "positive breaks zero streak")
        try expect(engine.ingest(reading(0), at: 8), .none, "zero flicker cannot start")
        try expect(engine.ingest(reading(0), at: 10), .start, "stable off AC starts")
        try expect(engine.ingest(reading(100), at: 12), .none, "first positive")
        try expect(engine.ingest(reading(nil), at: 14), .none, "unknown breaks positive streak")
        try expect(engine.ingest(reading(100), at: 16), .none, "first fresh positive")
        try expect(engine.ingest(reading(0), at: 18), .none, "positive flicker cannot finish")
        try expect(engine.ingest(reading(100), at: 20), .none, "first stable positive")
        try expect(engine.ingest(reading(100), at: 22), .finish, "stable AC finishes")
    }

    private static func testInvalidReadings() throws {
        var engine = ReminderEngine()
        let batteries: [Double?] = [nil, .nan, .infinity, -1, 101]
        for (index, battery) in batteries.enumerated() {
            try expect(engine.ingest(reading(0, battery), at: Double(index * 2)), .none, "invalid battery \(index)")
        }
        try expect(engine.ingest(reading(nil, 0), at: 12), .none, "missing AC with empty battery")
        try expect(engine.ingest(reading(-1, 0), at: 14), .none, "negative AC is unknown")
        try expect(engine.ingest(reading(.nan, 0), at: 16), .none, "NaN AC is unknown")
        try expect(engine.ingest(reading(.infinity, 0), at: 18), .none, "infinite AC is unknown")
        try expect(engine.ingest(reading(0, 0), at: 20), .none, "valid zero still needs confirmation")
        try expect(engine.ingest(reading(0, 0), at: 22), .start, "valid empty battery can start")
    }

    private static func testTelemetryGrace() throws {
        var engine = ReminderEngine(trigger: .immediate)
        _ = engine.ingest(reading(0), at: 0)
        try expect(engine.ingest(reading(0), at: 2), .start, "start before telemetry gap")
        try expect(engine.ingest(reading(nil), at: 10), .none, "brief unknown keeps overlay")
        try expect(engine.ingest(reading(nil), at: 31.9), .none, "grace lasts 30 seconds from last valid AC")
        try expect(engine.ingest(reading(nil), at: 32), .cancel, "expiry hides without outro")
        try expect(engine.phase, .idle, "expired phase")
        try expect(engine.ingest(reading(nil), at: 34), .none, "expiry cancellation occurs once")
        try expect(engine.ingest(reading(0), at: 36), .none, "recovery needs fresh confirmation")
        try expect(engine.ingest(reading(0), at: 38), .start, "confirmed recovery starts again")
        try expect(engine.ingest(reading(150), at: 40), .none, "restore AC first sample")
        try expect(engine.ingest(reading(150), at: 42), .finish, "restore AC second sample")
        try expect(engine.tick(at: 72), .cancel, "stale outro also hides")
    }

    private static func testStalledPolling() throws {
        var engine = ReminderEngine(trigger: .immediate)
        _ = engine.ingest(reading(0), at: 0)
        _ = engine.ingest(reading(0), at: 2)
        try expect(engine.tick(at: 31), .none, "stalled polling inside grace")
        try expect(engine.tick(at: 32), .cancel, "tick cancels without another poll")
        try expect(engine.tick(at: 100), .none, "tick does not repeat cancellation")

        var returnsAtExpiry = ReminderEngine(trigger: .immediate)
        _ = returnsAtExpiry.ingest(reading(0), at: 0)
        _ = returnsAtExpiry.ingest(reading(0), at: 2)
        try expect(returnsAtExpiry.ingest(reading(200), at: 32), .cancel, "late recovery hides expired reminder")
        try expect(returnsAtExpiry.ingest(reading(200), at: 34), .none, "late recovery cannot falsely play outro")
    }

    private static func testOldAndDuplicateReadings() throws {
        var engine = ReminderEngine(trigger: .immediate)
        try expect(engine.ingest(reading(0), at: 0), .none, "first sample")
        try expect(engine.ingest(reading(0), at: 0), .none, "duplicate cannot confirm")
        try expect(engine.ingest(reading(0), at: -1), .none, "out-of-order cannot confirm")
        try expect(engine.ingest(reading(0), at: .nan), .none, "invalid timestamp cannot confirm")
        try expect(engine.ingest(reading(0), at: 30), .none, "old zero cannot combine with new zero")
        try expect(engine.ingest(reading(0), at: 32), .start, "fresh consecutive samples start")
        try expect(engine.ingest(reading(100), at: 34), .none, "first positive sample")
        try expect(engine.ingest(reading(100), at: 34), .none, "duplicate positive cannot finish")
        try expect(engine.ingest(reading(100), at: 36), .finish, "fresh positive confirms restoration")
    }

    private static func testSettings() throws {
        var engine = ReminderEngine()
        _ = engine.ingest(reading(0, 80), at: 0)
        _ = engine.ingest(reading(0, 80), at: 2)
        try expect(engine.updateSettings(enabled: true, trigger: .immediate, at: 3), .none, "settings wait for next poll")
        try expect(engine.ingest(reading(0, 80), at: 4), .start, "immediate mode starts next poll")
        try expect(engine.updateSettings(enabled: true, trigger: .belowBattery(10), at: 5), .none, "trigger change keeps active latch")
        try expect(engine.ingest(reading(0, 80), at: 6), .none, "new threshold cannot interrupt active reminder")
        try expect(engine.updateSettings(enabled: false, trigger: .belowBattery(50), at: 7), .cancel, "disable immediately cancels")
        try expect(engine.phase, .idle, "disabled state idle")
        try expect(engine.ingest(reading(0), at: 8), .none, "disabled poll cannot start")
        try expect(engine.updateSettings(enabled: true, trigger: .belowBattery(50), at: 9), .none, "enable waits for fresh observations")
        try expect(engine.ingest(reading(0), at: 10), .none, "fresh first observation")
        try expect(engine.ingest(reading(0), at: 12), .start, "fresh second observation")
        _ = engine.ingest(reading(100), at: 14)
        _ = engine.ingest(reading(100), at: 16)
        try expect(engine.updateSettings(enabled: false, trigger: .immediate, at: 17), .cancel, "disable cancels outro")
    }

    private static func testCancellation() throws {
        var engine = ReminderEngine(trigger: .immediate)
        try expect(engine.cancel(), .none, "idle cancel has no visible effect")
        _ = engine.ingest(reading(0), at: 0)
        _ = engine.ingest(reading(0), at: 2)
        engine.outroDidFinish()
        try expect(engine.phase, .active, "unrelated completion cannot clear active reminder")
        try expect(engine.cancel(), .cancel, "quit or source change cancels")
        try expect(engine.cancel(), .none, "cancellation is idempotent")
        try expect(engine.ingest(reading(0), at: 4), .none, "cancel clears old observations")
        try expect(engine.ingest(reading(0), at: 6), .start, "fresh outage can restart")
    }

    private static func testConnectedZeroInput() throws {
        var engine = ReminderEngine(trigger: .immediate)
        // A fully charged station can be connected to AC while drawing 0 W.
        for timestamp in stride(from: 0.0, through: 40.0, by: 2.0) {
            try expect(engine.ingest(reading(0, acConnected: true), at: timestamp), .none, "connected zero-input startup")
        }
        try expect(engine.phase, .idle, "connected zero cannot start an outage reminder")
        try expect(engine.ingest(reading(0, acConnected: false), at: 42), .none, "first disconnected reading")
        try expect(engine.ingest(reading(0, acConnected: false), at: 44), .start, "confirmed disconnection starts")
        for timestamp in stride(from: 46.0, through: 86.0, by: 2.0) {
            try expect(engine.ingest(reading(0, acConnected: true), at: timestamp), .none, "connected zero-input keeps active beyond grace")
            try expect(engine.tick(at: timestamp), .none, "connected zero-input is fresh telemetry")
        }
        try expect(engine.phase, .active, "positive input still required to stop loop")
        try expect(engine.ingest(reading(150, acConnected: true), at: 88), .none, "first positive reading")
        try expect(engine.ingest(reading(0, acConnected: true), at: 90), .none, "connected zero breaks positive confirmation")
        try expect(engine.ingest(reading(150, acConnected: true), at: 92), .none, "fresh first positive reading")
        try expect(engine.ingest(reading(150, acConnected: true), at: 94), .finish, "two positive readings play outro")

        var missingWatts = ReminderEngine(trigger: .immediate)
        _ = missingWatts.ingest(reading(0, acConnected: false), at: 0)
        _ = missingWatts.ingest(reading(0, acConnected: false), at: 2)
        try expect(missingWatts.ingest(reading(nil, acConnected: true), at: 32), .cancel, "connected status alone cannot invent a fresh watts value")
    }
}
