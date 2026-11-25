import Foundation

/// User-adjustable catch settings. Defaults come from product requirements, not fixed geographic rules.
/// Settings saved by older versions still contain the unused `extendedBetterByMinutes`, which is simply ignored when decoding.
public struct CatchSettings: Codable, Hashable, Sendable {
    /// Primary search range: walking minutes (default 15).
    public var primaryWalkMinutes: Double
    /// Extended search range: walking minutes (default 20).
    public var extendedWalkMinutes: Double
    /// Search radius (meters, default 1219.2 = 4,000 ft): the straight-line prefilter for the primary range; the extended range uses
    /// the larger of this and extended walk time × walking speed (see extendedCandidateRadiusMeters).
    public var candidateRadiusMeters: Double
    /// Catch safety buffer (minutes, default 2).
    public var safetyBufferMinutes: Double
    /// Walking speed (km/h, default 4.5): turns an Apple Maps route length into walk time, and estimates walks that have no route (see WalkEstimator).
    public var walkingSpeedKmh: Double
    /// Detour factor applied to straight-line distance when there's no real route (streets aren't straight).
    public var detourFactor: Double
    /// Realtime predictions older than this many seconds count as stale (default 180, at most 600: an hour-old prediction can't count as fresh).
    public var realtimeStaleAfterSeconds: TimeInterval
    /// Only show trains arriving within this many minutes (default 120).
    /// Settings saved by older versions lack this; it reads as nil and the default is used.
    public var arrivalWindowMinutes: Double?

    public init(
        primaryWalkMinutes: Double = 15,
        extendedWalkMinutes: Double = 20,
        candidateRadiusMeters: Double = CatchSettings.defaultRadiusMeters,
        safetyBufferMinutes: Double = 2,
        walkingSpeedKmh: Double = 4.5,
        detourFactor: Double = 1.25,
        realtimeStaleAfterSeconds: TimeInterval = 180,
        arrivalWindowMinutes: Double? = CatchSettings.defaultArrivalWindowMinutes
    ) {
        self.primaryWalkMinutes = primaryWalkMinutes
        self.extendedWalkMinutes = extendedWalkMinutes
        self.candidateRadiusMeters = candidateRadiusMeters
        self.safetyBufferMinutes = safetyBufferMinutes
        self.walkingSpeedKmh = walkingSpeedKmh
        self.detourFactor = detourFactor
        self.realtimeStaleAfterSeconds = realtimeStaleAfterSeconds
        self.arrivalWindowMinutes = arrivalWindowMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case primaryWalkMinutes, extendedWalkMinutes, candidateRadiusMeters, safetyBufferMinutes
        case walkingSpeedKmh, detourFactor, realtimeStaleAfterSeconds, arrivalWindowMinutes
    }

    /// When reading saved settings, any missing item (absent in older versions, or added later) uses that item's default,
    /// and the rest are kept, so one unreadable item never resets all settings to defaults (updates must not lose data).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CatchSettings()
        func value(_ key: CodingKeys, _ fallback: Double) -> Double {
            (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback
        }
        self.init(
            primaryWalkMinutes: value(.primaryWalkMinutes, d.primaryWalkMinutes),
            extendedWalkMinutes: value(.extendedWalkMinutes, d.extendedWalkMinutes),
            candidateRadiusMeters: value(.candidateRadiusMeters, d.candidateRadiusMeters),
            safetyBufferMinutes: value(.safetyBufferMinutes, d.safetyBufferMinutes),
            walkingSpeedKmh: value(.walkingSpeedKmh, d.walkingSpeedKmh),
            detourFactor: value(.detourFactor, d.detourFactor),
            realtimeStaleAfterSeconds: value(.realtimeStaleAfterSeconds, d.realtimeStaleAfterSeconds),
            arrivalWindowMinutes: (try? c.decodeIfPresent(Double.self, forKey: .arrivalWindowMinutes))
        )
    }

