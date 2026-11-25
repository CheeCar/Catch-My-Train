import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

// MARK: - Right side: trips for one station

struct StationDetail: View {
    @EnvironmentObject var transit: TransitModel
    var stationID: String
    var now: Date
    @Binding var directionMode: DirectionMode
    /// Show only these routes (empty means all). Cleared when the station changes.
    @State private var routeFilter: Set<String> = []
    /// The trips area has room for two columns: both directions go side by side (instead of ViewThatFits laying out twice on
    /// every redraw). Only this yes or no is stored, not the width: a window being resized then redraws the page once at the
    /// width where the answer changes, not at every step
    @State private var sideBySide = true
    /// Side by side with VoiceOver on: the natural height of each title and row of both columns, the taller of the two for each (PairHeights)
    @State private var pairHeights: [String: CGFloat] = [:]
    /// VoiceOver is on: the columns are drawn in full, so it reads every departure of one direction, then the other's. Without
    /// it only the rows in view are drawn (BoardRows.swift)
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// Minimum width of each column when the two directions are side by side
    static let minColumnWidth: CGFloat = 270

    var body: some View {
        let l = transit.l10n
        let all = transit.board(at: now)
        let board = routeFilter.isEmpty ? all : transit.board(at: now, routeFilter: routeFilter)
        if let station = all.station(id: stationID), let place = station.noTimes {
            // An operator that publishes no times the app can use: the header as usual, then why there are none and a button
            // to its website, in place of the directions (no route filter, direction switch or footer)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    StationHeader(station: station, memberRoutes: transit.stationRoutes, l: l)
                    NoTimesNotice(place: place, l: l)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } else if let station = all.station(id: stationID), let shown = board.station(id: stationID) {
            let hasNorth = transit.hasDirection(station.north, in: station)
            let hasSouth = transit.hasDirection(station.south, in: station)
            // A bus stop on only one side of the street has only one direction: show just that column
            let direction = !hasSouth ? DirectionMode.north : !hasNorth ? DirectionMode.south : directionMode
            VStack(alignment: .leading, spacing: 0) {
                // The top part is fixed (like the MTA app): station, notices, route filter, direction switch.
                VStack(alignment: .leading, spacing: 12) {
                    StationHeader(station: station, memberRoutes: transit.stationRoutes, l: l)
                    BusKeyPrompt(station: station)
                    StatusBanner(now: now, station: station)
                    ScheduleOnlyNotice(station: station)
                    if transit.isDemo {
                        DemoBanner()
                    }
                    if station.routes.count > 1 {
                        RouteFilterBar(routes: station.routes, filter: $routeFilter, l: l)
                    }
                    if hasNorth && hasSouth {
                        DirectionSwitcher(mode: $directionMode,
                                          northTitle: transit.directionTitle(station.north, in: station),
                                          southTitle: transit.directionTitle(station.south, in: station),
                                          l: l)
                    }
                }
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
                // Its full height first, the list below the rest: a notice keeps all its lines even in a small window with larger text,
                // and the list gives way (it scrolls). Not fixedSize, which makes the window's minimum height far too tall (see BusKeyPrompt)
                .layoutPriority(1)

                Divider()

                ScrollView {
                    Group {
                        // Its own cancelled trips, of the lines picked in the filter
                        let cancelled = board.cancelledCount(at: stationID)
                        if voiceOver {
                            fullColumns(direction, shown: shown, station: station, all: all, cancelled: cancelled, l: l)
                        } else {
                            lazyRows(direction, shown: shown, station: station, all: all, cancelled: cancelled, l: l)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // After switching direction, the trips come in from the side of the chosen segment
                    .pushIn(direction, order: direction.order)
                    // Stored only when the answer changes (see sideBySide)
                    .onGeometryChange(for: Bool.self) { $0.size.width >= Self.minColumnWidth * 2 + 14 } action: { wide in
                        if wide != sideBySide { sideBySide = wide }
                    }
                    .padding(20)
                }
                // A few trips always in view: with several notices, larger text and a small window, the top part gives way instead
                .frame(minHeight: 120)
            }
        }
    }

    /// The directions with only the rows in view drawn (the lazy stack's rows: headings, departures, the footer). When the window
    /// is wide enough the two directions are side by side, their rows in pairs; when narrow they stack, so the window doesn't
    /// overflow. Each column is at least 270 wide: side by side even with a wider sidebar or the minimum window
    private func lazyRows(_ direction: DirectionMode, shown: BoardStation, station: BoardStation, all: NearbyBoard,
                          cancelled: Int, l: UIText) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            switch direction {
            case .both:
                if sideBySide {
                    PairedDirectionRows(north: shown.north, south: shown.south, station: station, l: l)
                } else {
                    DirectionRows(direction: shown.north, station: station, l: l)
                    Color.clear.frame(height: 18).accessibilityHidden(true)
                    DirectionRows(direction: shown.south, station: station, l: l)
                }
            case .north, .south:
                // The chosen direction; when it has nothing and the other has departures, the other under it, with its
                // own title (the choice holds for every station: at this one nothing may run that way for a while)
                let chosen = direction == .north ? shown.north : shown.south
                let other = direction == .north ? shown.south : shown.north
                DirectionRows(direction: chosen, station: station, l: l)
                if direction.showsOtherDirection(chosenIsEmpty: chosen.trains.isEmpty, otherIsEmpty: other.trains.isEmpty) {
                    Color.clear.frame(height: 18).accessibilityHidden(true)
                    DirectionRows(direction: other, station: station, l: l)
                }
            }
            BoardFooter(board: all, now: now, cancelled: cancelled)
                .padding(.top, 14)
        }
        // One group: the order assistive tools go through the paired rows in (PairedDirectionRows) is set inside it
        .accessibilityElement(children: .contain)
    }

