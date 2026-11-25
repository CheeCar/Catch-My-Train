import CatchText
import SwiftUI
import TransitCore

// The station page's departures drawn row by row, only the ones in view (a lazy stack): a busy station lists up to 60 a
// direction, and laying all of them out again at every step of a window resize made resizing lag. Side by side, the two
// directions share their rows (the first departures of both, the second ones and so on), so each pair is as tall as its taller
// one without measuring. With VoiceOver on, the page keeps its columns drawn in full (StationDetail, DirectionColumn): VoiceOver
// then reads every departure of one direction before the other's, also the ones out of view.

/// A direction's heading: its arrow, its title on up to three lines (a click lists every terminal when the title names only the
/// first ones), and "Timetable" when all its times are timetable times
struct DirectionTitle: View {
    @EnvironmentObject var transit: TransitModel
    var direction: BoardDirection
    var station: BoardStation
    var l: UIText
    /// The list of every terminal is open (a title that names only the first ones)
    @State private var showsTerminals = false

    var body: some View {
        // The arrow lines up with the first line of the title, not with the middle of a title of two or three lines
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: direction.code == "S" ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Past two terminals the title names the first two and "and N more": a click lists them all (the blue circled
            // chevron after the last word, a no-break space before it so it never sits alone on a line, says so). At most 3
            // lines (a sign direction name and terminals together), hover shows the full title
            let title = transit.directionTitle(direction, in: station)
            let terminals = transit.directionTerminals(direction, in: station)
            if terminals.count > AppText.shownPlaces {
                Button {
                    showsTerminals.toggle()
                } label: {
                    (Text(title) + Text("\u{00A0}") + Text(Image(systemName: "chevron.down.circle")).foregroundStyle(Color.accentColor))
                        .font(.scaled(.headline))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help(title)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(l.t("All destinations")))
                .accessibilityAddTraits(.isHeader)
                .popover(isPresented: $showsTerminals, arrowEdge: .bottom) {
                    DirectionTerminalList(terminals: terminals, l: l)
                        .environment(\.layoutDirection, transit.layoutDirection)
                }
            } else {
                Text(title)
                    .font(.scaled(.headline))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(title)
                    // A heading: screen readers can jump from one direction to the other
                    .accessibilityAddTraits(.isHeader)
            }
            // Every time in this direction is a timetable time: said once here instead of on each row
            if DirectionColumn.allTimetable(direction) {
                TimetableTag(l: l)
            }
        }
    }
}

/// Every terminal of a direction whose title names only the first ones ("and N more"), one per line
struct DirectionTerminalList: View {
    let terminals: [String]
    let l: UIText

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l.t("All destinations"))
                .font(.scaled(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(terminals, id: \.self) { terminal in
                Text(l.f("To %@", terminal))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.scaled(.body))
        .padding(12)
        .frame(minWidth: 200, maxWidth: 320, alignment: .leading)
    }
}

/// In place of a direction's departures when it has none: why (still loading, the download failed or the data is out of date, or
/// really nothing runs), or the offer to read a saved key again
struct DirectionEmptyNote: View {
    @EnvironmentObject var transit: TransitModel
    var direction: BoardDirection
    var station: BoardStation

    var body: some View {
        Group {
            if transit.busKeyUnreadable, transit.needsBusKey(at: station) {
                // The key may well still be saved (see TransitModel.busKeyUnreadable): offer to read it again
                KeychainRetryLine(credential: .busTime)
            } else {
                Text(emptyText).foregroundStyle(.secondary)
            }
        }
        .font(.scaled(.callout))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var emptyText: String {
        let l = transit.l10n
        if transit.needsBusKey(at: station) { return l.t("Add a key to see live bus times") }
        if transit.isRefreshing && transit.arrivals.isEmpty {
            return l.pick(transit.system, train: l.t("Loading train times…"), bus: l.t("Loading bus times…"), ferry: l.t("Loading ferry times…"))
        }
        // Say this only when nothing at all was downloaded or the data is stale; minor notes like "a few trains have no realtime data" don't count
        // (rate limits and connection notices only when they're about this station, like StatusBanner)
        if !transit.rateLimits(at: station).isEmpty { return l.t("Live times are paused for a while because of too many requests.") }
        let reach = transit.reachNotices(at: station)
        if !reach.isEmpty {
            return reach.allSatisfy(\.problem.isNetwork)
                ? l.t("A data server can't be reached, so live times didn't load. See the note above.")
                : l.t("A data source has a problem, so live times didn't load. See the note above.")
        }
        if transit.isStale(now: BoardClock.now()) || (transit.notice(for: station) != nil && transit.arrivals.isEmpty) {
            // The network turned off in Settings: nothing could download, which isn't a failure
            return transit.networkOffNote ?? l.t("The data is out of date or didn't load.")
        }
        return l.noArrivals(transit.system, within: transit.effectiveSettings.sanitized().arrivalWindowSeconds, next: direction.next)
    }
}

/// One row of a direction's card: the departure at `index` under a thin line (none above the first), or, for a direction with no
/// departures, the note that says why. Behind it its piece of the card (CardPiece). A departure fills the height it is given, so
/// beside a taller one of the other direction the card and the first-catchable mark go on to the pair's bottom; the note keeps
/// its own height
struct DirectionCell: View {
    var direction: BoardDirection
    var station: BoardStation
    var index: Int
    var l: UIText

