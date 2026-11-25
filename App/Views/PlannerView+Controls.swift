import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

extension PlannerView {
    // MARK: Controls

    /// How the controls are laid out: all on one row; the place and the clock, then the time choices on a second row; or, when even
    /// those don't fit side by side (larger text, a long language, a long day like "Tomorrow at 10:10 PM"), the departure time on the
    /// second row and the range and the walk on a third
    private enum ControlRows { case one, two, three }

    /// From the room the controls are given (controlsWidth, which never grows with what's in it) and the parts' own widths (measured
    /// where they are drawn, as wide on any row): the place field at its narrowest, the map button, a divider, the departure time,
    /// the range and the walk, and the clock
    private var controlRows: ControlRows {
        guard controlsWidth > 0, leavePartWidth > 0, rangePartWidth > 0 else { return .one }
        let times = leavePartWidth + Self.controlSpacing + rangePartWidth
        if controlsWidth >= Self.fieldMin + mapButtonWidth + 1 + times + clockWidth + 5 * Self.controlSpacing { return .one }
        return controlsWidth >= times ? .two : .three
    }

    /// Place field, map button, departure time, time range, walk and the clock in one row; when the window is too narrow or the text too
    /// large, the place and the clock on the first row and the time choices below (see controlRows)
    func controls(_ l: UIText) -> some View {
        let rows = controlRows
        return VStack(alignment: .leading, spacing: Self.controlSpacing) {
            HStack(spacing: Self.controlSpacing) {
                // Demo mode too: its own places and made-up times (see PlannerModel.updateDemo)
                placeField(l)
                    .frame(minWidth: Self.fieldMin, idealWidth: Self.fieldUsual, maxWidth: rows == .one ? Self.fieldUsual : .infinity)
                    // Its suggestion list, wider than it, over the rest of the row too
                    .zIndex(1)
                mapButton(l)
                if rows == .one {
                    Divider().frame(height: 18)
                    leavePart(l)
                    rangePart(l)
                    // The room left over is before the clock (on more rows the place field takes it)
                    Spacer(minLength: 0)
                }
                CurrentTimeLabel(font: .scaled(.callout).monospacedDigit(), icon: false, text: l)
                    .foregroundStyle(.secondary)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                        if changed(clockWidth, w) { clockWidth = w }
                    }
            }
            // Above the rows below too: the suggestion list hangs from the place field over them
            .zIndex(1)
            switch rows {
            case .one:
                EmptyView()
            case .two:
                HStack(spacing: Self.controlSpacing) {
                    leavePart(l)
                    rangePart(l)
                }
            case .three:
                leavePart(l)
                rangePart(l)
            }
        }
        // As wide as the window gives, never wider: a frame with only a largest width would grow with a row too long for the window,
        // measure that, and keep everything on one row, pushing the results aside
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if changed(controlsWidth, w) { controlsWidth = w }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The ★ button: a popover with the first of the place picker's favorites and recent places, and All Places and Map (the place
    /// picker window, with all of them and its map). Only the icon: hovering says what it does, and screen readers read it too
    private func mapButton(_ l: UIText) -> some View {
        Button {
            placesOpen.toggle()
        } label: {
            Image(systemName: "star")
        }
        .appButtonStyle()
        .help(l.t("Favorite and recent places, or choose on the map."))
        .accessibilityLabel(l.t("Favorite and recent places, or choose on the map."))
        .popover(isPresented: $placesOpen, arrowEdge: .bottom) {
            // A popover doesn't take the window's language and direction by itself
            placesPopover(l)
                .environment(\.locale, transit.language.locale)
                .environment(\.layoutDirection, transit.layoutDirection)
        }
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if changed(mapButtonWidth, w) { mapButtonWidth = w }
        }
    }

    /// When to leave: a button that opens the popover
    private func leavePart(_ l: UIText) -> some View {
        HStack(spacing: Self.controlSpacing) {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(l.t("Leave at"))
            }
            // The button is named so for screen readers: they don't say it twice
            .accessibilityHidden(true)
            Button {
                choosingTime.toggle()
            } label: {
                HStack(spacing: 4) {
                    // "Today at 11:10 AM": the day in the system's own words for today and tomorrow. A time already past says
                    // Now, as that's the time used (PlannerModel.effectiveLeave): it changes with the clock, each minute
                    TimelineView(.periodic(from: Timetable.minuteStart(Date()), by: 60)) { context in
                        // The schedule's date is the minute's start: the clock itself, so a time just picked as Now says so at once
                        Text(leaveText(l, now: ClockSkew.now(BoardClock.now(max(context.date, Date())))))
                    }
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .appButtonStyle()
            .popover(isPresented: $choosingTime, arrowEdge: .bottom) {
                timePopover(l)
            }
            .accessibilityLabel(l.t("Leave at"))
            .accessibilityValue(planner.leaveAt < PlannerModel.trainTimeNow() ? l.t("Now") : l.dayAndTime(planner.leaveAt))
        }
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if changed(leavePartWidth, w) { leavePartWidth = w }
        }
    }

    /// The time on the Leave at button: the one chosen, or Now once it's past (the results are worked out from now then). The
    /// popover still shows the time chosen, so it can be changed one column at a time
    private func leaveText(_ l: UIText, now: Date) -> String {
        planner.leaveAt < now ? l.t("Now") : l.dayAndTimeFromToday(planner.leaveAt)
    }

    /// How long after leaving to look, and how far to walk
    private func rangePart(_ l: UIText) -> some View {
        HStack(spacing: Self.controlSpacing) {
            // How far after departure to look for trains (2 hours by default)
            AppMenuPicker(l.t("Time range"), selection: $planner.windowSeconds,
                          valueText: l.f("Within %@", l.duration(planner.windowSeconds))) {
                ForEach(CatchSettings.arrivalWindowChoices, id: \.self) { minutes in
                    Text(l.f("Within %@", l.duration(minutes * 60))).tag(minutes * 60)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(l.t("Show departures within this time after you leave"))
            // How far to walk: the trip planner's own (Settings stay the same); every station within it is listed
            AppMenuPicker(l.t("Search range"), selection: walkBinding,
                          valueText: l.f("%@ walk", l.minutes(walkBinding.wrappedValue * 60))) {
                ForEach(transit.settings.plannerWalkChoices(), id: \.self) { minutes in
                    Text(l.f("%@ walk", l.minutes(minutes * 60))).tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(l.t("Show stations within this walk. Settings stay the same."))
        }
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if changed(rangePartWidth, w) { rangePartWidth = w }
        }
    }

    /// The walk menu's choice: the one made here, else the longer walk in Settings
    private var walkBinding: Binding<Double> {
        .afterViewUpdate(get: { planner.walkMinutes ?? transit.settings.sanitized().extendedWalkMinutes },
                         set: { planner.walkMinutes = $0 })
    }

    /// The day on a calendar with the time beside it in columns (PlannerTimePicker), and the quick choices below: now, or in 15, 30 or
    /// 60 minutes (rounded up to 5 minutes); each of those closes the popover, a day or a time doesn't. No earlier days; a time earlier
    /// today still counts as leaving now (see PlannerModel.effectiveLeave). Picked in the place's time zone (plannerText), the same
    /// time its trains show
    private func timePopover(_ l: UIText) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PlannerTimePicker(time: Binding(get: { planner.leaveAt }, set: { planner.chooseLeaveTime($0) }), l: l)
            HStack(spacing: 6) {
                quickTime(l.t("Now")) { PlannerModel.trainTimeNow() }
                ForEach([15.0, 30, 60], id: \.self) { minutes in
                    quickTime(l.f("in %@ min", l.number(minutes))) { PlannerModel.leaveTime(in: minutes) }
                }
            }
            .appButtonStyle(.bordered)
            .fixedSize()
        }
        .padding(12)
        .font(.scaled(.body))
        .environment(\.timeZone, l.timeZone)
        // The calendar draws its own month names; Haitian Creole has no date data on macOS, so it gets French (Haiti)
        .environment(\.locale, transit.language.datePickerLocale)
        .environment(\.layoutDirection, transit.layoutDirection)
    }

    private func quickTime(_ title: String, _ time: @escaping () -> Date) -> some View {
        Button {
            planner.chooseLeaveTime(time())
            choosingTime = false
        } label: {
            Text(title)
        }
    }
}
/// The departure day and time: the calendar (no earlier days), and beside it the time in columns of cells, as tall as the calendar
/// (TimeColumns: hour, minute and, on a 12-hour clock, AM/PM, in the order and words of the language's clock times). In the text's
/// time zone (the place's)
private struct PlannerTimePicker: View {
    @Binding var time: Date
    let l: UIText
    /// The calendar's height, measured (the columns scroll within it)
    @State private var calendarHeight: CGFloat = 150

