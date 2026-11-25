import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// Right side of the title bar: transit mode switch (Subway, Bus, Train, Ferry; just these four), the same in every metro area.
/// For the current place and its metro area see AreaLabel.
struct SystemSwitcher: View {
    @EnvironmentObject var transit: TransitModel
    @Namespace private var space

    var body: some View {
        // One icon button per transit mode, the selected one highlighted; hovering shows a small tooltip naming it.
        // The blue slides to the new mode, also when it's switched from the menu or a keyboard shortcut
        HStack(spacing: 2) {
            ForEach(TransitSystem.modes) { sys in
                ModeButton(system: sys, space: space)
            }
        }
        .segmentThumb(transit.system, in: space, cornerRadius: 6)
        .padding(2)
        .fixedSize()
        // One group for screen readers with its own name, the four buttons inside it. Once a screen reader is attached, the name the
        // title bar gives this item (see ModeButton) goes on every element at the top of the item: without this group all four
        // buttons would read that name; with it the group gets it and the buttons keep their own
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(transit.l10n.t("Transit")))
    }

    static func name(_ s: TransitSystem, _ l: UIText) -> String { l.modeName(s) }
}

/// A button for one transit mode. Hovering briefly shows the system tooltip (name and what it includes); clicking switches.
/// It uses the system tooltip (.help), not a popover: a popover is a separate small window, and while it is open the first click only closes it,
/// so switching would take two clicks. The system tooltip doesn't intercept clicks, so one click works.
struct ModeButton: View {
    @EnvironmentObject var transit: TransitModel
    var system: TransitSystem
    /// Shared by the four buttons, so the blue slides from one to the next (see SystemSwitcher)
    var space: Namespace.ID
    @State private var hovering = false