    /// The directions drawn in full, each in its own column (with VoiceOver on)
    private func fullColumns(_ direction: DirectionMode, shown: BoardStation, station: BoardStation, all: NearbyBoard,
                             cancelled: Int, l: UIText) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch direction {
            case .both:
                if sideBySide {
                    // The two columns line up: the titles are as tall as each other, and so are the first trains, the second
                    // trains and so on (PairedHeight)
                    HStack(alignment: .top, spacing: 14) {
                        DirectionColumn(direction: shown.north, station: station, l: l, pairHeights: pairHeights)
                            .frame(minWidth: Self.minColumnWidth, idealWidth: 330, maxWidth: .infinity)
                        DirectionColumn(direction: shown.south, station: station, l: l, pairHeights: pairHeights)
                            .frame(minWidth: Self.minColumnWidth, idealWidth: 330, maxWidth: .infinity)
                    }
                    .onPreferenceChange(PairHeights.self) { h in
                        if PairHeights.differs(h, pairHeights) { pairHeights = h }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        DirectionColumn(direction: shown.north, station: station, l: l)
                        DirectionColumn(direction: shown.south, station: station, l: l)
                    }
                }
            case .north, .south:
                let chosen = direction == .north ? shown.north : shown.south
                let other = direction == .north ? shown.south : shown.north
                VStack(alignment: .leading, spacing: 18) {
                    DirectionColumn(direction: chosen, station: station, l: l)
                    if direction.showsOtherDirection(chosenIsEmpty: chosen.trains.isEmpty, otherIsEmpty: other.trains.isEmpty) {
                        DirectionColumn(direction: other, station: station, l: l)
                    }
                }
            }
            BoardFooter(board: all, now: now, cancelled: cancelled)
        }
    }
}