    var body: some View {
        let trains = direction.trains
        VStack(spacing: 0) {
            if trains.isEmpty {
                DirectionEmptyNote(direction: direction, station: station)
            } else if index < trains.count {
                let train = trains[index]
                if index > 0 { Divider() }
                BoardTrainRow(train: train, showStation: train.station.name != station.name, l: l,
                              timetableTag: !DirectionColumn.allTimetable(direction), reminders: .shared)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .modifier(FirstCatchableMark(verdict: train.id == direction.firstCatchable?.id ? train.verdict : nil))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: trains.isEmpty ? nil : .infinity, alignment: .topLeading)
        .modifier(CardPiece(index: index, count: max(trains.count, 1)))
    }
}

/// The card behind a direction's departures, cut into one piece per row so that each row brings its own: the first has the
/// card's top corners and the last its bottom corners
private struct CardPiece: ViewModifier {
    var index: Int
    var count: Int

    func body(content: Content) -> some View {
        let top: CGFloat = index == 0 ? 10 : 0
        let bottom: CGFloat = index == count - 1 ? 10 : 0
        content.background(
            UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                                   topTrailingRadius: top)
                .fill(.background.secondary))
    }
}

/// One direction as rows of the lazy stack it is put in: its heading, then a row per departure
struct DirectionRows: View {
    var direction: BoardDirection
    var station: BoardStation
    var l: UIText

    var body: some View {
        DirectionTitle(direction: direction, station: station, l: l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 8)
        if direction.trains.isEmpty {
            DirectionCell(direction: direction, station: station, index: 0, l: l)
        } else {
            ForEach(Array(direction.trains.enumerated()), id: \.element.id) { index, _ in
                DirectionCell(direction: direction, station: station, index: index, l: l)
            }
        }
    }
}

/// Both directions side by side as rows of the lazy stack they are put in: the two headings, then the first departures of both,
/// the second ones and so on. Each pair is as tall as its taller one (fixedSize: the pair takes its own height, and both cells
/// fill it), so the two columns line up. Assistive tools go through one direction's rows, then the other's (the sort priorities;
/// VoiceOver gets the columns drawn in full instead, see StationDetail)
struct PairedDirectionRows: View {
    var north: BoardDirection
    var south: BoardDirection
    var station: BoardStation
    var l: UIText

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            DirectionTitle(direction: north, station: station, l: l)
                .modifier(ColumnWidth())
                .accessibilitySortPriority(4)
            DirectionTitle(direction: south, station: station, l: l)
                .modifier(ColumnWidth())
                .accessibilitySortPriority(2)
        }
        .padding(.bottom, 8)
        ForEach(0..<max(Self.rows(north), Self.rows(south)), id: \.self) { index in
            HStack(alignment: .top, spacing: 14) {
                cell(north, index).accessibilitySortPriority(3)
                cell(south, index).accessibilitySortPriority(1)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A direction's rows: one per departure, or the one that says there are none
    private static func rows(_ direction: BoardDirection) -> Int { max(direction.trains.count, 1) }

    @ViewBuilder private func cell(_ direction: BoardDirection, _ index: Int) -> some View {
        if index < Self.rows(direction) {
            DirectionCell(direction: direction, station: station, index: index, l: l)
                // A row's own state (its details open) stays with its departure, not with its place in the list
                .id(direction.trains.isEmpty ? "none" : direction.trains[index].id)
                .modifier(ColumnWidth())
        } else {
            // Past this direction's last departure: nothing, as wide as its column
            Color.clear
                .frame(height: 0)
                .modifier(ColumnWidth())
                .accessibilityHidden(true)
        }
    }

    /// Each direction's column: at least StationDetail.minColumnWidth, the two as wide as each other
    private struct ColumnWidth: ViewModifier {
        func body(content: Content) -> some View {
            content.frame(minWidth: StationDetail.minColumnWidth, idealWidth: 330, maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
