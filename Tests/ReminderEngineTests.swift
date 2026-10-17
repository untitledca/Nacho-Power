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
            ("explicit AC state starts and stops even with zero or missing watts", testConnectedZeroInput),
            ("immediate default and authoritative AC status", testExplicitACState),
            ("timed reminders start only after a full eligible interval", testTimedStart),
            ("click snooze counts from the click through pop completion", testTimedSnooze),
            ("unknown and stale telemetry reset timed reminders", testTimedTelemetry),
            ("timed threshold eligibility must remain valid", testTimedThreshold),
            ("AC restoration cancels waiting and snoozed reminders", testTimedReconnect),
            ("timed settings, disable, and source resets", testTimedSettings),
            ("timer normalization and invalid snooze timestamps", testTimedValidation),
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
        var engine = ReminderEngine(trigger: .belowBattery(50))
        try expect(engine.ingest(reading(0, 60), at: 0), .none, "first off-AC sample")
        try expect(engine.ingest(reading(0, 50), at: 2), .none, "50% is not below 50%")
        try expect(engine.ingest(reading(0, 49), at: 4), .start, "crossing threshold starts intro")
        try expect(engine.phase, .active, "active reminder phase")
        try expect(engine.ingest(reading(0, 70), at: 6), .none, "battery change cannot stop reminder")
        try expect(engine.ingest(reading(0, 20), at: 8), .none, "intro is not repeated")
        try expect(engine.ingest(reading(200), at: 10), .none, "first positive AC sample")
        try expect(engine.ingest(reading(150), at: 12), .finish, "confirmed positive input plays pop animation")
        try expect(engine.phase, .dismissing, "pop animation phase")
        try expect(engine.ingest(reading(100), at: 14), .none, "pop animation not repeated")
        engine.dismissalDidFinish()
        try expect(engine.phase, .idle, "pop animation completion resets")
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
        var engine = ReminderEngine(trigger: .belowBattery(50))
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
        try expect(engine.ingest(reading(nil), at: 32), .cancel, "expiry hides without pop animation")
        try expect(engine.phase, .idle, "expired phase")
        try expect(engine.ingest(reading(nil), at: 34), .none, "expiry cancellation occurs once")
        try expect(engine.ingest(reading(0), at: 36), .none, "recovery needs fresh confirmation")
        try expect(engine.ingest(reading(0), at: 38), .start, "confirmed recovery starts again")
        try expect(engine.ingest(reading(150), at: 40), .none, "restore AC first sample")
        try expect(engine.ingest(reading(150), at: 42), .finish, "restore AC second sample")
        try expect(engine.tick(at: 72), .cancel, "stale pop animation also hides")
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
        try expect(returnsAtExpiry.ingest(reading(200), at: 34), .none, "late recovery cannot falsely play pop animation")
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
        var engine = ReminderEngine(trigger: .belowBattery(50))
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
        try expect(engine.updateSettings(enabled: false, trigger: .immediate, at: 17), .cancel, "disable cancels pop animation")
    }

    private static func testCancellation() throws {
        var engine = ReminderEngine(trigger: .immediate)
        try expect(engine.cancel(), .none, "idle cancel has no visible effect")
        _ = engine.ingest(reading(0), at: 0)
        _ = engine.ingest(reading(0), at: 2)
        engine.dismissalDidFinish()
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
        try expect(engine.ingest(reading(0, acConnected: false), at: 42), .start, "explicit disconnection starts immediately")
        try expect(engine.ingest(reading(0, acConnected: true), at: 44), .finish, "reconnection at 0 W dismisses immediately")
        try expect(engine.phase, .dismissing, "pop begins immediately")
        engine.dismissalDidFinish()
        try expect(engine.phase, .idle, "pop completion resets")
        try expect(engine.ingest(reading(nil, acConnected: false), at: 46), .start, "explicit disconnect does not need watts")
        try expect(engine.ingest(reading(nil, acConnected: true), at: 48), .finish, "explicit reconnect does not need watts")
    }

    private static func testExplicitACState() throws {
        var engine = ReminderEngine()
        try expect(engine.trigger, .immediate, "default responds to AC loss at any battery percentage")
        try expect(engine.ingest(reading(150, 100, acConnected: false), at: 0), .start, "explicit AC state wins over lagging wattage")
        try expect(engine.ingest(reading(.nan, nil, acConnected: false), at: 20), .none, "explicit state remains valid with invalid watts")
        try expect(engine.tick(at: 35), .none, "AC state refreshes telemetry grace")
        try expect(engine.ingest(reading(0, nil, acConnected: true), at: 36), .finish, "immediate reconnect despite full battery or missing charge percentage")
        try expect(engine.ingest(reading(0, nil, acConnected: true), at: 38), .none, "reconnection cannot repeat the pop")
        engine.dismissalDidFinish()
        try expect(engine.ingest(reading(nil, nil, acConnected: false), at: 40), .start, "a second outage restarts intro")

        var threshold = ReminderEngine(trigger: .belowBattery(50))
        try expect(threshold.ingest(reading(nil, 80, acConnected: false), at: 0), .none, "saved optional threshold is respected")
        try expect(threshold.ingest(reading(nil, 49, acConnected: false), at: 2), .start, "explicit disconnect starts below threshold")
        try expect(threshold.ingest(reading(nil, 100, acConnected: true), at: 4), .finish, "threshold never blocks reconnection dismissal")
    }

    private static func testTimedStart() throws {
        var engine = ReminderEngine(interval: 60)
        try expect(engine.ingest(reading(0), at: 0), .none, "a noisy unconfirmed AC sample cannot start a timer")
        try expect(engine.nextReminderAt, nil, "no timer before confirmation")
        try expect(engine.ingest(reading(0), at: 2), .none, "confirmed outage schedules instead of showing cat")
        try expect(engine.nextReminderAt, 62, "full interval begins at confirmed eligibility")
        for timestamp in stride(from: 10.0, through: 60.0, by: 10) {
            try expect(engine.ingest(reading(0), at: timestamp), .none, "fresh polls preserve original deadline")
        }
        try expect(engine.nextReminderAt, 62, "polling does not perpetually postpone the cat")
        try expect(engine.tick(at: 61.9), .none, "tick must not start early")
        try expect(engine.tick(at: 62), .start, "fresh eligibility lets a timer fire between polls")
        try expect(engine.nextReminderAt, nil, "active cat has no recurring restart deadline")
        for timestamp in stride(from: 80.0, through: 200.0, by: 20) {
            try expect(engine.ingest(reading(0), at: timestamp), .none, "visible cat loops until clicked or AC returns")
        }
        try expect(engine.phase, .active, "timer is not an automatic timeout")
    }

    private static func testTimedSnooze() throws {
        var engine = ReminderEngine(interval: 60)
        _ = engine.ingest(reading(nil, acConnected: false), at: 0)
        for timestamp in [20.0, 40, 60] { _ = engine.ingest(reading(nil, acConnected: false), at: timestamp) }
        try expect(engine.phase, .active, "timed cat is active before click")
        try expect(engine.snooze(at: 70), .finish, "click starts the pop")
        try expect(engine.phase, .dismissing, "click pop has its own dismissal phase")
        try expect(engine.nextReminderAt, 130, "deadline is click plus interval")
        try expect(engine.isSnoozed, true, "UI can distinguish snooze from first waiting interval")
        try expect(engine.snooze(at: 70.1), .none, "a second click cannot extend the timer")
        engine.dismissalDidFinish()
        try expect(engine.nextReminderAt, 130, "pop completion preserves click deadline")
        try expect(engine.phase, .idle, "snoozed cat is hidden")
        try expect(engine.ingest(reading(nil, acConnected: true), at: 69), .none, "old delivery before click cannot cancel its schedule")
        for timestamp in [80.0, 100, 120] {
            try expect(engine.ingest(reading(nil, acConnected: false), at: timestamp), .none, "snooze keeps checking eligibility")
        }
        try expect(engine.tick(at: 129.9), .none, "full snooze interval is respected")
        try expect(engine.tick(at: 130), .start, "new intro begins when snooze expires")
        try expect(engine.isSnoozed, false, "snooze clears on next cat")
    }

    private static func testTimedTelemetry() throws {
        var engine = ReminderEngine(interval: 60)
        _ = engine.ingest(reading(nil, acConnected: false), at: 0)
        _ = engine.ingest(reading(nil, acConnected: false), at: 20)
        try expect(engine.ingest(reading(nil), at: 25), .none, "unknown state cancels a pending timer")
        try expect(engine.nextReminderAt, nil, "unknown AC cannot leave an armed deadline")
        try expect(engine.tick(at: 60), .none, "unknown telemetry cannot show a cat")
        _ = engine.ingest(reading(nil, acConnected: false), at: 61)
        try expect(engine.nextReminderAt, 121, "recovery starts a fresh full interval")
        try expect(engine.tick(at: 91), .none, "stale invisible schedule expires quietly")
        try expect(engine.nextReminderAt, nil, "stalled polling clears the deadline")
        _ = engine.ingest(reading(nil, acConnected: false), at: 100)
        for timestamp in [120.0, 140, 160] { _ = engine.ingest(reading(nil, acConnected: false), at: timestamp) }
        try expect(engine.phase, .active, "fresh interval can start after recovery")
        try expect(engine.tick(at: 190), .cancel, "an active timed cat retains stale-data protection")
        try expect(engine.nextReminderAt, nil, "expiry clears any timing state")
        try expect(engine.isSnoozed, false, "expiry is not a user snooze")
    }

    private static func testTimedThreshold() throws {
        var engine = ReminderEngine(trigger: .belowBattery(50), interval: 60)
        _ = engine.ingest(reading(nil, 50, acConnected: false), at: 0)
        try expect(engine.nextReminderAt, nil, "equal threshold is ineligible")
        _ = engine.ingest(reading(nil, 49, acConnected: false), at: 10)
        try expect(engine.nextReminderAt, 70, "below threshold begins countdown")
        _ = engine.ingest(reading(nil, nil, acConnected: false), at: 20)
        try expect(engine.nextReminderAt, nil, "missing battery cancels a threshold countdown")
        _ = engine.ingest(reading(nil, 49, acConnected: false), at: 30)
        _ = engine.ingest(reading(nil, 80, acConnected: false), at: 40)
        try expect(engine.nextReminderAt, nil, "battery becoming ineligible resets countdown")
        for timestamp in [50.0, 70, 90, 110] { _ = engine.ingest(reading(nil, 49, acConnected: false), at: timestamp) }
        try expect(engine.phase, .active, "continuously eligible interval starts cat")
        try expect(engine.ingest(reading(nil, 80, acConnected: false), at: 112), .none, "active latch survives battery change")
        try expect(engine.snooze(at: 113), .finish, "click still dismisses a latched cat")
        try expect(engine.nextReminderAt, nil, "ineligible battery cannot arm another cat")
        engine.dismissalDidFinish()
        _ = engine.ingest(reading(nil, 49, acConnected: false), at: 120)
        try expect(engine.nextReminderAt, 180, "new eligibility needs its full interval")
    }

    private static func testTimedReconnect() throws {
        var engine = ReminderEngine(interval: 60)
        _ = engine.ingest(reading(nil, acConnected: false), at: 0)
        _ = engine.ingest(reading(0, acConnected: true), at: 20)
        try expect(engine.nextReminderAt, nil, "connected at zero watts clears waiting timer")
        _ = engine.ingest(reading(nil, acConnected: false), at: 30)
        try expect(engine.nextReminderAt, 90, "new outage restarts countdown")
        for timestamp in [50.0, 70, 90] { _ = engine.ingest(reading(nil, acConnected: false), at: timestamp) }
        try expect(engine.snooze(at: 91), .finish, "snooze begins")
        try expect(engine.ingest(reading(nil, acConnected: true), at: 91.1), .none, "AC during pop must not duplicate the pop")
        try expect(engine.nextReminderAt, nil, "AC during pop clears the snoozed deadline")
        engine.dismissalDidFinish()
        try expect(engine.isSnoozed, false, "AC restoration clears snooze state")
        _ = engine.ingest(reading(nil, acConnected: false), at: 100)
        try expect(engine.nextReminderAt, 160, "outage after reconnection waits again")
        for timestamp in [120.0, 140, 160] { _ = engine.ingest(reading(nil, acConnected: false), at: timestamp) }
        try expect(engine.ingest(reading(nil, acConnected: true), at: 162), .finish, "AC reconnect immediately pops an active timed cat")
        try expect(engine.nextReminderAt, nil, "AC dismissal never arms a new timer")
    }

    private static func testTimedSettings() throws {
        var engine = ReminderEngine(interval: 60)
        _ = engine.ingest(reading(nil, acConnected: false), at: 0)
        _ = engine.updateSettings(enabled: true, trigger: .immediate, interval: 60, at: 10)
        try expect(engine.nextReminderAt, 60, "unchanged settings do not restart countdown")
        _ = engine.updateSettings(enabled: true, trigger: .immediate, interval: 120, at: 11)
        try expect(engine.nextReminderAt, nil, "new interval waits for fresh eligibility")
        _ = engine.ingest(reading(nil, acConnected: false), at: 12)
        try expect(engine.nextReminderAt, 132, "changed interval applies in full")
        _ = engine.updateSettings(enabled: false, trigger: .immediate, interval: 120, at: 13)
        try expect(engine.nextReminderAt, nil, "pause clears countdown")
        _ = engine.updateSettings(enabled: true, trigger: .immediate, interval: 60, at: 14)
        _ = engine.ingest(reading(nil, acConnected: false), at: 15)
        try expect(engine.nextReminderAt, 75, "resuming does not reuse elapsed time")
        try expect(engine.cancel(), .none, "source change cancels an invisible countdown")
        try expect(engine.nextReminderAt, nil, "source change clears countdown")
        _ = engine.ingest(reading(nil, acConnected: false), at: 20)
        for timestamp in [40.0, 60, 80] { _ = engine.ingest(reading(nil, acConnected: false), at: timestamp) }
        try expect(engine.updateSettings(enabled: true, trigger: .belowBattery(10), interval: 120, at: 81), .none, "timing changes preserve active latch")
        try expect(engine.phase, .active, "existing cat still waits for click or AC")
        try expect(engine.updateSettings(enabled: false, trigger: .immediate, interval: 60, at: 82), .cancel, "disabling still hides active cat immediately")

        var switchesToImmediate = ReminderEngine(interval: 60)
        _ = switchesToImmediate.ingest(reading(nil, acConnected: false), at: 0)
        _ = switchesToImmediate.updateSettings(enabled: true, trigger: .immediate, interval: nil, at: 1)
        try expect(switchesToImmediate.nextReminderAt, nil, "disabling timer clears waiting deadline")
        try expect(switchesToImmediate.ingest(reading(nil, acConnected: false), at: 2), .start, "untimed mode starts on next fresh reading")
    }

    private static func testTimedValidation() throws {
        try expect(ReminderEngine(interval: -1).interval, 60, "interval clamps to one minute")
        try expect(ReminderEngine(interval: 9_000).interval, 3_600, "interval clamps to one hour")
        try expect(ReminderEngine(interval: .nan).interval, 300, "invalid interval uses five-minute default")
        try expect(ReminderEngine(interval: .infinity).interval, 300, "infinite interval is normalized")
        try expect(ReminderEngine().interval, nil, "legacy mode is unchanged by default")
        var untimed = ReminderEngine()
        _ = untimed.ingest(reading(nil, acConnected: false), at: 0)
        try expect(untimed.snooze(at: 1), .none, "untimed reminders do not acquire an implicit snooze period")

        var timed = ReminderEngine(interval: 60)
        _ = timed.ingest(reading(nil, acConnected: false), at: 0)
        for timestamp in [20.0, 40, 60] { _ = timed.ingest(reading(nil, acConnected: false), at: timestamp) }
        try expect(timed.snooze(at: .nan), .none, "invalid click time cannot hide cat")
        try expect(timed.snooze(at: 59), .none, "out-of-order click time cannot hide cat")
        try expect(timed.phase, .active, "rejected click leaves cat active")
        try expect(timed.snooze(at: 90), .cancel, "click cannot convert expired telemetry into a new timer")
        try expect(timed.nextReminderAt, nil, "stale click leaves no schedule")
    }
}
