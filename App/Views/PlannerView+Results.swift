import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

extension PlannerView {
    // MARK: Results

    /// Before a place is chosen, a page that says what to do; then the results, scrolling. The countdowns in the blocks' hover text
    /// follow the clock (each minute)
    @ViewBuilder
    func resultsArea(_ l: UIText) -> some View {
        if planner.place == nil {
            emptyPage(l)
        } else {
            TimelineView(.periodic(from: Timetable.minuteStart(Date()), by: 60)) { context in
                ScrollViewReader { scroller in
                    ScrollView {
                        results(l, now: BoardClock.now(context.date))
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 16)
                    }
                    // A station selected on the map: its card comes into view
                    .onChange(of: mapSelections) { _, _ in
                        guard let id = selectedStation else { return }
                        withAnimation(Motion.ease(0.3)) { scroller.scrollTo(id) }
                    }
                }
            }
        }
    }

    /// No place yet: an icon, what to do, and that the main screen doesn't change
    private func emptyPage(_ l: UIText) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 34 * TextScale.factor))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(l.pick(transit.system, train: l.t("Choose a place to see nearby trains."), bus: l.t("Choose a place to see nearby buses."),
                        ferry: l.t("Choose a place to see nearby ferries.")))
                .font(.scaled(.title3).weight(.semibold))
            // The second sentence depends on which place the main view is using (it never says "current location" while "A place I choose" is selected)
            Text(l.pick(transit.system,
                        train: l.t("Check trains near another place, for a time you choose."),
                        bus: l.t("Check buses near another place, for a time you choose."),
                        ferry: l.t("Check ferries near another place, for a time you choose."))
                 + (mainScreenText(l).isEmpty ? "" : " " + mainScreenText(l)))
                .font(.scaled(.callout))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// When and how the times were found, notes, then every station within the walk (nearest first), a legend and the disclaimer.
    /// While computing, only the loading line: the stations of a new search have no times yet, and would all say there are none
    private func results(_ l: UIText, now: Date) -> some View {
        let board = planner.board(transit: transit)
        let computing = planner.shownStatus == .loading
        let layout = board.map { chipLayout($0) }
        return LazyVStack(alignment: .leading, spacing: 10) {
            if let leave = planner.computedLeaveAt {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.f("Leaving %@", l.dayAndTimeFromToday(leave)))
                        .font(.scaled(.headline))
                    // The place's times read differently on this Mac's clock: say whose time they are
                    if let note = l.timeZoneNote(at: leave, areaName: planner.placeArea.map { l.metroAreaName($0) }) {
                        TimeZoneNoteText(note: note)
                    }
                    dataNote(l)
                }
            }
            if transit.isDemo {
                // Made-up times, and places in Manhattan only, as the demo page says
                DemoBanner(text: l.t("Demo data only. These times are made up, and this demo knows only places in Manhattan."))
            }
            switch planner.shownStatus {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(l.pick(transit.system, train: l.t("Loading train times…"), bus: l.t("Loading bus times…"), ferry: l.t("Loading ferry times…")))
                }
                .foregroundStyle(.secondary)
            case .failed(let note):
                // Put into words now, in the language shown now (see PlannerModel.Note)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                    Text(note.words(l))
                }
                .foregroundStyle(Color.noticeOrange)
                // What would put it right, here rather than only elsewhere in the app: Start on standby, Refresh when asking
                // online failed. Under the sentence, in line with its words
                if let action = note.action {
                    Group {
                        switch action {
                        case .start:
                            Button {
                                transit.start()
                            } label: {
                                Label(l.t("Start"), systemImage: "play.fill")
                            }
                        case .refresh:
                            Button {
                                planner.update(transit: transit)
                            } label: {
                                Label(l.t("Refresh"), systemImage: "arrow.clockwise")
                            }
                        case .settings(let target):
                            Button(l.t("Settings…")) {
                                SettingsJump.to(target)
                                NSApp.activate()
                                openSettings()
                            }
                        }
                    }
                    .appButtonStyle(.bordered)
                    .fixedSize()
                    .padding(.leading, 22)
                }
            case .idle, .ready:
                EmptyView()
            }
            if let board, let layout, !computing {
                if board.stations.isEmpty && planner.shownStatus == .ready {
                    Text(l.noStationWithinWalk(transit.system, walkSeconds: planner.walkSeconds(transit)))
                        .foregroundStyle(.secondary)
                }
                // tipSample: a block of the first station with times shows its hover text as if the mouse were on it
                let sampleStation = tipSample == nil ? nil : board.stations.first(where: { $0.noTimes == nil })?.id
                let selectable = showsMapColumn
                ForEach(board.stations) { station in
                    let isSelected = selectable && selectedStation == station.id
                    PlannerStationCard(station: station, l: l, window: planner.windowSeconds, layout: layout,
                                       live: planner.dataKind == .realtime, now: now, hover: hover,
                                       tipSample: station.id == sampleStation ? tipSample : nil,
                                       select: selectable ? selecting(station.id) : nil)
                        // With the map column: a click selects the station, marked here and on the map
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture {
                            if selectable { withAnimation(Motion.ease(0.2)) { selectedStation = station.id } }
                        }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .id(station.id)
                }
                if board.stations.contains(where: { $0.noTimes == nil }) {
                    legend(l)
                }
            }
            Text(l.pick(transit.system, train: l.t("Estimates only. Times may not show the latest service changes, and catching a train is never guaranteed."),
                        bus: l.t("Estimates only. Times may not show the latest service changes, and catching a bus is never guaranteed."),
                        ferry: l.t("Estimates only. Times may not show the latest service changes, and catching a ferry is never guaranteed.")))
                .font(.scaled(.caption)).foregroundStyle(.secondary)
        }
        // As wide as the scroll view gives, never wider, like the controls: the blocks are laid out for that width
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if changed(resultsWidth, w) { resultsWidth = w }
        }
        // The widest block, hidden, to measure (all blocks are as wide)
        .background(alignment: .topLeading) {
            if let board {
                chipSample(l, board: board)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                        if changed(chipWidth, w) { chipWidth = w }
                    }
            }
        }
        .animation(Motion.ease(0.2), value: planner.shownStatus)
        .animation(Motion.ease(0.2), value: planner.place)
    }

    /// Where the times come from: live data, or the timetables (said clearly when they're not live)
    @ViewBuilder
    private func dataNote(_ l: UIText) -> some View {
        switch planner.dataKind {
        case .realtime:
            VStack(alignment: .leading, spacing: 2) {
                // Only the operators of the departures found, wherever the place is; nothing before there are any
                let live = transit.liveDataSummary(of: planner.arrivals)
                if !live.isEmpty {
                    noteLine(live, icon: "dot.radiowaves.left.and.right")
                }
                // How old the live times shown are (fetched again on the refresh interval while started)
                if let at = planner.computedAt {
                    noteLine(l.f("Updated %@", l.time(at)), icon: "clock")
                }
            }
        case .scheduled(let until, let mta):
            noteLine(transit.isFerry ? l.t("No live data for this time. Times are from the ferry timetables.")
                     : transit.isTrain ? l.t("No live data for this time. Times are from the train timetables.")
                     : transit.isBus ? l.t("No live data for this time. Times are from the bus timetables.")
                     // No MTA station near the place: the other operators' subway and light rail timetables
                     : !mta ? l.t("No live data for this time. Times are from the subway timetables.")
                     : until.map { l.f("No live data for this time. Times are from the MTA timetable (valid until %@).", l.day($0, timeZone: Timetable.timeZone)) }
                     ?? l.t("No live data for this time. Times are from the MTA timetable."),
                     icon: "calendar")
        case nil:
            EmptyView()
        }
    }

    /// A small gray line with its icon on the first line of text
    private func noteLine(_ text: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(text)
        }
        .font(.scaled(.caption))
        .foregroundStyle(.secondary)
    }

    /// Selects a station's card, as a click on it does (with the map column)
    private func selecting(_ id: String) -> () -> Void {
        { withAnimation(Motion.ease(0.2)) { selectedStation = id } }
    }

    /// What the colors and icons of the blocks mean: on one line, or on more when they don't fit (a narrow window, the larger text)
    private func legend(_ l: UIText) -> some View {
        FlowLayout(spacing: 14, lineSpacing: 4, fitsWidth: true) {
            ForEach([CatchVerdict.canTry, .tight, .takeNext, .insufficientInfo], id: \.self) { verdict in
                verdict.line(l.verdict(verdict))
                    .foregroundStyle(verdict.color)
            }
        }
        .font(.scaled(.subheadline).weight(.medium))
        .padding(.top, 2)
    }

    /// The blocks' width and where the direction names go, for all cards alike: beside the blocks when the fullest direction's blocks
    /// (up to 4) fit next to them in every card, otherwise above the blocks in every card, so the window looks the same throughout
    private func chipLayout(_ board: NearbyBoard) -> PlannerChipLayout {
        let card = max(0, resultsWidth - 2 * PlannerStationCard.padding)
        let label = (150 * TextScale.factor).rounded()
        var layout = PlannerChipLayout(chipWidth: chipWidth, labelWidth: label, sideRoom: card - label - PlannerStationCard.labelGap,
                                       stackedRoom: card, stacked: false)
        let most = min(4, board.stations.map { max($0.north.trains.count, $0.south.trains.count) }.max() ?? 0)
        layout.stacked = most > 0 && layout.perRow(layout.sideRoom) < most
        return layout
    }

    /// The widest a block can be, drawn hidden to be measured: a route mark (the longest of the stations that show them), a morning
    /// and an evening time with the timetable mark, and each kind of second line
    private func chipSample(_ l: UIText, board: NearbyBoard) -> some View {
        let calendar = Timetable.calendar(in: l.timeZone)
        let morning = calendar.date(bySettingHour: 10, minute: 58, second: 0, of: Date()) ?? Date()
        let evening = calendar.date(bySettingHour: 22, minute: 58, second: 0, of: Date()) ?? Date()
        let route = board.stations.filter { $0.routes.count > 1 }.flatMap(\.routes)
            .max { RouteBadge.label($0).count < RouteBadge.label($1).count }
        let lines: [(CatchVerdict, String)] = [
            (.canTry, l.leaveBy(at: morning)), (.canTry, l.leaveBy(at: evening)),
            (.tight, l.toSpare(19 * 60)), (.tight, l.toSpare(30)),
            (.takeNext, l.verdict(.takeNext)), (.insufficientInfo, l.verdict(.insufficientInfo)),
        ]
        return ZStack(alignment: .topLeading) {
            ForEach(lines.indices, id: \.self) { i in
                PlannerChip(route: route, time: l.time(i % 2 == 0 ? morning : evening), verdict: lines[i].0, second: lines[i].1,
                            timetable: true, service: nil, destination: nil, thirdLine: false, width: nil, l: l)
            }
        }
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
    }
}