/// Direction switch (like a segmented control): "Both directions" as wide as it needs on one line, the two direction names share the rest
/// (DirectionSegmentsLayout). A name that doesn't fit wraps onto a second line; only one that two lines can't hold is truncated at the end,
/// hover shows the full name. The three segments are as tall as the tallest, each with its arrow and name in the middle.
/// At big transfer stations, or when a direction serves several terminals, direction names can be long (e.g. "To Flushing-Main St or Mets-Willets Point · Uptown");
/// the system segmented control sizes to the full names and overflows the window, so we draw our own.
struct DirectionSwitcher: View {
    @Binding var mode: DirectionMode
    var northTitle: String
    var southTitle: String
    var l: UIText
    @Namespace private var space
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        DirectionSegmentsLayout(rightToLeft: direction == .rightToLeft, spacing: 2) {
            Group {
                segment(.both, title: l.t("Both directions"), icon: "arrow.up.arrow.down")
                segment(.north, title: northTitle, icon: "arrow.up")
                segment(.south, title: southTitle, icon: "arrow.down")
            }
            .environment(\.layoutDirection, direction)
        }
        .environment(\.layoutDirection, .leftToRight)
        // The blue slides to the chosen direction
        .segmentThumb(mode, in: space, cornerRadius: 6)
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
        .contrastBorder(cornerRadius: 8)
        // Don't wrap or truncate direction names too early in wide windows (a screen-size test showed them still truncated at 1710 wide)
        .frame(maxWidth: 1100, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l.t("Direction"))
    }

    private func segment(_ value: DirectionMode, title: String, icon: String) -> some View {
        let selected = mode == value
        // No withAnimation here: the trips come in with their own animation (StationDetail), the rest of the page doesn't move
        return Button {
            mode = value
        } label: {
            // As wide and as tall as in bold, so being selected doesn't resize a segment and push the others while the blue slides.
            // The name starts right after the arrow; the room kept for bold is after it. Each copy has its own arrow, so where the
            // bold name takes two lines and the regular one fits on one, the arrow stays beside the line shown
            ZStack(alignment: .leading) {
                arrowAndName(title, icon: icon, weight: .semibold).hidden()
                arrowAndName(title, icon: icon, weight: selected ? .semibold : .regular)
            }
            // "Both directions" on one line; a direction name wraps onto a second line, and is truncated only past that
            .lineLimit(value == .both ? 1 : 2)
            .truncationMode(.tail)
            .fixedSize(horizontal: value == .both, vertical: false)
            .font(.scaled(.callout))
            .foregroundStyle(selected ? Color.white : Color.primary)
            // Fills the width DirectionSegmentsLayout gives it ("Both directions" gets only the width it needs) and the height it
            // gives all three, so the blue fills a segment beside a taller one; the arrow and name stay in the middle
            .frame(maxWidth: value == .both ? nil : .infinity, minHeight: 26, maxHeight: .infinity)
            .padding(.horizontal, 8)
            .segmentSlot(value, in: space)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        // Screen readers: say which one is selected (on screen only color shows it)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The arrow, on the first line of the name beside it
    private func arrowAndName(_ title: String, icon: String, weight: Font.Weight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).font(.scaled(.caption).weight(.semibold))
                .accessibilityHidden(true)
            Text(title).fontWeight(weight)
        }
    }
}

/// The direction switch's segments ("Both directions", then the two directions): the first as wide as it needs. The two directions share the rest
/// equally when both names fit in half. When the longer one doesn't, it gets the width it needs and the shorter one the rest; with less room,
/// the shorter one keeps the width its full name needs and only the longer one wraps onto a second line, so no space is left empty beside a
/// wrapped name (when even the shorter doesn't fit in half, both get half). The widths change smoothly as the window is resized.
/// All three are as tall as the tallest at its width. When a name wraps, a little room is added above and below it; one line keeps its height.
/// It places them itself, from the right in right-to-left languages, so it is used in a left-to-right environment (DirectionSwitcher does that).
struct DirectionSegmentsLayout: Layout {
    var rightToLeft = false
    var spacing: CGFloat = 2
    /// Added to the height when a name is on two lines, half above and half below it (each segment's content is in its middle).
    /// Added here rather than as padding in each segment, so one line keeps its height in scripts with taller lines
    var wrappedRoom: CGFloat = 6

    /// Each segment's width within `width` (nil: as wide as each needs), from the width each needs on one line (`ideal`)
    static func widths(_ ideal: [CGFloat], in width: CGFloat?, spacing: CGFloat) -> [CGFloat] {
        guard let width, width.isFinite, ideal.count == 3 else { return ideal }
        let rest = max(0, width - ideal[0] - spacing * 2)
        let half = rest / 2
        let shorter = min(ideal[1], ideal[2]), longer = max(ideal[1], ideal[2])
        if longer <= half || shorter >= half { return [ideal[0], half, half] }
        let long = min(longer, rest - shorter)
        return ideal[1] < ideal[2] ? [ideal[0], rest - long, long] : [ideal[0], long, rest - long]
    }

