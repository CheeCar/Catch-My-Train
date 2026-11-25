import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

/// How the blocks of all cards are laid out (PlannerView.chipLayout): one width for every block, measured; where the direction names go
struct PlannerChipLayout: Equatable {
    var chipWidth: CGFloat
    var labelWidth: CGFloat
    /// The room for blocks beside the direction names, and under them
    var sideRoom: CGFloat
    var stackedRoom: CGFloat
    /// The direction names above the blocks (in every card)
    var stacked: Bool

    static let spacing: CGFloat = 6
    /// The most blocks a direction shows (the board keeps no more)
    static let most = 6

    /// How many blocks fit side by side in `room` (at least 1; 3 before anything is measured)
    func perRow(_ room: CGFloat) -> Int {
        guard chipWidth > 0, room > 0 else { return 3 }
        return max(1, Int((room + Self.spacing) / (chipWidth + Self.spacing)))
    }
}

/// One station in the trip planner's results: its name, lines and walk on top (the walk moves under them when there's no room),
/// then each direction's name and its departures as small blocks: as many as fit in one row, up to 6, at least 3 (in two rows if
/// they don't fit in one)
struct PlannerStationCard: View {
    @EnvironmentObject var transit: TransitModel
    var station: BoardStation
    var l: UIText
    /// How far after departure to look for trains (the trip planner's own setting)
    var window: TimeInterval
    var layout: PlannerChipLayout
    /// Leaving within 30 minutes with live data: the hover text says how soon each comes, and timetable times among the live ones are marked
    var live: Bool
    var now: Date
    /// The block the mouse is on (PlannerTipSource)
    var hover: PlannerHover
    /// The block of this card that shows its hover text as if the mouse were on it; nil: none
    var tipSample: PlannerTipSample?
    /// Selects the station (with the map column): screen readers press the station's name for it, as a click on the card
    var select: (() -> Void)? = nil

