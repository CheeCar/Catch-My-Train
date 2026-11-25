import AppIntents
import CatchText
import SwiftUI
import TransitCore
import WidgetKit

/// Trips shown in the widget: the first ones too soon to catch ("Too soon") are dropped, and the ones worth trying are shown first.
private func visibleTrains(_ direction: BoardDirection) -> [BoardTrain] {
    let rest = Array(direction.trains.drop { $0.verdict == .takeNext })
    return rest.isEmpty ? direction.trains : rest
}

/// Small icon button on the widget.
/// The icon is small; the hit area is at least 22 × 22 pt (bigger than the icon); screen readers read the button's name.
struct WidgetIconButton<I: AppIntent>: View {
    var intent: I
    var systemImage: String
    var label: String
    var size: CGFloat = 15
    /// In a line of small text: the hit area reaches above and below the line, which keeps its height (the medium size has
    /// only a few points to spare)
    var inLine = false

    var body: some View {
        Button(intent: intent) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .help(label)
        .padding(.vertical, inLine ? -5 : 0)
    }
}

/// The station's name. With more than one station nearby, the name and a small › after it are a button that shows the next one
/// (the widget can't open a list); screen readers read "Next station" and the name. Clicking elsewhere still opens the app
struct WidgetStationName: View {
    var station: BoardStation
    var board: NearbyBoard
    var l: UIText
    var size: CGFloat
    var weight: Font.Weight

    var body: some View {
        if board.stations.count > 1 {
            Button(intent: NextStationIntent()) {
                HStack(spacing: 3) {
                    Text(station.name)
                        .font(.system(size: size, weight: weight))
                        .lineLimit(1)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: size - 3, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(l.t("Next station")))
            .accessibilityValue(Text(station.name))
            .help(l.t("Next station"))
        } else {
            Text(station.name)
                .font(.system(size: size, weight: weight))
                .lineLimit(1)
        }
    }
}

/// Standby, in the widget's top corner (the same place as on the widgets with no station or outside the areas), with the
/// standby icon the main window uses
struct WidgetStandbyButton: View {
    var l: UIText
    var size: CGFloat = 15

    var body: some View {
        WidgetIconButton(intent: StandbyTrainsIntent(), systemImage: "moon.zzz", label: l.t("Standby"), size: size)
    }
}

/// Refresh, at the end of the bottom line beside the time the data was updated
struct WidgetRefreshButton: View {
    var l: UIText
    var size: CGFloat = 12
    var inLine = true

    var body: some View {
        WidgetIconButton(intent: RefreshTrainsIntent(), systemImage: "arrow.clockwise", label: l.t("Refresh"), size: size, inLine: inLine)
    }
}

/// Station name (the next-station button), routes, walking time, with standby on the right (refresh is at the bottom).
struct WidgetStationHeader: View {
    var station: BoardStation
    var board: NearbyBoard
    var l: UIText

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                WidgetStationName(station: station, board: board, l: l, size: 13, weight: .bold)
                HStack(spacing: 4) {
                    RouteBullets(routes: station.routes, size: 13, limit: 7)
                    Text(l.f("%@ walk", l.minutes(station.walk.walkSeconds)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if station.range == .extended {
                        // Mark extended-range stations like the main window does
                        WidgetExtendedTag(l: l)
                    }
                }
            }
            Spacer(minLength: 4)
            WidgetStandbyButton(l: l)
        }
    }
}

/// Extended-range station: small gray dashed label (same as in the main window sidebar, not tappable).
struct WidgetExtendedTag: View {
    var l: UIText

    var body: some View {
        Text(l.t("Extended range"))
            // Text no smaller than 10 pt and not scaled down; truncate when it doesn't fit
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
    }
}

/// One trip: the arrival time is most prominent, with small text below for walking time and whether you'll make it.
struct WidgetTrainRow: View {
    var train: BoardTrain
    var l: UIText
    var timeSize: CGFloat = 15
    var badgeSize: CGFloat = 16

