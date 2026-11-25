import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// Settings, Search range page: what is listed and how far away, then when a departure counts as one you can catch.
struct RangeSettingsPage: View {
    @EnvironmentObject var transit: TransitModel
    /// A number typed into a field that was changed to fit (outside the range, or between two steps): the field's title and the
    /// value kept, said under that field until the next change (see numberRow)
    @State private var adjusted: (title: String, value: Double)?
    /// How many times each field's typed number was changed to fit: the field is made again then, so it shows the value kept
    /// even when that's the value it had before
    @State private var fitCounts: [String: Int] = [:]

    var body: some View {
        let l = transit.l10n
        let metric = transit.units == .metric
        SettingsPageForm(.searchRange) {
            Section {
                // Show only trains arriving within this time (default 2 hours). The main window, menu bar, widgets and Plan a Trip all follow it
                AppMenuPicker(l.t("Show arrivals within"), selection: Binding(
                    get: { transit.settings.arrivalWindowSeconds / 60 },
                    set: { transit.settings.arrivalWindowMinutes = $0 }
                ), valueText: l.duration(transit.settings.arrivalWindowSeconds), plain: true) {
                    ForEach(CatchSettings.arrivalWindowChoices, id: \.self) { minutes in
                        Text(l.duration(minutes * 60)).tag(minutes)
                    }
                }
                Text(l.t("Only arrivals within this time from now are listed, in the main window, the menu bar and the widget. Plan a Trip has its own setting, next to the time you leave."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                // See CatchSettings for allowed ranges (not too large, not too small); typed numbers are also clamped to the range and rounded to the step
                numberRow(l.t("Primary range (walk minutes)"), value: $transit.settings.primaryWalkMinutes,
                          range: CatchSettings.primaryWalkRange, step: 1, l: l) { l.f("%@ min", $0) }
                numberRow(l.t("Extended range (walk minutes)"), value: $transit.settings.extendedWalkMinutes,
                          range: transit.settings.primaryWalkMinutes...CatchSettings.extendedWalkMax, step: 1, l: l,
                          note: l.t("At least the primary range")) { l.f("%@ min", $0) }
                numberRow(metric ? l.t("Search radius (m)") : l.t("Search radius (ft)"),
                          value: distanceBinding(\.candidateRadiusMeters),
                          range: metric ? CatchSettings.radiusRangeMeters : feetRadiusRange,
                          step: metric ? 10 : 100, l: l) { metric ? l.f("%@ m", $0) : l.f("%@ ft", $0) }
                // Each section restores its own defaults, changing only its own items
                Button(l.f("Reset to defaults (%@)", rangeDefaultsSummary(l))) {
                    var s = transit.settings
                    s.resetSearchRange()
                    transit.settings = s
                }
                .disabled(transit.settings.isSearchRangeDefault)
                .appButtonStyle()
            } header: {
                // The "widen the range in Settings" buttons scroll here (SettingsJump)
                Text(l.t("Search range"))
                    .settingsSectionTitle()
                    .id(SettingsJump.Target.searchRange.id)
            }

            SettingsSection(l.t("Catch judgment")) {
                numberRow(l.t("Safety buffer (min)"), value: $transit.settings.safetyBufferMinutes,
                          range: CatchSettings.safetyBufferRange, step: 0.5, l: l) { l.f("%@ min", $0) }
                numberRow(metric ? l.t("Walking speed (km/h)") : l.t("Walking speed (mph)"),
                          value: speedBinding,
                          range: metric ? CatchSettings.walkingSpeedRangeKmh : 1.2...4.3,
                          step: 0.1, l: l) { metric ? l.f("%@ km/h", $0) : l.f("%@ mph", $0) }
                Text(l.t("With a walking route, walk time = route length ÷ walking speed. Without one, the straight-line distance is used and marked “estimated”."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                Button(l.f("Reset to defaults (%@)", catchDefaultsSummary(l))) {
                    var s = transit.settings
                    s.resetCatchJudgment()
                    transit.settings = s
                }
                .disabled(transit.settings.isCatchJudgmentDefault)
                .appButtonStyle()
            }
        }
    }

    /// A numeric setting row of this page (SettingNumberRow): the note about a number changed to fit is this page's
    private func numberRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                           l: UIText, note: String? = nil, unit: @escaping (String) -> String) -> some View {
        SettingNumberRow(title: title, value: value, range: range, step: step, l: l, note: note,
                         adjusted: $adjusted, fitCounts: $fitCounts, unit: unit)
    }

    private func rangeDefaultsSummary(_ l: UIText) -> String {
        let d = CatchSettings.default
        return [
            l.duration(d.arrivalWindowSeconds),
            l.minutes(d.primaryWalkSeconds) + " / " + l.minutes(d.extendedWalkSeconds),
            l.radius(d.candidateRadiusMeters),
        ].joined(separator: l.comma)
    }

    private func catchDefaultsSummary(_ l: UIText) -> String {
        let d = CatchSettings.default
        return [
            l.minutes(d.safetyBufferSeconds),
            l.speed(kmh: d.walkingSpeedKmh),
        ].joined(separator: l.comma)
    }

    /// Settings store meters; when feet are selected, this shows and accepts feet.
    private func distanceBinding(_ keyPath: WritableKeyPath<CatchSettings, Double>) -> Binding<Double> {
        Binding(
            // Rounded for display to 100 for feet and 10 for meters (the default 4,000 ft is stored as 1219.2 m, shown as 1,220 m in metric, following the feet conversion).
            // The value used, within the allowed range (one typed in feet by an earlier version can be a little over it)
            get: {
                let step: Double = transit.units == .metric ? 10 : 100
                return (transit.units.displayDistance(fromMeters: transit.settings.sanitized()[keyPath: keyPath]) / step).rounded() * step
            },
            set: { transit.settings[keyPath: keyPath] = transit.units.meters(fromDisplay: $0) }
        )
    }

    /// The search radius's range in feet: the meters' range, rounded inward to the 100 ft step (1,000 to 9,800 ft), so what's
    /// shown can all be used
    private var feetRadiusRange: ClosedRange<Double> {
        let meters = CatchSettings.radiusRangeMeters
        let low = (transit.units.displayDistance(fromMeters: meters.lowerBound) / 100).rounded(.up) * 100
        let high = (transit.units.displayDistance(fromMeters: meters.upperBound) / 100).rounded(.down) * 100
        return low...max(low, high)
    }

    /// Settings store km/h; when feet are selected, this shows and accepts mph.
    private var speedBinding: Binding<Double> {
        Binding(
            get: { (transit.units.displaySpeed(fromKmh: transit.settings.walkingSpeedKmh) * 10).rounded() / 10 },
            set: { transit.settings.walkingSpeedKmh = transit.units.kmh(fromDisplay: $0) }
        )
    }
}