    static let padding: CGFloat = 12
    static let labelGap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let place = station.noTimes {
                // An operator that publishes no times the app can use: the station page's notice in place of the directions
                NoTimesNotice(place: place, l: l, boxed: false)
            } else {
                let hasNorth = transit.hasDirection(station.north, in: station)
                let hasSouth = transit.hasDirection(station.south, in: station)
                // A bus stop on only one side of the street has only one direction
                let shown = hasNorth && hasSouth ? [station.north, station.south] : [hasSouth ? station.south : station.north]
                ForEach(shown, id: \.code) { direction in
                    row(direction, sample: direction.code == shown.first?.code ? tipSample : nil)
                }
            }
        }
        .padding(.horizontal, Self.padding)
        .padding(.vertical, 10)
        // As wide as the list gives, never wider: while the window is being made narrower, blocks laid out for the width just left
        // behind mustn't widen the list (which would then keep that width)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }

    // MARK: Station

    /// Name, lines (their "+N" always shown) and the walk in one line; the walk on a line of its own when they don't fit
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    nameAndLines
                    Spacer(minLength: 8)
                    walk
                }
                VStack(alignment: .leading, spacing: 4) {
                    nameAndLines
                    walk
                }
            }
            if station.walk.isAcrossWater {
                AcrossWaterNote(l: l)
                    .font(.scaled(.callout))
            }
        }
    }

    private var nameAndLines: some View {
        HStack(spacing: 8) {
            Text(station.name)
                .font(.scaled(.headline))
                .lineLimit(2)
                .modifier(SelectsStation(select: select))
            if let place = station.noTimes {
                KindBox(text: place.agency.shortName)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                RouteBullets(routes: station.routes, size: 16, limit: 10)
                    .fixedSize()
            }
        }
    }

    /// The walk, its range (the icons of the main window's list) and, hovered, how it was worked out
    private var walk: some View {
        HStack(spacing: 5) {
            Image(systemName: station.range == .extended ? "circle.dashed" : "circle.circle")
                .accessibilityHidden(true)
            Text(l.f("%@ walk", l.minutes(station.walk.walkSeconds)))
            if station.range == .extended {
                ExtendedRangeTag(l: l)
            }
        }
        .font(.scaled(.callout))
        .foregroundStyle(.secondary)
        .help(walkDetails)
    }

    /// Two lines: how long the walk is, how far and how it was found; then the time from reaching it to boarding (UIText.boardingLine:
    /// none at MTA's bus stops)
    private var walkDetails: String {
        let w = station.walk
        var lines = [l.f("Walk: %1$@, %2$@ (%3$@)", l.minutes(w.walkSeconds), l.distance(w.routeMeters ?? w.straightLineMeters),
                         l.walkSource(w.source))]
        if station.noTimes == nil, let nearest = station.stations.first,
           let boarding = l.boardingLine(seconds: nearest.entranceToPlatformSeconds, routes: station.routes) {
            lines.append(boarding)
        }
        if w.isAcrossWater { lines.append(l.note(.acrossWater)) }
        return lines.joined(separator: "\n")
    }

    // MARK: Directions

    /// One direction: its name beside its blocks, or above them (PlannerChipLayout.stacked)
    @ViewBuilder
    private func row(_ direction: BoardDirection, sample: PlannerTipSample?) -> some View {
        let title = transit.directionTitle(direction, in: station, fromCatalog: true)
        if layout.stacked {
            VStack(alignment: .leading, spacing: 5) {
                directionName(title, lines: 2)
                blocks(direction, room: layout.stackedRoom, sample: sample)
            }
        } else {
            HStack(alignment: .top, spacing: Self.labelGap) {
                directionName(title, lines: 3)
                    .frame(width: layout.labelWidth, alignment: .leading)
                    // Level with the first line of the blocks
                    .padding(.top, 5 * TextScale.factor)
                blocks(direction, room: layout.sideRoom, sample: sample)
            }
        }
    }

    private func directionName(_ title: String, lines: Int) -> some View {
        Text(title)
            .font(.scaled(.subheadline).bold())
            .foregroundStyle(.secondary)
            .lineLimit(lines)
            .help(title)
    }

    @ViewBuilder
    private func blocks(_ direction: BoardDirection, room: CGFloat, sample: PlannerTipSample?) -> some View {
        let trains = direction.trains
        if trains.isEmpty {
            // The time range chosen here, counted from the departure time
            let d = l.duration(window)
            Text(l.pick(transit.system, train: l.f("No trains in the %@ after you leave", d),
                        bus: l.f("No buses in the %@ after you leave", d),
                        ferry: l.f("No ferries in the %@ after you leave", d)))
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .padding(.top, layout.stacked ? 0 : 5 * TextScale.factor)
        } else {
            let perRow = layout.perRow(room)
            let shown = Array(trains.prefix(perRow >= 3 ? min(perRow, PlannerChipLayout.most) : 3))
            let rows = stride(from: 0, to: shown.count, by: perRow).map { Array(shown[$0 ..< min($0 + perRow, shown.count)]) }
            // Where each goes: on trains and ferries, or when one line goes to different places in this direction
            let destinations = transit.isTrain || transit.isFerry || goesToDifferentPlaces(shown)
            // A third line in every block of the row when any has one, so they're all as tall
            let third = destinations || shown.contains { $0.evaluation.arrival.isExpress != nil }
            // The block that shows its hover text as if the mouse were on it, the first or the last of the first row
            let sampleID = sample.flatMap { $0 == .first ? rows.first?.first?.id : rows.first?.last?.id }
            VStack(alignment: .leading, spacing: PlannerChipLayout.spacing) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(spacing: PlannerChipLayout.spacing) {
                        ForEach(rows[i]) { train in
                            chip(train, destination: destinations, third: third, sample: train.id == sampleID)
                        }
                    }
                }
            }
        }
    }

    /// Where a train goes, the terminal's name (as the station signs write it)
    private func place(_ train: BoardTrain) -> String {
        if let terminal = train.direction.terminal, !terminal.isEmpty { return terminal }
        return l.direction(train.direction)
    }

    private func goesToDifferentPlaces(_ trains: [BoardTrain]) -> Bool {
        var seen: [String: String] = [:]
        for train in trains {
            let to = place(train)
            if let before = seen[train.route], before != to { return true }
            seen[train.route] = to
        }
        return false
    }

    private func chip(_ train: BoardTrain, destination: Bool, third: Bool, sample: Bool) -> some View {
        let e = train.evaluation
        let second: String
        switch e.verdict {
        case .canTry: second = l.leaveBy(e) ?? l.verdict(.canTry)
        case .tight: second = l.toSpare(e.slackSeconds)
        case .takeNext, .insufficientInfo: second = l.verdict(e.verdict)
        }
        let mark = station.routes.count > 1
        let help = hoverText(train)
        let time = l.arrivalTime(e)
        // Read out as one: the line (at stations with several), the time, the second line, then the hover text
        var spoken = [time, second, help.replacingOccurrences(of: "\n", with: ", ")]
        if mark { spoken.insert(FerryFeed.spokenRouteName(train.route), at: 0) }
        return PlannerChip(route: mark ? train.route : nil, time: time, verdict: e.verdict, second: second,
                           timetable: live && e.arrival.isTimetableTime,
                           service: e.arrival.isExpress.map { (express: $0, bus: e.arrival.busService) },
                           destination: destination ? place(train) : nil, thirdLine: third, width: layout.chipWidth > 0 ? layout.chipWidth : nil,
                           l: l)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken.joined(separator: ", "))
            // The hover text at once, below the block: the system's tooltip comes only after the mouse has stood still for a while
            .modifier(PlannerTipSource(hover: hover, id: station.id + "|" + train.id, text: help, sample: sample))
    }

    /// Two lines: where it goes (and from which station of the group, if not the one named; when leaving within 30 minutes, how soon
    /// it comes), then the whole verdict with its notes (delays, data out of date, a timetable time among live ones)
    private func hoverText(_ train: BoardTrain) -> String {
        let e = train.evaluation
        var parts = [l.terminal(train.direction) ?? l.direction(train.direction)]
        if train.station.name != station.name { parts.insert(train.station.name, at: 0) }
        if live, let time = e.arrival.arrivalTime {
            parts.append(l.countdown(time.timeIntervalSince(now.addingTimeInterval(ClockSkew.current))))
        }
        let first = l.dotted(parts)
        let notes = e.notes.filter { note in
            switch note {
            // The walk's own hover text and the header already say these
            case .walkEstimated, .acrossWater, .mockData: return false
            case .scheduledOnly: return live
            case .missingPrediction, .staleRealtime, .delayed: return true
            }
        }
        let second = ([l.catchJudgement(e, recommended: train.recommended)] + notes.map(l.note).sorted()).joined(separator: " · ")
        return first + "\n" + second
    }
}