    var body: some View {
        let l = transit.l10n
        let selected = system == transit.system
        // No withAnimation here: only the switch and the content that comes in move (their own animations), not everything the new mode changes
        Button {
            transit.system = system
        } label: {
            // "Transit" on every button's own label, not the mode's name (it isn't shown, only the icon). The title bar names its
            // item after the first label in it, and once a screen reader is attached it puts that name on the switch's group too
            // (SystemSwitcher), over the group's own: with the mode's name here, the group read "Subway" in every window.
            // Each button's name for screen readers is its accessibilityLabel below
            Label(l.t("Transit"), systemImage: system.symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 30, height: 22)
                // Light gray background on hover, same as the refresh and settings buttons; the selected one stays blue
                .background(RoundedRectangle(cornerRadius: 6).fill(!selected && hovering ? Color.primary.opacity(0.1) : Color.clear))
                .segmentSlot(system, in: space)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Only the short line from under the sidebar title: the system draws tooltips and can't line up a wrapped list
        // (the whole list is in the sidebar title's popover)
        .help(l.modeName(system) + "\n" + l.modeParts(system, in: transit.headerArea))
        .accessibilityLabel(Text(l.modeName(system)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Top of the sidebar: which transit mode is being viewed, a large icon plus name (prominent in the main view).
/// The line under the name says which kinds of vehicles the mode has in the start place's metro area, in at most four lines (a narrow
/// sidebar with larger text or a long translation).
/// Clicking the header (the info icon shows it can be clicked) opens a popover with that area's operators, one per line, each
/// marked "Live" or "Timetable", and a button to Settings' data source section.
/// A popover keeps this list row's height the same (sidebar rows must not change height).
struct ModeHeader: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openSettings) private var openSettings
    @State private var hovering = false
    @State private var showDetails = false

    /// The words in the header: the mode's name and the line under it. The sidebar makes the row new when they change: they
    /// decide how many lines it takes (a list row's height doesn't follow its content)
    @MainActor static func words(of transit: TransitModel) -> [String] {
        let l = transit.l10n
        return [l.modeName(transit.system), l.modeParts(transit.system, in: transit.headerArea)]
    }

    /// Where one kind ends and the next begins in the line under the name (AppText.modeParts)
    private static let kindBreak = "\u{00A0}· "

    /// The last kind of vehicle in the line under the name, its words kept together (all of the line when it has one kind)
    static func lastKind(of parts: String) -> String {
        guard let end = parts.range(of: kindBreak, options: .backwards) else { return parts }
        return String(parts[end.upperBound...])
    }

    /// The line under the name with ordinary spaces between the words of its last kind, so they can wrap there. Only the last
    /// kind: the ones before it and the dots stay as they are
    static func loosenedLastKind(_ parts: String) -> String {
        let start = parts.range(of: kindBreak, options: .backwards)?.upperBound ?? parts.startIndex
        return String(parts[..<start]) + parts[start...].replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// The line under the name, small and gray, with the info icon right after the last word. A no-break space before the icon,
    /// so it never sits alone on the next line. Up to four lines, so a long translation at the larger text size in the narrowest
    /// sidebar isn't cut off
    private func kindsLine(_ parts: String) -> some View {
        (Text(parts) + Text("\u{00A0}") + Text(Image(systemName: "info.circle")))
            .font(.scaled(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(4)
    }

    var body: some View {
        let l = transit.l10n
        let parts = l.modeParts(transit.system, in: transit.headerArea)
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: transit.system.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.modeName(transit.system))
                        .font(.scaled(.title2).bold())
                    // The whole block is the button. Each kind's words stay together, unless the last kind and the info icon are
                    // wider than the whole line (a long translation, the narrowest sidebar): then that kind wraps between its words,
                    // and the icon stays with its last word instead of going alone onto a line of its own. Measured with a hidden
                    // copy of the last kind and the icon, each time the row is laid out
                    ViewThatFits(in: .horizontal) {
                        IdealWidthFromSecond {
                            kindsLine(parts)
                            kindsLine(Self.lastKind(of: parts))
                                .fixedSize()
                                .hidden()
                        }
                        kindsLine(Self.loosenedLastKind(parts))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            // Light gray on hover and while the popover is open, a little wider than the contents (only drawn wider: the row's width stays the same)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(hovering || showDetails ? 0.07 : 0))
                    .padding(.horizontal, -6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $showDetails, arrowEdge: .trailing) {
            ModeDetailsPopover(l: l, system: transit.system, area: transit.headerArea, outside: transit.isOutsideArea && !transit.isDemo,
                               isDemo: transit.isDemo, access: transit.liveAccess) {
                showDetails = false
                SettingsJump.toDataSource()
                NSApp.activate()
                openSettings()
            }
            .environment(\.locale, transit.language.locale)
            .environment(\.layoutDirection, transit.layoutDirection)
        }
        // Give screen readers one ready-made sentence instead of letting the system walk the sidebar list's children and assemble one:
        // that recomputes its own layout during list updates, logging "Cycle detected through attribute".
        // List rows use only lineLimit, no vertical fixedSize (same reason).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(l.modeName(transit.system) + ", " + parts))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showDetails = true }
    }
}

/// Lays out its first view in the space it is offered. Asked for its ideal width, it answers with its second view's (a hidden view
/// that only measures): in a ViewThatFits it is taken only where that second view fits on one line
struct IdealWidthFromSecond: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        guard let width = proposal.width, width.isFinite else {
            let ideal = subviews[1].sizeThatFits(.unspecified).width
            return CGSize(width: ideal, height: subviews[0].sizeThatFits(ProposedViewSize(width: ideal, height: nil)).height)
        }
        return subviews[0].sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        subviews[1].place(at: bounds.origin, proposal: .unspecified)
    }
}

extension TransitModel {
    /// The metro area the sidebar's header line and its popover are about: the start place's. Demo mode's place is in
    /// Manhattan. Nil outside every metro area, and before there is a start place
    var headerArea: MetroArea? { isDemo ? .newYork : areaRegion?.metroArea }

    /// The metro area Settings' data source opens at, and How It Works and About write about: the start place's; outside them all
    /// the one nearest the start place; the first of them before there's any place. New York in Demo mode (Manhattan)
    var sourcesArea: MetroArea {
        if dataSource == .mock { return .newYork }
        return areaRegion?.metroArea ?? origin.flatMap { MetroArea.nearest(to: $0.coordinate) } ?? MetroArea.allCases[0]
    }

    /// Whose times are live now besides the free live data (the "Live" and "Timetable" marks in the header's popover): a key or
    /// account counts once the user has one and it wasn't refused, as in Settings' data source rows
    var liveAccess: ModeCoverage.LiveAccess {
        ModeCoverage.LiveAccess(mtaBusKey: hasBusKey && busError != .invalidKey,
                                njTransitAccount: hasNJTransitAccount && !njTransitRejected,
                                suffolkKey: hasSuffolkKey && !suffolkKeyRejected,
                                failedBuses: busRealtimeFailed.union(njTransitBusRejected ? [RegionalBusFeed.njTransit.code] : []))
    }
}

/// The sidebar header's popover: the mode's name and the start place's metro area, that area's operators one per line, each
/// marked "Live" or "Timetable" like Settings' data source rows, and a button to that section of Settings. Outside the service area
/// it says so in place of the list.
struct ModeDetailsPopover: View {
    let l: UIText
    let system: TransitSystem
    /// The start place's metro area: only its operators are listed. Nil: all of them (no start place yet)
    let area: MetroArea?
    /// The start place is outside the service area
    let outside: Bool
    let isDemo: Bool
    let access: ModeCoverage.LiveAccess
    /// Opens Settings at its data source section
    var openDataSource: () -> Void = {}

    var body: some View {
        let place: String? = outside ? l.t("Outside the service area") : area.map { l.metroAreaName($0) }
        let rows = outside ? [] : ModeCoverage.operators(for: system, in: area, access: access)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(l.modeName(system))
                    .font(.scaled(.headline))
                if let place {
                    Text(place)
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty, !outside {
                Text(l.t("No data for this transit system in this area yet."))
                    .font(.scaled(.callout))
                    .foregroundStyle(.secondary)
            }
            // One operator or group per line, the bullets in a column of their own, so a wrapped line starts under its text, not under
            // the bullet (like How It Works); its mark at the end of the line, level with the first line of the text. Demo mode's
            // times are made up: no marks there. Screen readers still read it line by line
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").accessibilityHidden(true)
                            Text(l.operatorRow(row))
                            Spacer(minLength: 4)
                            if let live = row.live, !isDemo {
                                SourceBadgeLabel(badge: live ? .live : .timetable, l: l)
                            }
                        }
                    }
                }
                .font(.scaled(.callout))
            }
            if isDemo {
                Label(l.t("Demo data only: made-up times, not from any transit operator."), systemImage: "theatermasks")
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
            }
            Button(l.t("Data Source…")) { openDataSource() }
                .appButtonStyle()
                .controlSize(.small)
        }
        .labelStyle(IconColumnLabelStyle())
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320, alignment: .leading)
        .padding(14)
    }
}