    /// Default search radius: 4,000 feet. Metric converts accordingly, showing 1,220 m.
    public static let defaultRadiusMeters: Double = 1219.2
    /// The earlier default radius (1,200 m), upgraded to 4,000 ft (see upgradingPreviousRadiusDefault)
    public static let previousDefaultRadiusMeters: Double = 1200

    /// If the radius is still the old default of 1200 m (unchanged by the user), switch to the new 4,000 feet; other settings stay the same.
    public func upgradingPreviousRadiusDefault() -> CatchSettings {
        guard candidateRadiusMeters == Self.previousDefaultRadiusMeters else { return self }
        var s = self
        s.candidateRadiusMeters = Self.defaultRadiusMeters
        return s
    }

    /// Default and selectable values (minutes) for the arrival time window in Settings.
    public static let defaultArrivalWindowMinutes: Double = 120
    public static let arrivalWindowChoices: [Double] = [30, 60, 90, 120, 180, 240]

    /// Only show trains arriving within this many seconds.
    public var arrivalWindowSeconds: TimeInterval {
        let minutes = arrivalWindowMinutes.flatMap { $0.isFinite ? $0 : nil } ?? Self.defaultArrivalWindowMinutes
        return min(max(minutes, 10), 720) * 60
    }

    /// Defaults: 15 / 20 minutes and 4,000 ft (1219.2 m), so a station about 16 minutes away on foot is still within the extended range (ReferenceTripTests).
    public static let `default` = CatchSettings()

    /// Default ranges of the first versions: settings still on all three are upgraded to the current defaults.
    public static let legacyRangeDefaults = (primaryWalkMinutes: 8.0, extendedWalkMinutes: 12.0, candidateRadiusMeters: 800.0)

    /// If the three range settings are still the old defaults (unchanged by the user), switch to the new defaults; other settings stay the same.
    public func upgradingLegacyRangeDefaults() -> CatchSettings {
        let old = Self.legacyRangeDefaults
        guard primaryWalkMinutes == old.primaryWalkMinutes,
              extendedWalkMinutes == old.extendedWalkMinutes,
              candidateRadiusMeters == old.candidateRadiusMeters else { return self }
        var s = self
        s.primaryWalkMinutes = Self.default.primaryWalkMinutes
        s.extendedWalkMinutes = Self.default.extendedWalkMinutes
        s.candidateRadiusMeters = Self.default.candidateRadiusMeters
        return s
    }

    public var safetyBufferSeconds: TimeInterval { safetyBufferMinutes * 60 }
    public var primaryWalkSeconds: TimeInterval { primaryWalkMinutes * 60 }
    public var extendedWalkSeconds: TimeInterval { extendedWalkMinutes * 60 }
    public var walkingSpeedMetersPerSecond: Double { walkingSpeedKmh * 1000 / 3600 }

    /// Straight-line prefilter radius for the extended range: the larger of "initial radius" and "extended walk time × speed",
    /// otherwise the extended range would be cut off by the initial radius (default: max(1219.2, 20 min × 75 m/min) = 1500 m).
    public var extendedCandidateRadiusMeters: Double {
        max(candidateRadiusMeters, extendedWalkSeconds * walkingSpeedMetersPerSecond)
    }

    /// Radius of the primary range circle on the map (meters): how far a walk with no route reaches in the primary walk time
    /// (walk time × speed ÷ detour factor, the estimate WalkEstimator makes), at most the search radius, as in Recommender.classify.
    /// Defaults: 15 min × 1.25 m/s ÷ 1.25 = 900 m. Real walking routes can be longer or shorter, so the circle is only a guide.
    public var primaryRangeRadiusMeters: Double {
        rangeRadiusMeters(walkSeconds: primaryWalkSeconds, limit: candidateRadiusMeters)
    }