    var body: some View {
        let columns = TimeColumns(text: l)
        HStack(alignment: .top, spacing: 10) {
            DatePicker(l.t("Leave at"), selection: $time, in: Timetable.calendar(in: l.timeZone).startOfDay(for: Date())..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if h > 0, abs(h - calendarHeight) > 0.5 { calendarHeight = h }
                }
            // The lines get the columns' height from the frame below
            HStack(spacing: 4) {
                ForEach(columns.kinds, id: \.self) { kind in
                    Divider()
                    PlannerTimeColumn(columns: columns, kind: kind, name: columns.name(kind, text: l), time: $time)
                }
            }
            .frame(height: calendarHeight)
        }
    }
}

/// One column of the time picker: its cells in a scrolling column, the picked one filled with the accent color and in the middle when
/// the popover opens. A click picks a cell and gives the column the keyboard (lightly tinted then): the up and down arrows pick the
/// cell above or below, stopping at the ends. To screen readers the column is one stepper, read as its name and the picked value and
/// changed with its own keys, as the system's own time pickers (its cells aren't read one by one, nor reached with Tab)
private struct PlannerTimeColumn: View {
    let columns: TimeColumns
    let kind: TimeColumns.Kind
    let name: String
    @Binding var time: Date
    @FocusState private var focused: Bool

