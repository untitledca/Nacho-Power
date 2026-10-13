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
    /// Play the intro once, then loop the middle clip.
    case start
    /// Stop the reminder loop and play the outro once.
    case finish
    /// Hide immediately; loss of telemetry does not mean AC was restored.
    case cancel
}

enum ReminderPhase: Equatable {
    case idle
    case active
    case outro
}

/// Pure reminder policy. The caller supplies timestamps in seconds from one
/// consistent clock and tells the engine when the outro finishes.
struct ReminderEngine {
    private(set) var phase: ReminderPhase = .idle
    private(set) var enabled: Bool
    private(set) var trigger: ReminderTrigger

    let staleGrace: TimeInterval

    private var lastAcceptedAt: TimeInterval?
    private var lastValidACAt: TimeInterval?
    private var consecutiveZero = 0
    private var consecutivePositive = 0
    private let requiredConsecutiveReadings = 2

    init(
        enabled: Bool = true,
        trigger: ReminderTrigger = .belowBattery(50),
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

        guard let watts = sample.acInputWatts, watts.isFinite, watts >= 0 else {
            consecutiveZero = 0
            consecutivePositive = 0
            return expiration
        }

        lastValidACAt = timestamp
        if watts == 0 && sample.acConnected == true {
            // Connected with known zero input is live telemetry. It cannot
            // start an outage reminder or satisfy positive-input restoration,
            // but it keeps an already active reminder latched.
            consecutiveZero = 0
            consecutivePositive = 0
            return expiration
        }
        if watts == 0 {
            consecutiveZero = min(consecutiveZero + 1, requiredConsecutiveReadings)
            consecutivePositive = 0
        } else {
            consecutivePositive = min(consecutivePositive + 1, requiredConsecutiveReadings)
            consecutiveZero = 0
        }

        // An expired reminder is hidden even if this poll brings telemetry back.
        // A later fresh confirmation may start another reminder.
        guard expiration == .none else { return expiration }

        switch phase {
        case .idle:
            guard consecutiveZero >= requiredConsecutiveReadings,
                  shouldStart(batteryPercentage: sample.batteryPercentage) else {
                return .none
            }
            phase = .active
            return .start
        case .active:
            // Once started, changing battery level or trigger settings never
            // stops the reminder. Confirmed positive AC input ends it.
            guard consecutivePositive >= requiredConsecutiveReadings else {
                return .none
            }
            phase = .outro
            return .finish
        case .outro:
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
    /// hides either the reminder loop or an in-progress outro.
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

    /// Start a new confirmation cycle after the outro has actually disappeared.
    mutating func outroDidFinish() {
        guard phase == .outro else { return }
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
        consecutiveZero = 0
        consecutivePositive = 0
        return wasVisible ? .cancel : .none
    }

    private mutating func resetObservations() {
        lastAcceptedAt = nil
        lastValidACAt = nil
        consecutiveZero = 0
        consecutivePositive = 0
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