    var body: some View {
        let e = train.evaluation
        HStack(alignment: .top, spacing: 5) {
            RouteBadge(route: train.route, size: badgeSize)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Text(l.arrivalTime(e))
                        .font(.system(size: timeSize, weight: .bold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(e.verdict == .takeNext ? Color.secondary : Color.primary)
                    // No realtime data (e.g. Staten Island Ferry), or no train assigned yet: the time comes from the timetable
                    if e.arrival.isTimetableTime {
                        Image(systemName: "calendar")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text(l.t("Timetable")))
                    }
                }
                ViewThatFits(in: .horizontal) {
                    e.verdict.line(l.shortCatchLine(e))
                    e.verdict.line(l.tinyCatchLine(e))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(e.verdict.color)
                .lineLimit(1)
            }
        }
        // Same as the main window: for trips you can't make, only gray out the time; the route badge color stays
        // Read as one sentence, as in the main window (AppText.spokenDeparture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(l.spokenDeparture(train)))
    }
}

/// One column per direction: title and the next few trips.
struct WidgetDirectionColumn: View {
    var direction: BoardDirection
    var rows: Int
    var l: UIText
    var timeSize: CGFloat = 15
    var system: TransitSystem = .subway
    /// Arrival time window from Settings (seconds): with no trips, writes "No trains in the next 2 hr"
    var window: TimeInterval = CatchSettings.defaultArrivalWindowMinutes * 60
    /// The snapshot is used up (see TrainEntry.usedUp): an empty direction asks for the app instead of saying nothing is coming
    var usedUp = false

    var body: some View {
        // Bus stops on only one side of the road (or piers/tram stations served in one direction only): if the other direction has no trips and no terminal name, it takes no space.
        // Empty subway directions have titles saved by the main app (see TransitSnapshot.directionTitles), so they aren't hidden.
        if !(direction.trains.isEmpty && direction.directions.isEmpty) {
            column
        }
    }

    private var column: some View {
        let trains = visibleTrains(direction)
        return VStack(alignment: .leading, spacing: 3) {
            // Always one line, shrunk a little when long; the hidden space keeps it as tall as a full-size line even then, so the
            // trips of two columns side by side start on the same line
            ZStack(alignment: .leading) {
                Text(verbatim: " ").hidden()
                Text(l.directionTitle(direction))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            if trains.isEmpty {
                emptyLines(usedUp ? l.t("Open Catch My Train and refresh once.") : l.noArrivals(system, within: window),
                           next: usedUp ? nil : direction.next.map { l.nextDeparture($0) })
            }
            let first = direction.firstCatchable?.id
            ForEach(trains.prefix(rows)) { train in
                WidgetTrainRow(train: train, l: l, timeSize: timeSize)
                    .padding(.leading, 5)
                    .modifier(FirstCatchableMark(verdict: train.id == first ? train.verdict : nil, inset: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // One group per direction, as in the main window
        .accessibilityElement(children: .contain)
    }

    /// An empty direction's lines: what it has none of and, when that is known, when the next one comes, on a line of its own.
    /// With two rows or more the direction has the room its trips would take. With one row (the small size, the two directions one
    /// above the other) the second line is there only where the first fits on one line, so the two never take more than two lines
    @ViewBuilder
    private func emptyLines(_ none: String, next: String?) -> some View {
        if let next, rows > 1 {
            emptyLine(none, lines: 2)
            emptyLine(next, lines: 1)
        } else if let next {
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 3) {
                    emptyLine(none, lines: 1)
                    emptyLine(next, lines: 1)
                }
                emptyLine(none, lines: 2)
            }
        } else {
            emptyLine(none, lines: 2)
        }
    }

    private func emptyLine(_ text: String, lines: Int) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(lines)
            .minimumScaleFactor(lines == 1 ? 0.8 : 1)
    }
}
