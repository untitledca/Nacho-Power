import Foundation

/// Reject an ambiguous two-station setup before replacing either live monitor.
enum MultiStationSelection {
    enum SelectionError: LocalizedError {
        case primaryRequired, secondaryRequired, duplicate

        var errorDescription: String? {
            switch self {
            case .primaryRequired: return "Choose the first station before enabling a second station."
            case .secondaryRequired: return "Choose the second station before saving."
            case .duplicate: return "Choose two different stations. The same EcoFlow cannot be monitored twice."
            }
        }
    }

    static func validated(primary: String, secondary: String, secondEnabled: Bool) throws -> (primary: String, secondary: String) {
        let primary = primary.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let secondary = secondary.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if secondEnabled {
            guard !primary.isEmpty else { throw SelectionError.primaryRequired }
            guard !secondary.isEmpty else { throw SelectionError.secondaryRequired }
            guard primary != secondary else { throw SelectionError.duplicate }
        }
        return (primary, secondary)
    }
}

/// Each station owns its AC confirmation, battery threshold, countdown, and
/// telemetry grace. Only playback commands are shared; readings never combine.
struct MultiStationReminderPolicy {
    private var primary: ReminderEngine
    private var secondary: ReminderEngine
    private(set) var secondEnabled: Bool
    private(set) var phase: ReminderPhase = .idle

    init(enabled: Bool = true, trigger: ReminderTrigger = .immediate,
         staleGrace: TimeInterval = 30, interval: TimeInterval? = nil,
         secondEnabled: Bool = false) {
        primary = ReminderEngine(enabled: enabled, trigger: trigger, staleGrace: staleGrace, interval: interval)
        secondary = ReminderEngine(enabled: enabled, trigger: trigger, staleGrace: staleGrace, interval: interval)
        self.secondEnabled = secondEnabled
    }

    var nextReminderAt: TimeInterval? {
        [primary.nextReminderAt, secondEnabled ? secondary.nextReminderAt : nil].compactMap { $0 }.min()
    }

    var isSnoozed: Bool {
        guard let nextReminderAt else { return false }
        return (primary.nextReminderAt == nextReminderAt && primary.isSnoozed)
            || (secondEnabled && secondary.nextReminderAt == nextReminderAt && secondary.isSnoozed)
    }

    mutating func ingest(_ sample: ReminderSample, station: EcoFlowStationSlot, at timestamp: TimeInterval) -> ReminderCommand {
        let command: ReminderCommand
        switch station {
        case .primary: command = primary.ingest(sample, at: timestamp)
        case .secondary:
            guard secondEnabled else { return .none }
            command = secondary.ingest(sample, at: timestamp)
        }
        return reconcile([command])
    }

    mutating func tick(at timestamp: TimeInterval) -> ReminderCommand {
        let first = primary.tick(at: timestamp)
        let second = secondEnabled ? secondary.tick(at: timestamp) : .none
        return reconcile([first, second])
    }

    mutating func updateSettings(enabled: Bool, trigger: ReminderTrigger,
                                 interval: TimeInterval? = nil, at timestamp: TimeInterval) -> ReminderCommand {
        let first = primary.updateSettings(enabled: enabled, trigger: trigger, interval: interval, at: timestamp)
        let second = secondary.updateSettings(enabled: enabled, trigger: trigger, interval: interval, at: timestamp)
        return reconcile([first, second])
    }

    mutating func setSecondStationEnabled(_ enabled: Bool) -> ReminderCommand {
        guard enabled != secondEnabled else { return .none }
        secondEnabled = enabled
        return reconcile([secondary.cancel()])
    }

    /// Reset only the lane whose configuration changed. The other station can
    /// keep its live reminder or countdown while this one reconnects.
    mutating func reset(station: EcoFlowStationSlot) -> ReminderCommand {
        let command = station == .primary ? primary.cancel() : secondary.cancel()
        return reconcile([command])
    }

    mutating func snooze(at timestamp: TimeInterval) -> ReminderCommand {
        guard phase == .active else { return .none }
        let first = primary.phase == .active ? primary.snooze(at: timestamp) : primary.deferPendingReminder(at: timestamp)
        let second: ReminderCommand
        if secondEnabled {
            second = secondary.phase == .active ? secondary.snooze(at: timestamp) : secondary.deferPendingReminder(at: timestamp)
        } else { second = .none }
        return reconcile([first, second])
    }

    @discardableResult
    mutating func cancel() -> ReminderCommand {
        let wasVisible = phase != .idle
        _ = primary.cancel()
        _ = secondary.cancel()
        phase = .idle
        return wasVisible ? .cancel : .none
    }

    /// A second station may become eligible during the shared pop transition.
    /// Start it only after that transition completes.
    mutating func dismissalDidFinish() -> ReminderCommand {
        guard phase == .dismissing else { return .none }
        finishPrivateDismissals()
        phase = .idle
        return reconcile([])
    }

    private mutating func reconcile(_ commands: [ReminderCommand]) -> ReminderCommand {
        let wantsCat = primary.phase == .active || (secondEnabled && secondary.phase == .active)
        if wantsCat {
            guard phase != .dismissing else { return .none }
            // One lane finishing does not animate the shared cat away while
            // another lane still needs it. Complete that private state now.
            finishPrivateDismissals()
            guard phase == .idle else { return .none }
            phase = .active
            return .start
        }
        guard phase == .active else {
            // Disabling, reconfiguring, or expiring the last lane must also
            // cancel a pop already in progress, matching the single engine.
            if phase == .dismissing, commands.contains(.cancel) {
                phase = .idle
                finishPrivateDismissals()
                return .cancel
            }
            if phase == .idle { finishPrivateDismissals() }
            return .none
        }
        if commands.contains(.finish), !commands.contains(.cancel) {
            phase = .dismissing
            return .finish
        }
        phase = .idle
        finishPrivateDismissals()
        return .cancel
    }

    private mutating func finishPrivateDismissals() {
        if primary.phase == .dismissing { primary.dismissalDidFinish() }
        if secondary.phase == .dismissing { secondary.dismissalDidFinish() }
    }
}
