import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// Notice for stale data, failed downloads or rate limiting, placed above the trips where it's seen at a glance.
/// Each cause is mentioned only once: when rate-limited, mention only that (refreshing won't help then, so don't tell the user to refresh);
/// otherwise mention only download errors if any; only if neither, mention stale data.
/// Rate limits and connection notices are only the ones about this station's providers (see NoticeScope); with none, the station's own notice shows.
/// This Mac's clock being off is said first, above any of them: a wrong clock is often why the others fail.
struct StatusBanner: View {
    @EnvironmentObject var transit: TransitModel
    var now: Date
    /// The station shown: live-data problems of one company or feed appear only at its stations (nil = only problems that affect all)
    var station: BoardStation?

    var body: some View {
        let l = transit.l10n
        // This Mac's clock is off: the times already go by the servers' time (ClockSkew); this says how to set the clock right. On
        // top, with the other notices under it
        if let offset = transit.clockOffset {
            Label(l.clockOffsetText(offset), systemImage: "clock.badge.exclamationmark")
                .font(.scaled(.callout))
                .foregroundStyle(Color.noticeOrange)
                .lineLimit(3)
                .help(l.clockOffsetText(offset))
        }
        // This station's operator's new data hasn't been used for 14 days (DataChangeLog.longHeldDays): said here too, with the
        // button to Settings' Data source page, which tells why and has Report an Issue… (this area can't scroll: two lines each).
        // One line for each of the station's operators held that long
        let held = transit.heldLongLines(at: station, now: now)
        if !held.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(held, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle")
                            .font(.scaled(.callout))
                            .foregroundStyle(Color.noticeOrange)
                            .lineLimit(2)
                            .help(line)
                    }
                }
                OpenSettingsButton(l: l, target: .dataSource)
                    .fixedSize()
            }
        }
        let limits = transit.rateLimits(at: station)
        let reach = transit.reachNotices(at: station)
        if !limits.isEmpty || !reach.isEmpty {
            // A data provider says there are too many requests: paused for a while, so show a notice
            ForEach(limits, id: \.provider) { n in
                Label(transit.rateLimitText(n), systemImage: "hourglass")
                    .font(.scaled(.callout))
                    .foregroundStyle(Color.noticeOrange)
            }
            // Unreachable (possibly network restrictions). This area can't scroll: several providers merge into one line, long text is truncated, hover shows it all.
            // Problems on the provider's side (URL changed, format changed, not updating) aren't merged: one per line, with a triangle icon.
            if let combined = l.reachCombinedText(reach) {
                Label(combined, systemImage: "wifi.exclamationmark")
                    .font(.scaled(.callout))
                    .foregroundStyle(Color.noticeOrange)
                    .lineLimit(4)
                    .help(combined)
            }
            let rest = l.reachSeparate(reach)
            // Problems on the operator's side that have lasted 14 days: a line of their own says since when (see LongProblemLine)
            let lasting = rest.filter { !$0.problem.isNetwork && NetworkReach.longProblemSince($0.provider, now: now) != nil }
            ForEach(rest, id: \.self) { n in
                // About this Mac or its network (its date, a sign-in page): longer, and what to do is at the end
                Label(transit.reachText(n), systemImage: l.reachSymbol(n))
                    .font(.scaled(.callout))
                    .foregroundStyle(Color.noticeOrange)
                    .lineLimit(n.problem.isGeneral ? 3 : 2)
                    .help(transit.reachText(n))
                // After 14 days of a problem on the operator's side: since when, and Check for Updates… (one line, under the text above)
                if lasting.contains(n) {
                    Label {
                        LongProblemLine(provider: n.provider, now: now)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: l.reachSymbol(n)).hidden()
                    }
                    .font(.scaled(.callout))
                }
            }
            // This area can't scroll: an operator with the line saying since when gets no gray explanation (its last sentence, that an
            // app update may be needed, is what that line's Check for Updates… button is for); the other notices keep theirs
            if let why = l.reachExplanation(rest.filter { !lasting.contains($0) }) {
                Text(why)
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(why)
            }
        } else if let err = station.map(transit.notice(for:)) ?? transit.lastError {
            // A notice that says what to change in Settings has the button to there, on its line (this area can't scroll)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.scaled(.callout))
                    .foregroundStyle(Color.noticeRed)
                if let target = transit.settingsPlace(forNotice: err) {
                    OpenSettingsButton(l: l, target: target)
                }
            }
        } else if transit.isStale(now: now) {
            Label(l.pick(transit.system,
                         train: l.t("Data is out of date, so trains show “Not sure”. Please refresh."),
                         bus: l.t("Data is out of date, so buses show “Not sure”. Please refresh."),
                         ferry: l.t("Data is out of date, so ferries show “Not sure”. Please refresh.")),
                  systemImage: "exclamationmark.arrow.circlepath")
                .font(.scaled(.callout))
                .foregroundStyle(Color.noticeOrange)
        }
    }
}

