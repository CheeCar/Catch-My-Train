import Foundation

/// Which detection range a station belongs to.
public enum SearchRange: String, Codable, Sendable {
    case primary
    case extended
}

/// Detection range logic. Nearby trips are grouped by station in `NearbyBoardBuilder`; all that's left here is deciding which range a station is in.
public enum Recommender {

    /// Decides whether a station is in the primary range, the extended range, or out of range (nil).
    public static func classify(walk: WalkEstimate, settings: CatchSettings) -> SearchRange? {
        if walk.walkSeconds <= settings.primaryWalkSeconds && walk.straightLineMeters <= settings.candidateRadiusMeters {
            return .primary
        }
        if walk.walkSeconds <= settings.extendedWalkSeconds && walk.straightLineMeters <= settings.extendedCandidateRadiusMeters {
            return .extended
        }
        return nil
    }
}
