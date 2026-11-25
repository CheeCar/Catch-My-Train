import Foundation

/// Distance units: metric (meters, km/h) or US (feet, mph).
/// All calculations use meters; this only handles conversion for display and Settings input.
public enum DistanceUnit: String, CaseIterable, Codable, Identifiable, Sendable {
    case metric
    case usCustomary = "us"

    /// Defaults to US (feet, mph)
    public static let `default`: DistanceUnit = .usCustomary

    public static let feetPerMeter = 3.280_839_895
    public static let kilometersPerMile = 1.609_344

    public var id: String { rawValue }

    /// Meters → display value (meters or feet).
    public func displayDistance(fromMeters meters: Double) -> Double {
        self == .metric ? meters : meters * Self.feetPerMeter
    }

    /// Display value (meters or feet) → meters.
    public func meters(fromDisplay value: Double) -> Double {
        self == .metric ? value : value / Self.feetPerMeter
    }

    /// km/h → display value (km/h or mph).
    public func displaySpeed(fromKmh kmh: Double) -> Double {
        self == .metric ? kmh : kmh / Self.kilometersPerMile
    }

    /// Display value (km/h or mph) → km/h.
    public func kmh(fromDisplay value: Double) -> Double {
        self == .metric ? value : value * Self.kilometersPerMile
    }
}

/// Clock format: 12-hour ("2:05 PM", default) or 24-hour ("14:05"), switchable in Settings.
/// Every place that shows a clock time follows this: the main window, trip planner, menu bar panel and widgets.
public enum ClockStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case twelveHour = "12"
    case twentyFourHour = "24"

    public static let `default`: ClockStyle = .twelveHour

    public var id: String { rawValue }

    /// Format template for the time part (for DateFormatter.dateFormat(fromTemplate:), ordered per locale)
    func template(seconds: Bool) -> String {
        switch self {
        case .twelveHour: return seconds ? "hmmssa" : "hmma"
        case .twentyFourHour: return seconds ? "HHmmss" : "HHmm"
        }
    }
}
