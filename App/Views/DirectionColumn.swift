import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// Both directions side by side: the natural heights of the titles ("title") and of the rows ("row0", "row1", ...) of both columns,
/// the taller of the two for each (also the menu bar panel's two directions)
struct PairHeights: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { max($0, $1) }
    }

    /// Store only real changes: storing redraws the columns, which report their heights again
    static func differs(_ a: [String: CGFloat], _ b: [String: CGFloat]) -> Bool {
        a.count != b.count || a.contains { key, height in abs((b[key] ?? -1) - height) > 0.5 }
    }
}

/// Side by side, the title or row N of one direction is as tall as the title or row N of the other, so the two columns line up
/// (the extra room goes below the shorter one). The natural height is measured before the taller frame, so a row that gets
/// shorter again (its details closed) shrinks back.
struct PairedHeight: ViewModifier {
    var key: String
    var heights: [String: CGFloat]?

    func body(content: Content) -> some View {
        if let heights {
            content
                .background(GeometryReader { g in
                    Color.clear.preference(key: PairHeights.self, value: [key: g.size.height])
                })
                .frame(minHeight: heights[key], alignment: .topLeading)
        } else {
            content
        }
    }
}

/// One direction drawn in full: a title (sign direction name) with trips below sorted by arrival time. Used with VoiceOver on;
/// otherwise the station page draws only the rows in view (BoardRows.swift, which also has the title and the note for no trips).
struct DirectionColumn: View {
    var direction: BoardDirection
    var station: BoardStation
    var l: UIText
    /// Side by side with the other direction: the heights to line up with (nil when it stands alone or the two are stacked)
    var pairHeights: [String: CGFloat]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DirectionTitle(direction: direction, station: station, l: l)
                .modifier(PairedHeight(key: "title", heights: pairHeights))
            VStack(spacing: 0) {
                if direction.trains.isEmpty {
                    DirectionEmptyNote(direction: direction, station: station)
                }
                let first = direction.firstCatchable?.id
                ForEach(Array(direction.trains.enumerated()), id: \.element.id) { index, train in
                    if index > 0 { Divider() }
                    BoardTrainRow(train: train, showStation: train.station.name != station.name, l: l,
                                  timetableTag: !Self.allTimetable(direction), reminders: .shared)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .modifier(PairedHeight(key: "row\(index)", heights: pairHeights))
                        .modifier(FirstCatchableMark(verdict: train.id == first ? train.verdict : nil))
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // One group per direction: screen readers read one direction's departures, then the other's (side by side, they took them
        // row by row across both)
        .accessibilityElement(children: .contain)
    }

    /// All of this direction's times come from the timetable (and there is at least one)
    static func allTimetable(_ direction: BoardDirection) -> Bool {
        !direction.trains.isEmpty && direction.trains.allSatisfy(\.evaluation.arrival.isTimetableTime)
    }
}

/// The train whose details opened last (BoardTrainRow)
@MainActor private enum LastOpenedDetails {
    static var train: String?
}

/// One train: the arrival time is most prominent, how soon it comes right after it; below it where it goes, then in the verdict's
/// color the walk time and whether you can catch it; when it has a leave-by reminder, when that comes. Clicking it (or Space when
/// it has the keyboard) shows the details below it (TrainDetailsPopover), where the reminder is set and cancelled.
struct BoardTrainRow: View {
    var train: BoardTrain
    /// When the complex has several stations, show which one this train stops at.
    var showStation: Bool
    var l: UIText
    /// Mark a timetable time on the row; false when the direction's heading says it for all of them (DirectionColumn)
    var timetableTag = true
    /// The leave-by reminders: they change only when one is set, moved or cancelled (the row doesn't watch the main model)
    @ObservedObject var reminders: LeaveReminderCenter
    @State private var showsDetails = false
    /// The screen reader's cursor on this row: put back here when its details close (it went back to the station's name)
    @AccessibilityFocusState private var readerOnRow: Bool

    var body: some View {
        let e = train.evaluation
        let reminder = reminders.reminder(for: train.id)
        HStack(alignment: .top, spacing: 10) {
            RouteBadge(route: train.route, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                // How soon comes right after the time, in body color; where both don't fit (small window, large text), below it
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        time(e)
                        countdown(e).font(.scaled(.body))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        time(e)
                        countdown(e).font(.scaled(.callout))
                    }
                }
                // The tags, then where it goes on up to three lines (a station's name and the terminal's together can be long,
                // most of all with larger text in a column beside the other direction); the tags line up with its first line
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let express = e.arrival.isExpress {
                        ServiceTag(express: express, bus: e.arrival.busService, l: l)
                    }
                    // Timetable times, including trips in the realtime data with no train assigned yet
                    if e.arrival.isTimetableTime, timetableTag {
                        TimetableTag(l: l)
                    }
                    Text(destination)
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The walk time and whether you can catch it (if not, which one to take), a size larger than the line above; on as
                // many lines as it needs, so the time of the next one you can catch is never cut off (word joiners keep a time whole)
                e.verdict.line(l.trainLine(train))
                    .font(.scaled(.subheadline).weight(.medium))
                    .foregroundStyle(e.verdict.color)
                    .fixedSize(horizontal: false, vertical: true)
                // Its leave-by reminder, when one is set: when the notification comes
                if let reminder {
                    Label(l.reminderAt(reminder), systemImage: "bell.fill")
                        .font(.scaled(.caption).weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { showsDetails.toggle() }
        .focusable()
        // Space or Return opens its details, as a button does
        .onKeyPress(.space) {
            showsDetails.toggle()
            return .handled
        }
        .onKeyPress(.return) {
            showsDetails.toggle()
            return .handled
        }
        .modifier(TrainDetailsPopover(train: train, l: l, isPresented: $showsDetails, reminders: reminders))
        // For trips you can't catch, only gray out the time, not the whole row: fading would make the route badge and express/local label colors differ from other rows
        // Read as one sentence of what the row shows (AppText.spokenDeparture), not piece by piece with the verdict's icon by its name
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(l.spokenDeparture(train, station: showStation ? train.station.name : nil)))
        // Its reminder is said after the sentence (nothing when it has none)
        .accessibilityValue(Text(reminder.map { l.reminderAt($0, spoken: true) } ?? ""))
        // A button that opens the details (Remind Me and Directions are only there): screen readers press it with their usual
        // keys, as the sidebar's station rows
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showsDetails = true }
        .accessibilityAction(named: Text(l.t("Show details"))) { showsDetails = true }
        .accessibilityFocused($readerOnRow)
        // Once the details have closed (Escape, or a click outside), after the popover's own move of the cursor; not when another
        // train's details have opened since (a click on its row closed these), or these again
        .onChange(of: showsDetails) { _, shown in
            if shown {
                LastOpenedDetails.train = train.id
                return
            }
            let id = train.id
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !showsDetails, LastOpenedDetails.train == id else { return }
                readerOnRow = true
            }
        }
        .help(l.t("Click for details"))
    }

    private func time(_ e: CatchEvaluation) -> some View {
        Text(l.arrivalTime(e))
            .font(.scaled(.title2).bold().monospacedDigit())
            .lineLimit(1)
            .foregroundStyle(e.verdict == .takeNext ? Color.secondary : Color.primary)
    }

    private func countdown(_ e: CatchEvaluation) -> some View {
        Text(l.countdown(e.secondsUntilTrain))
            .monospacedDigit()
            .lineLimit(1)
    }

    private var destination: String {
        let to = l.terminal(train.direction) ?? l.direction(train.direction)
        return showStation ? l.dotted([train.station.name, to]) : to
    }
}