    var body: some View {
        let picked = columns.selected(kind, in: time)
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                // Every cell as wide as the widest (each fills the column's width)
                VStack(spacing: 2) {
                    ForEach(columns.cells(kind), id: \.value) { cell in
                        PlannerTimeCell(text: cell.text, picked: cell.value == picked) {
                            time = columns.setting(kind, to: cell.value, in: time)
                            focused = true
                        }
                        .id(cell.value)
                    }
                }
                .padding(3)
                .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
            .onAppear {
                // Once the popover has laid the column out
                DispatchQueue.main.async { scroller.scrollTo(picked, anchor: .center) }
            }
            // An arrow key can pick a cell out of sight: bring it in, scrolling as little as needed
            .onChange(of: picked) { _, now in
                withAnimation(Motion.ease(0.15)) { scroller.scrollTo(now) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(focused ? Color.accentColor.opacity(0.08) : Color.clear))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard direction == .up || direction == .down,
                  let next = columns.stepping(kind, by: direction == .up ? -1 : 1, in: time) else { return }
            time = next
        }
        // A stepper, not a plain element with an adjustable action: on macOS screen readers change only a control that is one.
        // Up a value goes to the next cell down the column (a later time), as the down arrow does
        .accessibilityRepresentation {
            Stepper {
                Text(name)
            } onIncrement: {
                step(1)
            } onDecrement: {
                step(-1)
            }
            .accessibilityValue(columns.cells(kind).first { $0.value == picked }?.text ?? "")
        }
    }

    private func step(_ offset: Int) {
        if let next = columns.stepping(kind, by: offset, in: time) { time = next }
    }
}

/// One cell of a time column: a number (or AM / PM) to click, filled with the accent color when picked, lightly shaded under the mouse
private struct PlannerTimeCell: View {
    let text: String
    let picked: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            Text(text)
                .monospacedDigit()
                .fontWeight(picked ? .semibold : nil)
                .foregroundStyle(picked ? Color.white : Color.primary)
                .padding(.horizontal, 8)
                .frame(minWidth: 34, maxWidth: .infinity, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(picked ? Color.accentColor : hovering ? Color.primary.opacity(0.07) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The column takes the keyboard, not each of its cells (see PlannerTimeColumn)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}
