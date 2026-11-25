import AppIntents
import CatchText
import SwiftUI
import TransitCore
import WidgetKit

/// Small size: one station, one trip in each direction.
struct SmallStationView: View {
    var station: BoardStation
    var board: NearbyBoard
    var entry: TrainEntry
    var snap: TransitSnapshot
    var l: UIText

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                WidgetAreaLine(snap: snap, l: l, iconOnly: true)
                WidgetStationName(station: station, board: board, l: l, size: 12, weight: .semibold)
                Spacer(minLength: 0)
                // Standby in the top corner, refresh at the bottom beside the time, as in the larger sizes
                WidgetStandbyButton(l: l, size: 13)
            }
            let usedUp = entry.usedUp(snap, l)
            WidgetDirectionColumn(direction: station.north, rows: 1, l: l, timeSize: 17, system: snap.transitSystem,
                                  window: snap.settings.arrivalWindowSeconds, usedUp: usedUp)
            WidgetDirectionColumn(direction: station.south, rows: 1, l: l, timeSize: 17, system: snap.transitSystem,
                                  window: snap.settings.arrivalWindowSeconds, usedUp: usedUp)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                // The status and the time can't both fit beside the button: first drop the part that only says where the data
                // comes from ("MTA live"), keeping the time; a notice (e.g. "Demo data only") is kept and the time dropped
                // instead, rather than cutting both. Only this one line is measured, not the whole layout.
                ViewThatFits(in: .horizontal) {
                    WidgetStatusLine(snap: snap, entry: entry, l: l, station: station, compact: true)
                    WidgetStatusLine(snap: snap, entry: entry, l: l, station: station, compact: true, showsSource: false)
                    WidgetStatusLine(snap: snap, entry: entry, l: l, station: station, compact: true, showsTime: false)
                }
                Spacer(minLength: 0)
                WidgetRefreshButton(l: l, size: 13, inLine: false)
            }
        }
    }
}

/// Medium size: one station, two directions side by side, two trips each.
struct MediumStationView: View {
    var station: BoardStation
    var board: NearbyBoard
    var entry: TrainEntry
    var snap: TransitSnapshot
    var l: UIText

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetStationHeader(station: station, board: board, l: l)
            HStack(alignment: .top, spacing: 10) {
                let usedUp = entry.usedUp(snap, l)
                WidgetDirectionColumn(direction: station.north, rows: 2, l: l, system: snap.transitSystem,
                                      window: snap.settings.arrivalWindowSeconds, usedUp: usedUp)
                WidgetDirectionColumn(direction: station.south, rows: 2, l: l, system: snap.transitSystem,
                                      window: snap.settings.arrivalWindowSeconds, usedUp: usedUp)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                WidgetAreaLine(snap: snap, l: l)
                    .layoutPriority(-1)
                // The gap gets space last: first the status, then the mode and region
                Spacer(minLength: 0)
                    .layoutPriority(-2)
                WidgetStatusLine(snap: snap, entry: entry, l: l, station: station)
                WidgetRefreshButton(l: l)
            }
        }
    }
}

/// Large size: one station with four trips per direction, and other nearby stations below (tap one to switch to it).
struct LargeStationView: View {
    var station: BoardStation
    var board: NearbyBoard
    var entry: TrainEntry
    var snap: TransitSnapshot
    var l: UIText

    var body: some View {
        // When space is short, show fewer trips and nearby stations, so text doesn't overflow the widget.
        // Compute the row count directly instead of ViewThatFits: that lays out every arrangement on each draw, spiking widget CPU to 100%.
        // Train route labels and direction names are longer, so the title takes an extra line. "Walking from …" shares its line with
        // "Estimates only"; only the line saying how approximate the current position is adds one more line: one fewer nearby station.
        // Subway etc. with 4 trips still overflowed, so all show 3 trips.
        let rows = 3
        let placeLines = snap.placeNote != nil ? 1 : 0
        content(rows: rows, others: max(1, 3 - placeLines))
    }