    /// The switch's height from each segment's height at its width and on one line (`oneLine`): the tallest, and `room` more when
    /// one of them is taller than on one line (its name wrapped)
    static func height(_ heights: [CGFloat], oneLine: [CGFloat], room: CGFloat) -> CGFloat {
        let wrapped = zip(heights, oneLine).contains { $0 > $1 + 0.5 }
        return (heights.max() ?? 0) + (wrapped ? room : 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let w = Self.widths(ideal.map(\.width), in: proposal.width, spacing: spacing)
        let heights = zip(subviews, w).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
        return CGSize(width: w.reduce(0, +) + spacing * CGFloat(max(w.count - 1, 0)),
                      height: Self.height(heights, oneLine: ideal.map(\.height), room: wrappedRoom))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = Self.widths(subviews.map { $0.sizeThatFits(.unspecified).width }, in: bounds.width, spacing: spacing)
        var x = bounds.minX
        for i in rightToLeft ? Array(subviews.indices.reversed()) : Array(subviews.indices) {
            subviews[i].place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w[i], height: bounds.height))
            x += w[i] + spacing
        }
    }
}

/// Station name, each station in the complex, walk time.
struct StationHeader: View {
    @EnvironmentObject var transit: TransitModel
    var station: BoardStation
    /// Routes serving each station
    var memberRoutes: [String: [String]]
    var l: UIText