    /// Radius of the extended range circle on the map (meters), worked out the same way (defaults: 20 min, 1,200 m), at most extendedCandidateRadiusMeters.
    public var extendedRangeRadiusMeters: Double {
        rangeRadiusMeters(walkSeconds: extendedWalkSeconds, limit: extendedCandidateRadiusMeters)
    }

    private func rangeRadiusMeters(walkSeconds: TimeInterval, limit: Double) -> Double {
        guard detourFactor > 0 else { return limit }
        return min(walkSeconds * walkingSpeedMetersPerSecond / detourFactor, limit)
    }

    /// Clamps unreasonable input into a safe range, so a typo in Settings can't break the calculation.
    // Allowed ranges for the numbers in Settings (neither too large nor too small). Used by the Settings steppers, manual entry and saving.
    /// Primary range: 3–30 minutes on foot
    public static let primaryWalkRange: ClosedRange<Double> = 3...30
    /// Extended range: no less than the primary range, at most 45 minutes
    public static let extendedWalkMax: Double = 45
    /// Search radius: 300–3000 m (about 1,000–10,000 ft). Any smaller and there's often no stop nearby; any larger means too many stops to query and too far to walk
    public static let radiusRangeMeters: ClosedRange<Double> = 300...3000
    /// Safety buffer: 0–10 minutes
    public static let safetyBufferRange: ClosedRange<Double> = 0...10
    /// Walking speed: 2–7 km/h (about 1.2–4.3 mph), the range of normal walking
    public static let walkingSpeedRangeKmh: ClosedRange<Double> = 2...7
    /// When realtime data counts as stale: 30 seconds to 10 minutes
    public static let realtimeStaleRange: ClosedRange<Double> = 30...600

    /// The shortest "Real-time data expires after" that works with a refresh interval: a minute more than it, so live data doesn't
    /// count as stale between two refreshes. In steps of 30 seconds (as in Settings), within realtimeStaleRange
    public static func realtimeStaleMinimum(refreshInterval: TimeInterval) -> Double {
        let interval = refreshInterval.isFinite ? max(0, refreshInterval) : 0
        let minimum = ((interval + 60) / 30).rounded(.up) * 30
        return min(max(minimum, realtimeStaleRange.lowerBound), realtimeStaleRange.upperBound)
    }

    /// The "Real-time data expires after" the app uses with this refresh interval: the setting (within its range), and at least
    /// realtimeStaleMinimum. Settings shows this one; the saved setting stays as it was set, so a shorter refresh interval brings it back
    public func realtimeStale(refreshInterval: TimeInterval) -> Double {
        max(sanitized().realtimeStaleAfterSeconds, Self.realtimeStaleMinimum(refreshInterval: refreshInterval))
    }

    public func sanitized() -> CatchSettings {
        var s = self
        let d = Self.default
        // A value that isn't a number (NaN) would pass min and max unchanged, and NaN...45 below would crash: use the default instead
        func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
            min(max(v.isFinite ? v : fallback, r.lowerBound), r.upperBound)
        }
        s.primaryWalkMinutes = clamp(s.primaryWalkMinutes, Self.primaryWalkRange, d.primaryWalkMinutes)
        s.extendedWalkMinutes = clamp(s.extendedWalkMinutes, s.primaryWalkMinutes...Self.extendedWalkMax, d.extendedWalkMinutes)
        s.candidateRadiusMeters = clamp(s.candidateRadiusMeters, Self.radiusRangeMeters, d.candidateRadiusMeters)
        s.safetyBufferMinutes = clamp(s.safetyBufferMinutes, Self.safetyBufferRange, d.safetyBufferMinutes)
        s.walkingSpeedKmh = clamp(s.walkingSpeedKmh, Self.walkingSpeedRangeKmh, d.walkingSpeedKmh)
        s.detourFactor = clamp(s.detourFactor, 1...3, d.detourFactor)
        // At most 10 minutes (same as the Settings range): predictions that old can't count as fresh
        s.realtimeStaleAfterSeconds = clamp(s.realtimeStaleAfterSeconds, Self.realtimeStaleRange, d.realtimeStaleAfterSeconds)
        s.arrivalWindowMinutes = s.arrivalWindowSeconds / 60
        return s
    }
}

