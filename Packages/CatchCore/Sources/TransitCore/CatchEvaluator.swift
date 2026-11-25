import Foundation

/// Catch verdict (four kinds, matching the requirements doc).
public enum CatchVerdict: String, Codable, Sendable, CaseIterable {
    /// Can try to catch: expected to have enough time, but not guaranteed.
    case canTry
    /// Tight: might miss it; judge carefully.
    case tight
    /// Take the next one: expected to miss the current trip.
    case takeNext
    /// Not enough info: data stale, missing, or too uncertain.
    case insufficientInfo
}

/// Reasons for insufficient info or reduced confidence, for UI hints.
public enum CatchNote: String, Codable, Sendable, Hashable {
    /// No arrival prediction
    case missingPrediction
    /// Realtime prediction is stale
    case staleRealtime
    /// Only the scheduled timetable, not a realtime prediction
    case scheduledOnly
    /// Walk time is a straight-line estimate, not a real route
    case walkEstimated
    /// The straight line of the estimate crosses a river or a bay: the real walk may be much longer
    case acrossWater
    /// Mock data
    case mockData
    /// Train delayed
    case delayed
}

/// Confidence.
public enum CatchConfidence: String, Codable, Sendable, Comparable {
    case low, medium, high

    private var rank: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
    public static func < (a: CatchConfidence, b: CatchConfidence) -> Bool { a.rank < b.rank }
}

/// The full verdict for one trip.
///
/// Sign convention for time differences (very important):
///   slackSeconds = the train's time (the one shown) − estimated time reaching the platform
///   · Positive: I reach the platform this many seconds before that;
///   · Negative: the train leaves first; I miss it by this many seconds.
public struct CatchEvaluation: Codable, Hashable, Sendable {
    public var arrival: Arrival
    public var walk: WalkEstimate
    public var evaluatedAt: Date
    /// Estimated time reaching the platform = now + walk time + station entry time
    public var platformArrivalTime: Date
    /// Slack (seconds); see the sign convention above. nil when there's no prediction.
    public var slackSeconds: TimeInterval?
    /// Minimum slack needed for "can try" = safety buffer + uncertainty.
    public var requiredSlackSeconds: TimeInterval
    public var verdict: CatchVerdict
    public var confidence: CatchConfidence
    public var notes: Set<CatchNote>

    /// Seconds until the train arrives (countdown); nil when there's no prediction.
    public var secondsUntilTrain: TimeInterval? {
        arrival.arrivalTime.map { $0.timeIntervalSince(evaluatedAt) }
    }

    /// Total walk + station entry time (seconds).
    public var totalAccessSeconds: TimeInterval { platformArrivalTime.timeIntervalSince(evaluatedAt) }

    /// Earliest time you can actually board: only once both you and the train are at the platform.
    public var boardingTime: Date? {
        guard let t = arrival.arrivalTime else { return nil }
        return max(t, platformArrivalTime)
    }

    /// How much later than `evaluatedAt` you could set off and still get "can try": the slack beyond what it needs (seconds).
    /// nil unless the verdict is "can try". Setting off that much later leaves exactly the slack needed, which is still "can try".
    public var leewaySeconds: TimeInterval? {
        guard verdict == .canTry, let slack = slackSeconds else { return nil }
        return max(0, slack - requiredSlackSeconds)
    }

    /// The latest time to set off for "can try" (Plan a Trip's "Leave by"), rounded down to the minute so setting off at the
    /// minute shown is never too late. In the same time as the train times (server time, see ClockSkew). nil unless "can try".
    public var latestLeave: Date? {
        guard let leeway = leewaySeconds else { return nil }
        let t = evaluatedAt.addingTimeInterval(leeway).timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 60).rounded(.down) * 60)
    }
}

/// Core decision logic. A pure function: the same input always gives the same output, which makes it easy to test.
/// The clock offset is an input too; callers that leave it out get the app's measured offset (ClockSkew.current).
/// `now` is when you set off. `observedAt` is when the data was looked at, for the staleness check; it is the same as `now`
/// unless given, which is right for the board and the widget timeline. Plan a Trip sets off later than it looks.
public enum CatchEvaluator {