    var body: some View {
        let w = station.walk
        VStack(alignment: .leading, spacing: 6) {
            // Current time at the far right of the station name row (not in the title bar)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(station.name).font(.scaled(.title2).bold()).lineLimit(2)
                Spacer(minLength: 8)
                CurrentTimeLabel(font: .scaled(.title3).weight(.semibold).monospacedDigit())
            }
            TimeZoneNoteLine(font: .scaled(.callout))
            // When a complex has several stations, list them separately (same-name stations are told apart by routes). When they all
            // have the title's name (operators sharing one station, e.g. Philadelphia 30th Street), just the routes, as for one station
            if station.stations.count > 1, memberNames != [station.name] {
                // Same-name stations merge into one row (e.g. the several "Times Sq-42 St" at Times Square).
                ForEach(memberNames, id: \.self) { name in
                    HStack(spacing: 6) {
                        RouteBullets(routes: NearbyBoardBuilder.sortRoutes(
                            station.stations.filter { $0.name == name }.flatMap { memberRoutes[$0.id] ?? [] }),
                                     size: 16, limit: 10)
                        Text(name).font(.scaled(.callout))
                    }
                }
            } else if let place = station.noTimes {
                // No routes to show: the operator's box tells it apart from same-name stations (Jamaica on the subway and the LIRR)
                KindBox(text: place.agency.shortName)
                    .foregroundStyle(.secondary)
            } else {
                RouteBullets(routes: station.routes, size: 20, limit: 12)
            }
            let walkLine = HStack(spacing: 6) {
                Image(systemName: station.range == .extended ? "circle.dashed" : "circle.circle")
                    .accessibilityHidden(true)
                Image(systemName: "figure.walk")
                    .accessibilityHidden(true)
                Text(l.dotted([l.f("%@ walk", l.minutes(w.walkSeconds)), l.distance(w.routeMeters ?? w.straightLineMeters),
                               l.walkSource(w.source)]))
                    // The walk is what the choice rests on: body color, not gray like the rest
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(2)
                if station.range == .extended {
                    // A non-clickable gray badge says this station is in the extended range (same as the sidebar)
                    ExtendedRangeTag(l: l)
                        .layoutPriority(1)
                }
            }
            .font(.scaled(.callout))
            .foregroundStyle(.secondary)
            // "Directions" at the end of the walk line: the walk it opens is this one, to the nearest of the station's own
            // stations. On the next line when the two don't fit side by side
            if let directions = transit.directionsAction, let target = station.stations.first, directions.offers(target.coordinate) {
                let button = DirectionsButton(l: l, mapName: directions.mapName, small: true) {
                    directions.open(to: target.coordinate, name: station.name)
                }
                .font(.scaled(.callout))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { walkLine; button }
                    VStack(alignment: .leading, spacing: 6) { walkLine; button }
                }
            } else {
                walkLine
            }
            if station.walk.isAcrossWater {
                AcrossWaterNote(l: l)
                    .font(.scaled(.callout))
            }
        }
    }

    /// Distinct station names in the complex, ordered by walking distance.
    private var memberNames: [String] {
        station.stations.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// Footer: which routes are included, data freshness, sources, disclaimer. The range legend is above the station list on the left (RangeLegend).
struct BoardFooter: View {
    @EnvironmentObject var transit: TransitModel
    var board: NearbyBoard
    var now: Date
    /// Cancelled or skipped trips to say: a station page's own (of the lines picked above); nil, the whole board's (the empty page)
    var cancelled: Int? = nil

    var body: some View {
        let l = transit.l10n
        VStack(alignment: .leading, spacing: 4) {
            Group {
                // Timetable data that couldn't be downloaded: none of its stations is on the board to note it at (with no station, the empty state says it)
                if !board.stations.isEmpty, let note = transit.missingTimetableNote() {
                    Label(note, systemImage: "exclamationmark.triangle")
                }
                let cancelledShown = cancelled ?? board.cancelledCount
                if cancelledShown > 0 {
                    Text(l.f("Cancelled or skipping this stop: %@", l.number(Double(cancelledShown))))
                }
            }
            .foregroundStyle(Color.noticeRed)
            // The start place's metro area by name (none outside every area: the empty board says so). The operators there are in
            // the sidebar header's popover and Settings → Data source
            if let area = transit.headerArea {
                Label(l.coverageLine(transit.system, in: area), systemImage: transit.system.symbol)
            }
            // Only the selected station's operators: which have realtime data (see TransitModel.liveDataSummary), and who the
            // data is from. Neither without a selected station, nor outside every area
            let selected: BoardStation? = transit.headerArea == nil ? nil : transit.selection.station(in: board)
            let live = transit.isDemo ? "" : selected.map { transit.liveDataSummary(stationIDs: $0.stations.map(\.id), routes: $0.routes) } ?? ""
            if transit.isDemo {
                Label(l.t("Demo data only: made-up times, not from any transit operator."), systemImage: "theatermasks")
            } else if !live.isEmpty {
                Label(live, systemImage: "dot.radiowaves.left.and.right")
            }
            // When the data's time and the last refresh read the same, one line says it. When they differ, both stay:
            // the difference says the last refresh didn't bring new data
            // (with the network turned off in Settings: only the time of live data downloaded before, see BoardTimes)
            let updated = transit.shownDataTime.map { l.timeWithSeconds($0) }
            let refreshed = transit.shownRefreshTime.map { l.timeWithSeconds($0) }
            if let updated, updated == refreshed {
                Text(l.f("Updated %@", updated))
            } else if let updated {
                Text(l.f("Data updated: %@", updated))
            }
            // The day this station's operators' timetables are up to date as of (not in Demo mode, nor before they downloaded once)
            if let day = transit.timetablesUpToDate(at: transit.selection.station(in: board)) {
                Text(l.f("Timetables up to date as of %@", l.day(day, timeZone: l.macZone)))
            }
            if let refreshed, refreshed != updated {
                Text(l.f("Last refresh: %@", refreshed))
            }
            // The stations with times only: one without times always has the straight-line estimate (WalkEstimator.asksForRoute),
            // and its own page says so in its walk line
            let timedWalks = transit.walks.filter { !NoTimesStations.isNoTimes($0.key) }.values
            if !timedWalks.isEmpty {
                if timedWalks.contains(where: { $0.source == .estimated }) {
                    Text(l.t("Walk times marked “estimated” come from straight-line distance, not a walking route."))
                } else {
                    Text(l.t("Walk times use Apple Maps walking routes."))
                }
            }
            Text(l.pick(transit.system, train: l.t("Estimates only. Times may not show the latest service changes, and catching a train is never guaranteed."),
                        bus: l.t("Estimates only. Times may not show the latest service changes, and catching a bus is never guaranteed."),
                        ferry: l.t("Estimates only. Times may not show the latest service changes, and catching a ferry is never guaranteed.")))
            // Who the data shown at the selected station is from
            let credits = selected.map {
                ModeCoverage.credits(for: transit.system, operators: ModeCoverage.operatorIDs(atStations: $0.stations.map(\.id),
                                                                                               routes: $0.routes, mode: transit.system))
            } ?? []
            if !credits.isEmpty {
                Text(l.f("Data: %@. This app is not affiliated with them.", l.commaList(credits)))
            }
        }
        // The lines with an icon start at the same place
        .labelStyle(IconColumnLabelStyle())
        .font(.scaled(.caption))
        .foregroundStyle(.secondary)
    }
}