/// One departure in Plan a Trip, a small block: the time (crossed out when too soon; after the route's mark at stations with several
/// lines), then a line in the verdict's color and icon: when to leave by to still have "can try", the time to spare when tight, or
/// "Too soon"; and, where it helps, a third line with the service (Express, Local...) and where it goes. All are as wide (`width`)
struct PlannerChip: View {
    var route: String?
    var time: String
    var verdict: CatchVerdict
    var second: String
    /// A timetable time among live ones: a small calendar after the time
    var timetable: Bool
    var service: (express: Bool, bus: BusService?)?
    var destination: String?
    /// Keep the third line, empty if need be, so the blocks of a row are as tall
    var thirdLine: Bool
    var width: CGFloat?
    var l: UIText

    static let cornerRadius: CGFloat = 7

    var body: some View {
        let tooSoon = verdict == .takeNext
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if let route {
                    RouteBadge(route: route, size: 13)
                }
                Text(time)
                    .font(.scaled(.body).weight(tooSoon ? .regular : .semibold).monospacedDigit())
                    .strikethrough(tooSoon)
                    .foregroundStyle(tooSoon ? Color.secondary : Color.primary)
                    .lineLimit(1)
                if timetable {
                    Image(systemName: "calendar")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            verdict.line(second)
                .font(.scaled(.subheadline).weight(.medium).monospacedDigit())
                .foregroundStyle(verdict.color)
                .lineLimit(1)
            if thirdLine {
                HStack(spacing: 4) {
                    if let service {
                        ServiceTag(express: service.express, bus: service.bus, l: l)
                    }
                    Text(destination ?? " ")
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 5)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Self.cornerRadius).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .contrastBorder(cornerRadius: Self.cornerRadius)
    }
}

/// A station card's name, to screen readers a button that selects the station when the card can be selected (a click on the card does
/// the same); a plain name otherwise
private struct SelectsStation: ViewModifier {
    var select: (() -> Void)?

    func body(content: Content) -> some View {
        if let select {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { select() }
        } else {
            content
        }
    }
}