    private func content(rows: Int, others count: Int) -> some View {
        let others = board.stations.filter { $0.id != station.id }.prefix(count)
        return VStack(alignment: .leading, spacing: 8) {
            WidgetStationHeader(station: station, board: board, l: l)
            HStack(alignment: .top, spacing: 12) {
                let usedUp = entry.usedUp(snap, l)
                WidgetDirectionColumn(direction: station.north, rows: rows, l: l, system: snap.transitSystem,
                                      window: snap.settings.arrivalWindowSeconds, usedUp: usedUp)
                WidgetDirectionColumn(direction: station.south, rows: rows, l: l, system: snap.transitSystem,
                                      window: snap.settings.arrivalWindowSeconds, usedUp: usedUp)
            }
            if !others.isEmpty {
                Divider()
                Text(l.pick(snap.transitSystem, train: l.t("Nearby stations"), bus: l.t("Nearby bus stops"),
                            ferry: l.t("Nearby piers")))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(others)) { other in
                    Button(intent: SelectStationIntent(stationID: other.id)) {
                        OtherStationRow(station: other, l: l, arrows: snap.transitSystem.mode == .subway)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                // How approximate the current position is (the same line as under the place's name in the app). It is long, so it
                // keeps a line of its own, with "Estimates only" close under it
                if let note = snap.placeNote {
                    Text(note)
                        .minimumScaleFactor(0.8)
                }
                // The times are estimates. Only one time on the widget says when: "Updated" in the line below (the widget shows times
                // only when this Mac's clock reads the area's time, so no zone is needed). A chosen place shares the line, joined
                // like the status line: "Walking from <place> · Estimates only"; when it is too long, the place's name is cut first
                HStack(spacing: 3) {
                    if snap.placeName != l.t("Current location") {
                        // May be a home address: macOS redacts it during screen sharing and on the lock screen
                        Text(l.f("Walking from %@", snap.placeName))
                            .privacySensitive()
                        Text("·")
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    Text(l.t("Estimates only"))
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // Mode and region at the bottom, in the same position and order for space as the medium size
            HStack(spacing: 6) {
                WidgetAreaLine(snap: snap, l: l)
                    .layoutPriority(-1)
                Spacer(minLength: 0)
                    .layoutPriority(-2)
                WidgetStatusLine(snap: snap, entry: entry, l: l, station: station)
                WidgetRefreshButton(l: l)
            }
        }
    }
}

/// Other nearby stations in the large size: routes, station name, walking time, and the earliest trip worth trying in either direction.
struct OtherStationRow: View {
    var station: BoardStation
    var l: UIText
    /// Subway directions are northbound/southbound, shown with up/down arrows; bus, train and ferry directions aren't north/south, so only the earliest catchable trip is shown
    var arrows = true

    /// The direction of the earliest catchable trip of the two directions
    private var earliest: BoardDirection? {
        [station.north, station.south].filter { $0.firstCatchable?.arrivalTime != nil }
            .min { $0.firstCatchable!.arrivalTime! < $1.firstCatchable!.arrivalTime! }
    }

    var body: some View {
        HStack(spacing: 5) {
            RouteBullets(routes: station.routes, size: 12, limit: 3)
            Text(station.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(l.minutes(station.walk.walkSeconds))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            Spacer(minLength: 4)
            ForEach(arrows ? [station.north, station.south] : [earliest].compactMap { $0 }, id: \.code) { direction in
                if let t = direction.firstCatchable?.arrivalTime {
                    HStack(spacing: 1) {
                        if arrows {
                            Image(systemName: direction.code == "S" ? "arrow.down" : "arrow.up")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text(l.time(t))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                }
            }
        }
    }
}

/// Standby: no refresh, no downloads, only a "Start" button.
struct WidgetStandbyView: View {
    var l: UIText
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                Text(l.t("Standby")).font(.headline)
            }
            Text(l.t("Nothing is refreshed or downloaded on standby."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 3 : 2)
            Spacer(minLength: 0)
            Button(intent: StartTrainsIntent()) {
                StartLabel(title: l.t("Start"))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Has data, but no stations within walking range.
struct NoStationView: View {
    var entry: TrainEntry
    var snap: TransitSnapshot
    var l: UIText

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: snap.isBus ? "bus" : snap.isFerry ? "ferry"
                  : snap.transitSystem == .subway ? "tram" : snap.transitSystem.symbol)
            Text(l.pick(snap.transitSystem, train: l.t("No trains to suggest"), bus: l.t("No buses to suggest"),
                        ferry: l.t("No ferries to suggest"))).font(.headline)
            // Same reason as the main window (e.g. timetables still downloading); older snapshots don't have it.
            // What only the running app gets past (downloading, loading) isn't repeated once it has quit: ask for it instead
            Text(snap.emptyTextHolds(appRunning: entry.appRunning) ? (snap.emptyText ?? l.noStationNearby(snap.transitSystem))
                     : l.t("Open Catch My Train and refresh once."))
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 0)
            WidgetStatusLine(snap: snap, entry: entry, l: l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Standby is reachable here too (beside the icon, so nothing moves): while on, Catch My Train keeps refreshing
        .overlay(alignment: .topTrailing) {
            WidgetStandbyButton(l: l, size: 13)
        }
    }
}

/// No data yet: the main app was never opened, or the folder shared with it can't be used.
struct NoDataView: View {
    var l: UIText

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "tram")
            Text(l.t("No data yet")).font(.headline)
            Text(SharedStore.isSharedFolderUsable ? l.t("Open Catch My Train and refresh once.")
                                                  : l.t("The widget can't read Catch My Train's data. Try reinstalling Catch My Train."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