    /// Uncertainty ratio for estimated walk time (extra slack required for straight-line estimates).
    public static let estimatedWalkUncertaintyRatio: Double = 0.15
    /// Extra slack (seconds) required when there's only a scheduled timetable.
    public static let scheduledUncertaintySeconds: TimeInterval = 60

    public static func evaluate(
        arrival: Arrival,
        walk: WalkEstimate,
        entranceToPlatformSeconds: TimeInterval,
        settings: CatchSettings,
        now localNow: Date,
        clockOffset: TimeInterval = ClockSkew.current,
        observedAt: Date? = nil
    ) -> CatchEvaluation {
        // When the local clock differs too much from the server, judge by server time (see ClockSkew)
        let now = localNow.addingTimeInterval(clockOffset)
        let observed = (observedAt ?? localNow).addingTimeInterval(clockOffset)
        let platformArrival = now.addingTimeInterval(walk.walkSeconds + entranceToPlatformSeconds)
        var notes = Set<CatchNote>()
        var uncertainty: TimeInterval = 0
        var confidence: CatchConfidence = .high

        if walk.source == .estimated {
            notes.insert(.walkEstimated)
            uncertainty += walk.walkSeconds * estimatedWalkUncertaintyRatio
            confidence = min(confidence, .medium)
        }
        if walk.isAcrossWater { notes.insert(.acrossWater) }
        switch arrival.source {
        case .realtime:
            // In the realtime data but no train assigned yet: the time is still the timetable's, so judge it like one.
            // It still goes stale like any realtime data (checked below).
            if arrival.isAssigned == false {
                notes.insert(.scheduledOnly)
                uncertainty += scheduledUncertaintySeconds
                confidence = min(confidence, .medium)
            }
        case .scheduled:
            notes.insert(.scheduledOnly)
            uncertainty += scheduledUncertaintySeconds
            confidence = min(confidence, .medium)
        case .mock:
            notes.insert(.mockData)
        }
        if arrival.status == .delayed { notes.insert(.delayed) }

        let required = settings.safetyBufferSeconds + uncertainty

        func result(_ verdict: CatchVerdict, slack: TimeInterval?, confidence: CatchConfidence) -> CatchEvaluation {
            CatchEvaluation(
                arrival: arrival, walk: walk, evaluatedAt: now,
                platformArrivalTime: platformArrival, slackSeconds: slack,
                requiredSlackSeconds: required, verdict: verdict,
                confidence: confidence, notes: notes
            )
        }

        guard let trainTime = arrival.arrivalTime else {
            notes.insert(.missingPrediction)
            return result(.insufficientInfo, slack: nil, confidence: .low)
        }

        // Counted to the train's one time, the one shown (Arrival.arrivalTime)
        let slack = trainTime.timeIntervalSince(platformArrival)

        // Realtime prediction stale: can't judge reliably (a scheduled timetable never "goes stale", but its confidence is already lowered;
        // Demo mode's made-up times don't either: on standby it doesn't make new ones, and they'd all turn "Not sure" after 3 minutes)
        if arrival.source == .realtime,
           observed.timeIntervalSince(arrival.updatedAt) > settings.realtimeStaleAfterSeconds {
            notes.insert(.staleRealtime)
            return result(.insufficientInfo, slack: slack, confidence: .low)
        }

        let verdict: CatchVerdict
        if slack >= required {
            verdict = .canTry
        } else if slack >= 0 {
            verdict = .tight
        } else {
            verdict = .takeNext
        }
        // Across the water the real walk may be much longer than the estimate: never "can try" or "tight" on it. Missing it
        // already on the estimate stays "take the next one"
        if walk.isAcrossWater, verdict != .takeNext {
            return result(.insufficientInfo, slack: slack, confidence: .low)
        }
        return result(verdict, slack: slack, confidence: confidence)
    }
}