/// Current time (to the minute), in the 12 / 24-hour format from Settings. Changes on each full minute.
/// In the starting place's time zone like every time in the app, with the zone named (EDT / EST, in the language's own form; outside
/// the service area only when it isn't this Mac's, see AppText.currentTime).
/// Ticks every 60 seconds from the start of the minute (Timetable.minuteStart), not on the system's every-minute schedule: that one
/// goes by the clock's reading, and after clocks fell back from 2:00 to 1:00 it was seen still standing at 1:59 EDT 20 minutes later.
struct CurrentTimeLabel: View {
    @EnvironmentObject var transit: TransitModel
    var font: Font = .headline
    /// Without the clock icon where another clock is next to it (Plan a Trip's departure time)
    var icon = true
    /// Another place's text than the starting place's (Plan a Trip's, in its place's time zone)
    var text: UIText?

    var body: some View {
        let l = text ?? transit.l10n
        TimelineView(.periodic(from: Timetable.minuteStart(Date()), by: 60)) { context in
            // The number is what matters: the icon is gray and a bit smaller so the time doesn't look crowded
            HStack(spacing: 5) {
                if icon {
                    Image(systemName: "clock")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(l.currentTime(BoardClock.now(context.date)))
            }
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .help(l.t("Current time"))
                .accessibilityLabel(l.t("Current time") + " " + l.currentTime(BoardClock.now(context.date)))
        }
    }
}

/// The line saying whose time the times are when this Mac's clock reads differently (AppText.timeZoneNote): under the station page's
/// name and in the menu bar panel; Plan a Trip says it for its own place. Nothing when the times read as on the Mac's clock
struct TimeZoneNoteLine: View {
    @EnvironmentObject var transit: TransitModel
    var font: Font = .scaled(.caption)