/// Timetable-only landings (Staten Island Ferry): state clearly that there is no realtime data and times come from the timetable.
struct ScheduleOnlyNotice: View {
    @EnvironmentObject var transit: TransitModel
    var station: BoardStation

    var body: some View {
        let l = transit.l10n
        let note = transit.scheduleOnlyNote(station)
        if transit.isScheduleOnly(station), note != nil || transit.needsSecurityCheck(station) {
            VStack(alignment: .leading, spacing: 6) {
                if let note {
                    Label(note, systemImage: "calendar.badge.clock")
                    // It says to add or check a key or account in Settings: the button opens Keys and accounts
                    if transit.scheduleOnlyNoteAsksForKey(station) {
                        OpenSettingsButton(l: l, target: .keys)
                    }
                }
                // Statue of Liberty ferry: remind that tickets must be bought and security cleared before boarding
                if transit.needsSecurityCheck(station) {
                    Label(l.t("You need a ticket and a security check before boarding. Catch estimates allow 30 min for that."),
                          systemImage: "ticket")
                }
            }
            .font(.scaled(.callout))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.noteBackground))
            .contrastBorder(cornerRadius: 8)
        }
    }
}

/// A station whose operator publishes no times the app can use (NoTimesStations): why there are none, how often it runs where its
/// website says so, and a button to the operator's own page for the station. The station page shows it in a box of its own;
/// the trip planner's card shows it without one, in the card's own styles
struct NoTimesNotice: View {
    var place: NoTimesStation
    var l: UIText
    var boxed = true

    var body: some View {
        if boxed {
            content
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.noteBackground))
                .contrastBorder(cornerRadius: 8)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: boxed ? 8 : 6) {
            if boxed {
                Label(l.t("No times available"), systemImage: "clock.badge.xmark")
                    .font(.scaled(.headline))
            } else {
                // Where the directions' titles would be
                Text(l.t("No times available"))
                    .font(.scaled(.subheadline).bold())
                    .foregroundStyle(.secondary)
            }
            Group {
                Text(l.noTimesReason(place))
                if let headway = l.noTimesHeadway(place) {
                    Text(headway)
                }
            }
            .font(.scaled(boxed ? .callout : .caption))
            .foregroundStyle(boxed ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
            OpenWebsiteButton(place: place, l: l)
        }
    }
}

/// Opens the operator's own page for a station without times in the browser (the station page, the map's card, the trip planner)
struct OpenWebsiteButton: View {
    var place: NoTimesStation
    var l: UIText
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(place.website)
        } label: {
            Label(l.t("Open Website"), systemImage: "arrow.up.right.square")
        }
        .appButtonStyle(.bordered)
        // Where it goes, before going there
        .help(place.website.absoluteString)
    }
}

/// Buses need the user's own key: when switched to buses with no key yet (or an unusable key), show a notice at the top of the main view with a button to add it.
struct BusKeyPrompt: View {
    @EnvironmentObject var transit: TransitModel
    /// The stop the station page shows: the notice only where MTA's buses stop (a stop of other companies only has no use for
    /// the key). Nil: wherever MTA's buses stop nearby
    var station: BoardStation?
    @State private var showSheet = false

    var body: some View {
        let l = transit.l10n
        let mtaStop = station.map { $0.stations.contains { !transit.isTimetableStation($0.id) } } ?? true
        if mtaStop, transit.needsBusKey || (transit.isBus && transit.busError == .invalidKey) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(Color.noticeOrange).font(.scaled(.title3))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if transit.busKeyUnreadable {
                        // The key may well still be saved: offer to read it again, not to get one
                        KeychainRetryLine(credential: .busTime, fixedHeight: false)
                            .font(.scaled(.headline))
                    } else {
                        Text(transit.hasBusKey ? l.t("MTA Bus Time didn't accept your key.") : l.t("Add a key to see live bus times"))
                            .font(.scaled(.headline))
                        // Can't use fixedSize: it's inside the fixed header area, and when computing minimum height it measures at a very narrow width and gets a very tall height,
                        // pushing the whole window's content up.
                        Text(l.t("Bus times come from MTA Bus Time, which needs a free personal key. Getting one takes about two minutes."))
                            .font(.scaled(.callout))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 8)
                Button(transit.hasBusKey || transit.busKeyUnreadable ? l.t("Change key…") : l.t("Add key…")) { showSheet = true }
                    .appButtonStyle(.prominent)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.keyPromptBackground))
            .contrastBorder(cornerRadius: 10)
            .sheet(isPresented: $showSheet) { BusKeySheet() }
        }
    }
}
