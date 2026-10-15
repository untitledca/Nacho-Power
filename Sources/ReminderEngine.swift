import Foundation

/// A live reading from the selected power source. Missing data must remain nil.
/// acInputWatts refers to AC input, rather than combined AC/solar/DC input.
struct ReminderSample: Equatable {
    let acInputWatts: Double?
    let batteryPercentage: Double?
    let acConnected: Bool?

    init(acInputWatts: Double?, batteryPercentage: Double?, acConnected: Bool? = nil) {
        self.acInputWatts = acInputWatts
        self.batteryPercentage = batteryPercentage
        self.acConnected = acConnected
    }
}

enum ReminderTrigger: Equatable {
    case immediate
    case belowBattery(Double)
}

enum ReminderCommand: Equatable {
    case none
    /// Play the intro once, then repeat loop.mov.
    case start
    /// Stop playback immediately and dismiss with a short pop animation.
    case finish
    /// Hide immediately; loss of telemetry does not mean AC was restored.
    case cancel
}

enum ReminderPhase: Equatable {
    case idle
    case active
    case dismissing
}

/// Pure reminder policy. The caller supplies timestamps in seconds from one
/// consistent clock and tells the engine when the dismissal finishes.
struct ReminderEngine {
    private(set) var phase: ReminderPhase = .idle
    private(set) var enabled: Bool
    private(set) var trigger: ReminderTrigger

    let staleGrace: TimeInterval

    private var lastAcceptedAt: TimeInterval?
    private var lastValidACAt: TimeInterval?
    private var consecutiveDisconnected = 0
    private var consecutiveConnected = 0
    private let requiredConsecutiveReadings = 2

    init(
        enabled: Bool = true,
        trigger: ReminderTrigger = .immediate,
        staleGrace: TimeInterval = 30
    ) {
        self.enabled = enabled
        self.trigger = Self.normalized(trigger)
        self.staleGrace = staleGrace.isFinite && staleGrace > 0 ? staleGrace : 30
    }

    /// Each poll must have a later timestamp than the previous poll. Duplicate
    /// or out-of-order delivery cannot count as a second confirming reading.
    mutating func ingest(_ sample: ReminderSample, at timestamp: TimeInterval) -> ReminderCommand {
        guard timestamp.isFinite,
              lastAcceptedAt.map({ timestamp > $0 }) ?? true else {
            return .none
        }
        lastAcceptedAt = timestamp

        guard enabled else { return .none }

        let expiration = expireTelemetry(at: timestamp)

        // A device's explicit AC state is authoritative even when its battery is
        // full and AC input is 0 W, or when a transport omits the wattage field.
        // Wattage-only transports still need two readings to reject brief noise.
        let connected: Bool
        let requiredReadings: Int
        if let acConnected = sample.acConnected {
            connected = acConnected
            requiredReadings = 1
        } else if let watts = sample.acInputWatts, watts.isFinite, watts >= 0 {
            connected = watts > 0
            requiredReadings = requiredConsecutiveReadings
        } else {
            consecutiveDisconnected = 0
            consecutiveConnected = 0
            return expiration
        }
        lastValidACAt = timestamp
        if connected {
            consecutiveConnected = min(consecutiveConnected + 1, requiredConsecutiveReadings)
            consecutiveDisconnected = 0
        } else {
            consecutiveDisconnected = min(consecutiveDisconnected + 1, requiredConsecutiveReadings)
            consecutiveConnected = 0
        }

        // An expired reminder is hidden even if this poll brings telemetry back.
        // A later fresh confirmation may start another reminder.
        guard expiration == .none else { return expiration }

        switch phase {
        case .idle:
            guard consecutiveDisconnected >= requiredReadings,
                  shouldStart(batteryPercentage: sample.batteryPercentage) else {
                return .none
            }
            phase = .active
            return .start
        case .active:
            // Once started, changing battery level or trigger settings never
            // stops the reminder. Confirmed AC connection ends it, including at 0 W.
            guard consecutiveConnected >= requiredReadings else {
                return .none
            }
            phase = .dismissing
            return .finish
        case .dismissing:
            return .none
        }
    }

    /// Call even when polling is stalled so a visible reminder cannot live
    /// indefinitely on an old reading.
    mutating func tick(at timestamp: TimeInterval) -> ReminderCommand {
        guard enabled, timestamp.isFinite,
              lastAcceptedAt.map({ timestamp >= $0 }) ?? true else {
            return .none
        }
        return expireTelemetry(at: timestamp)
    }

    /// Trigger changes take effect on the next reading. Disabling immediately
    /// hides either the reminder loop or an in-progress pop animation.
    mutating func updateSettings(
        enabled: Bool,
        trigger: ReminderTrigger,
        at timestamp: TimeInterval
    ) -> ReminderCommand {
        let wasEnabled = self.enabled
        self.enabled = enabled
        self.trigger = Self.normalized(trigger)
        if !enabled {
            return cancel()
        }
        if !wasEnabled {
            resetObservations()
        }
        return tick(at: timestamp)
    }

    /// Start a new confirmation cycle after the pop animation has disappeared.
    mutating func dismissalDidFinish() {
        guard phase == .dismissing else { return }
        phase = .idle
        resetObservations()
    }

    /// Used for disabling, quitting, source changes, or explicit dismissal.
    @discardableResult
    mutating func cancel() -> ReminderCommand {
        let wasVisible = phase != .idle
        phase = .idle
        resetObservations()
        return wasVisible ? .cancel : .none
    }

    private func shouldStart(batteryPercentage: Double?) -> Bool {
        switch trigger {
        case .immediate:
            return true
        case .belowBattery(let threshold):
            guard let percentage = batteryPercentage,
                  percentage.isFinite,
                  (0...100).contains(percentage) else {
                return false
            }
            return percentage < threshold
        }
    }

    private mutating func expireTelemetry(at timestamp: TimeInterval) -> ReminderCommand {
        guard let lastValidACAt,
              timestamp - lastValidACAt >= staleGrace else {
            return .none
        }
        let wasVisible = phase != .idle
        phase = .idle
        // Keep lastAcceptedAt so duplicate delivery stays rejected. Only the
        // observations used for AC confirmation expire here.
        self.lastValidACAt = nil
        consecutiveDisconnected = 0
        consecutiveConnected = 0
        return wasVisible ? .cancel : .none
    }

    private mutating func resetObservations() {
        lastAcceptedAt = nil
        lastValidACAt = nil
        consecutiveDisconnected = 0
        consecutiveConnected = 0
    }

    private static func normalized(_ trigger: ReminderTrigger) -> ReminderTrigger {
        switch trigger {
        case .immediate:
            return .immediate
        case .belowBattery(let threshold):
            return .belowBattery(threshold.isFinite ? min(100, max(0, threshold)) : 50)
        }
    }
}