    var body: some View {
        let l = transit.l10n
        if let note = l.timeZoneNote(at: BoardClock.now(), areaName: transit.areaRegion.map { l.metroAreaName($0.metroArea) }) {
            TimeZoneNoteText(note: note, font: font)
        }
    }
}

/// How the time-zone note looks, wherever it's said (TimeZoneNoteLine, Plan a Trip): in the notices' orange and a little bold, as
/// "Outside the service area" is; in gray it was easily missed
struct TimeZoneNoteText: View {
    let note: String
    var font: Font = .scaled(.caption)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "globe").accessibilityHidden(true)
            // Not fixedSize: in the station page's fixed header it would be measured at a very narrow width (see BusKeyPrompt)
            Text(note).lineLimit(3)
        }
        .font(font.weight(.medium))
        .foregroundStyle(Color.noticeOrange)
    }
}

struct AreaLabel: View {
    @EnvironmentObject var transit: TransitModel

    /// Whether the block has anything to say: "Standby", outside the service area, or the part of it the place is in. Not while
    /// the place isn't known (none chosen yet, a position too far off to use, the first position still being found)
    @MainActor static func hasText(_ transit: TransitModel) -> Bool {
        !transit.isActive || transit.isOutsideArea || transit.areaRegion != nil
    }

    var body: some View {
        let l = transit.l10n
        // On standby show only the moon icon and one "Standby" line, whether or not in the service area
        let standby = !transit.isActive
        // The box width never changes: it equals the widest of the metro area names, the longest region name and "Outside the service area"
        // (sized by an invisible layer). A toolbar box never shrinks back once widened (after "Outside the service area"
        // switching back, the box stayed as long with empty space on the right), so it simply never grows or shrinks; long place names outside the area are truncated, hover shows them in full.
        sizer(l)
            .hidden()
            .overlay(alignment: .leading) {
                if standby {
                    // On standby write only one "Standby" line, without region or place
                    HStack(spacing: 4) {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                        Text(l.t("Standby"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                    }
                } else {
                VStack(alignment: .leading, spacing: 0) {
                    // Top line in small text: the name of the metro area the place is in when in range; the place name when out of range.
                    // Bottom line: icon plus status. Out of range is split into these two lines too, rather than wrapping a sentence onto two lines, so there's no empty space on the right
                    Text(transit.isOutsideArea ? (transit.areaName ?? " ") : (metroName(l) ?? " "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: transit.isOutsideArea ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(transit.isOutsideArea ? Color.noticeOrange : Color.noticeGreen)
                            .font(.system(size: 10))
                        // In range always show only the region name, with a green check meaning in range; the full sentence "… · You're in the service area"
                        // goes only in the hover tooltip (so every place shows the same short form).
                        Text(transit.isOutsideArea ? l.t("Outside the service area")
                             : (transit.areaName ?? l.t("You're in the service area")))
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .opacity(transit.areaName == nil && !transit.isOutsideArea ? 0 : 1)
                }
                // Text no smaller than 10 pt and never shrunk further; the box width is already computed from the widest line (see sizer), so it fits
                .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 8)
            .help(standby ? l.t("Standby") + "\n" + l.t("Nothing is refreshed or downloaded on standby.")
                  : transit.isOutsideArea ? line(l) : (metroName(l).map { $0 + "\n" } ?? "") + line(l))
            .accessibilityElement(children: .combine)
    }

    /// The metro area the place is in; none before a place is known (no area is named until then)
    private func metroName(_ l: UIText) -> String? {
        transit.areaRegion.map { l.t($0.metroArea.nameKey) }
    }

    /// Invisible layer: one "metro area name + icon + that line" for each region name and for "Outside the service area", stacked, taking the widest width.
    private func sizer(_ l: UIText) -> some View {
        ZStack(alignment: .leading) {
            // One for each region name, plus one for "Outside the service area"
            ForEach(MetroSubRegion.allCases.map { l.subRegionName($0) } + [l.t("Outside the service area"), l.t("Standby")], id: \.self) { status in
                VStack(alignment: .leading, spacing: 0) {
                    // The longer of the metro area names
                    ZStack(alignment: .leading) {
                        ForEach(MetroArea.allCases, id: \.self) { area in
                            Text(l.t(area.nameKey))
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(status)
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .accessibilityHidden(true)
    }

    private func line(_ l: UIText) -> String {
        let place = transit.areaName ?? ""
        let status = transit.isOutsideArea ? l.t("Outside the service area") : l.t("You're in the service area")
        return place.isEmpty ? status : l.dotted([place, status])
    }
}