// Plan a Trip's own walk: chosen in its window, kept until the app quits, and never saved to Settings
public extension CatchSettings {
    /// The walks Plan a Trip offers (minutes); the extended range from Settings is added to them (see plannerWalkChoices)
    static let plannerWalks: [Double] = [10, 15, 20, 30, 45]

    /// The walks to choose from in Plan a Trip, shortest first: plannerWalks and the extended range from Settings (its default)
    func plannerWalkChoices() -> [Double] {
        Array(Set(Self.plannerWalks + [sanitized().extendedWalkMinutes])).sorted()
    }

    /// The settings Plan a Trip searches with when a walk is chosen there: that walk is the farthest one (the extended range), and
    /// the primary range from Settings stays, cut to that walk when it's longer. nil, or a value that isn't a number: Settings as they are.
    func walking(upTo minutes: Double?) -> CatchSettings {
        var s = sanitized()
        guard let minutes, minutes.isFinite else { return s }
        let walk = min(max(minutes, Self.primaryWalkRange.lowerBound), Self.extendedWalkMax)
        s.primaryWalkMinutes = min(s.primaryWalkMinutes, walk)
        s.extendedWalkMinutes = walk
        return s
    }
}

// Separate "Reset to defaults" for each section of the Settings window that has numbers (Search range, Catch judgment, Advanced)
public extension CatchSettings {
    /// Search range: arrival time window, primary and extended ranges, search radius
    mutating func resetSearchRange() {
        let d = CatchSettings.default
        arrivalWindowMinutes = d.arrivalWindowMinutes
        primaryWalkMinutes = d.primaryWalkMinutes
        extendedWalkMinutes = d.extendedWalkMinutes
        candidateRadiusMeters = d.candidateRadiusMeters
    }

    /// Catch judgment: safety buffer and walking speed (plus the detour factor, not shown in the UI)
    mutating func resetCatchJudgment() {
        let d = CatchSettings.default
        safetyBufferMinutes = d.safetyBufferMinutes
        walkingSpeedKmh = d.walkingSpeedKmh
        detourFactor = d.detourFactor
    }

    /// Advanced: when realtime data counts as stale
    mutating func resetAdvanced() {
        realtimeStaleAfterSeconds = CatchSettings.default.realtimeStaleAfterSeconds
    }

    /// The radius shows rounded (to 10 m, or 100 ft): the default 4,000 ft is stored as 1,219.2 m and shown as 1,220 m, so a radius
    /// within a meter of the default counts as the default, as it looks
    var isSearchRangeDefault: Bool {
        var s = self
        s.resetSearchRange()
        guard abs(candidateRadiusMeters - s.candidateRadiusMeters) < 1 else { return false }
        s.candidateRadiusMeters = candidateRadiusMeters
        return s == self
    }

    /// The walking speed shows rounded (to 0.1 km/h, or 0.1 mph): 2.8 mph typed in is stored as 4.506 km/h, near the default 4.5,
    /// so a speed within 0.05 km/h of the default counts as the default, as it looks in either unit
    var isCatchJudgmentDefault: Bool {
        var s = self
        s.resetCatchJudgment()
        guard abs(walkingSpeedKmh - s.walkingSpeedKmh) < Self.sameWalkingSpeedKmh else { return false }
        s.walkingSpeedKmh = walkingSpeedKmh
        return s == self
    }

    /// How far apart two walking speeds can be and still show the same in both units (half the 0.1 km/h step)
    static let sameWalkingSpeedKmh = 0.05

    var isAdvancedDefault: Bool {
        var s = self
        s.resetAdvanced()
        return s == self
    }
}
