import Foundation

private enum CheckError: Error { case failed(String) }

@main
private struct MultiStationReminderChecks {
    private static let unplugged = ReminderSample(acInputWatts: 0, batteryPercentage: 20, acConnected: false)
    private static let plugged = ReminderSample(acInputWatts: 0, batteryPercentage: 90, acConnected: true)
    private static let unknown = ReminderSample(acInputWatts: nil, batteryPercentage: nil)

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw CheckError.failed(message) }
    }

    static func main() throws {
        try selectionValidation()
        try eitherStationKeepsCat()
        try thresholdsStayWithTheirStation()
        try independentFailureAndFreshness()
        try independentCountdowns()
        try sharedSnooze()
        try snoozeDoesNotRefreshTelemetry()
        try configurationIsolation()
        try eligibilityDuringPop()
        try disablingDuringPop()
        print("PASS multi-station selection, individual thresholds/freshness, independent failures/countdowns, shared snooze, and pop coordination")
    }

    private static func selectionValidation() throws {
        let single = try MultiStationSelection.validated(primary: "", secondary: "", secondEnabled: false)
        try check(single.primary.isEmpty, "Single-station automatic discovery stays backward compatible")
        for values in [("", "B"), ("A", ""), (" a \n", "A")] {
            do {
                _ = try MultiStationSelection.validated(primary: values.0, secondary: values.1, secondEnabled: true)
                throw CheckError.failed("Missing or duplicate two-station selection was accepted")
            } catch is MultiStationSelection.SelectionError { }
        }
        let two = try MultiStationSelection.validated(primary: " first ", secondary: " second\n", secondEnabled: true)
        try check(two.primary == "FIRST" && two.secondary == "SECOND", "Distinct selections normalize without swapping lanes")
    }

    private static func eitherStationKeepsCat() throws {
        var policy = MultiStationReminderPolicy(secondEnabled: true)
        try check(policy.ingest(plugged, station: .primary, at: 0) == .none, "Plugged primary does not start a reminder")
        try check(policy.ingest(unplugged, station: .secondary, at: 1) == .start, "Second station alone can start the cat")
        try check(policy.ingest(unplugged, station: .primary, at: 2) == .none, "Both unplugged still use one cat")
        try check(policy.ingest(plugged, station: .secondary, at: 3) == .none && policy.phase == .active,
                  "Reconnecting the second station cannot hide the first station's cat")
        try check(policy.ingest(plugged, station: .primary, at: 4) == .finish,
                  "The last unplugged station reconnecting finishes the shared cat")
        _ = policy.dismissalDidFinish()
        try check(policy.phase == .idle, "One completed pop returns to monitoring")
    }

    private static func thresholdsStayWithTheirStation() throws {
        var policy = MultiStationReminderPolicy(trigger: .belowBattery(50), secondEnabled: true)
        let highUnplugged = ReminderSample(acInputWatts: 0, batteryPercentage: 80, acConnected: false)
        let lowPlugged = ReminderSample(acInputWatts: 0, batteryPercentage: 10, acConnected: true)
        try check(policy.ingest(highUnplugged, station: .primary, at: 0) == .none, "Unplugged station above threshold waits")
        try check(policy.ingest(lowPlugged, station: .secondary, at: 1) == .none,
                  "A plugged station's low battery cannot combine with another station's AC state")
        try check(policy.ingest(unplugged, station: .secondary, at: 2) == .start, "Same-device unplugged and low battery triggers")
        try check(policy.ingest(highUnplugged, station: .secondary, at: 3) == .none && policy.phase == .active,
                  "A visible reminder retains the existing battery-threshold latch")
        try check(policy.ingest(plugged, station: .secondary, at: 4) == .finish,
                  "An unrelated above-threshold station cannot keep a threshold reminder active")
    }

    private static func independentFailureAndFreshness() throws {
        var policy = MultiStationReminderPolicy(secondEnabled: true)
        _ = policy.ingest(unplugged, station: .primary, at: 0)
        _ = policy.ingest(unplugged, station: .secondary, at: 1)
        try check(policy.ingest(unknown, station: .primary, at: 2) == .none, "A failed lane retains only its normal telemetry grace")
        _ = policy.ingest(unplugged, station: .secondary, at: 20)
        try check(policy.tick(at: 31) == .none && policy.phase == .active,
                  "Primary expiry cannot cancel a fresh unplugged secondary reminder")
        try check(policy.ingest(plugged, station: .secondary, at: 32) == .finish,
                  "An expired primary does not block a known secondary reconnection")

        var unknownOnly = MultiStationReminderPolicy(secondEnabled: true)
        _ = unknownOnly.ingest(unplugged, station: .primary, at: 0)
        _ = unknownOnly.ingest(unknown, station: .primary, at: 2)
        _ = unknownOnly.ingest(plugged, station: .secondary, at: 20)
        try check(unknownOnly.tick(at: 29) == .none, "A plugged neighbor does not falsely confirm failed primary AC restoration")
        try check(unknownOnly.tick(at: 30) == .cancel, "Last failed station expires exactly from its own last valid observation")
        try check(unknownOnly.ingest(unknown, station: .secondary, at: 31) == .none, "Unknown data cannot create a new unplug event")
    }

    private static func independentCountdowns() throws {
        var policy = MultiStationReminderPolicy(interval: 60, secondEnabled: true)
        _ = policy.ingest(unplugged, station: .secondary, at: 0)
        _ = policy.ingest(unknown, station: .primary, at: 10)
        _ = policy.ingest(unplugged, station: .secondary, at: 20)
        _ = policy.ingest(unknown, station: .primary, at: 30)
        _ = policy.ingest(unplugged, station: .secondary, at: 40)
        try check(policy.nextReminderAt == 60, "Errors in one station cannot reset the other station's timer")
        _ = policy.ingest(unplugged, station: .secondary, at: 59)
        try check(policy.tick(at: 60) == .start, "A fresh secondary starts after the full configured interval")
    }

    private static func sharedSnooze() throws {
        var policy = MultiStationReminderPolicy(interval: 60, secondEnabled: true)
        _ = policy.ingest(unplugged, station: .primary, at: 0)
        _ = policy.ingest(unplugged, station: .primary, at: 20)
        _ = policy.ingest(unplugged, station: .secondary, at: 30)
        _ = policy.ingest(unplugged, station: .primary, at: 40)
        _ = policy.ingest(unplugged, station: .secondary, at: 55)
        try check(policy.ingest(unplugged, station: .primary, at: 60) == .start, "First elapsed station shows the cat")
        try check(policy.snooze(at: 65) == .finish && policy.nextReminderAt == 125 && policy.isSnoozed,
                  "Clicking postpones both active and pending station timers by a full interval")
        _ = policy.dismissalDidFinish()
        for timestamp in [80.0, 100.0, 120.0] {
            _ = policy.ingest(unplugged, station: .primary, at: timestamp)
            _ = policy.ingest(unplugged, station: .secondary, at: timestamp)
        }
        try check(policy.tick(at: 124) == .none, "Another station's earlier countdown cannot break shared snooze")
        try check(policy.tick(at: 125) == .start, "Shared snooze ends exactly one full interval after clicking")
    }

    private static func snoozeDoesNotRefreshTelemetry() throws {
        var engine = ReminderEngine(interval: 60)
        _ = engine.ingest(unplugged, at: 0)
        _ = engine.deferPendingReminder(at: 29)
        try check(engine.nextReminderAt == 89, "Pending timer moves from the actual click time")
        _ = engine.tick(at: 30)
        try check(engine.nextReminderAt == nil, "Deferring a countdown cannot extend stale telemetry validity")
    }

    private static func configurationIsolation() throws {
        var policy = MultiStationReminderPolicy(secondEnabled: true)
        _ = policy.ingest(unplugged, station: .primary, at: 0)
        _ = policy.ingest(unplugged, station: .secondary, at: 1)
        try check(policy.reset(station: .primary) == .none && policy.phase == .active,
                  "Changing primary configuration cannot hide the secondary reminder")
        try check(policy.setSecondStationEnabled(false) == .cancel && policy.phase == .idle,
                  "Disabling the last active station cancels its reminder")
        try check(policy.ingest(unplugged, station: .secondary, at: 2) == .none,
                  "Disabled secondary readings cannot trigger a cat")
    }

    private static func eligibilityDuringPop() throws {
        var policy = MultiStationReminderPolicy(secondEnabled: true)
        _ = policy.ingest(unplugged, station: .primary, at: 0)
        try check(policy.ingest(plugged, station: .primary, at: 1) == .finish, "Primary starts a pop on restoration")
        try check(policy.ingest(unplugged, station: .secondary, at: 1.1) == .none, "Secondary cannot interrupt an in-progress pop")
        try check(policy.dismissalDidFinish() == .start && policy.phase == .active,
                  "A station becoming eligible during pop appears as soon as dismissal completes")
    }

    private static func disablingDuringPop() throws {
        var policy = MultiStationReminderPolicy(secondEnabled: true)
        _ = policy.ingest(unplugged, station: .primary, at: 0)
        _ = policy.ingest(plugged, station: .primary, at: 1)
        try check(policy.phase == .dismissing, "The regression fixture has a pop in progress")
        try check(policy.updateSettings(enabled: false, trigger: .immediate, at: 1.1) == .cancel && policy.phase == .idle,
                  "Disabling reminders immediately cancels an in-progress shared pop")
        try check(policy.dismissalDidFinish() == .none && policy.ingest(unplugged, station: .secondary, at: 2) == .none,
                  "Late pop callbacks and secondary readings cannot restart a disabled reminder")
    }
}
