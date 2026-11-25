import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// Settings, Data source page, at its top: how the data sources are doing. A row for each thing that's wrong now (a provider says
/// there are too many requests, some sources can't be reached, an operator's new data wasn't used, the data in use has what this
/// version doesn't know, this Mac's clock is off). With no row to show there is no section
struct DataStatusSettings: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let l = transit.l10n
        if hasRows {
            SettingsSection(l.t("Status")) {
                // A data provider says there are too many requests: a notice is shown while rate-limited
                if !transit.rateLimits.isEmpty {
                    StatusRow(icon: "hourglass", title: l.t("Too many requests")) {
                        Label(l.t("Paused"), systemImage: "pause.circle.fill").foregroundStyle(Color.noticeOrange)
                    } detail: {
                        ForEach(transit.rateLimits(at: nil), id: \.provider) { n in
                            Text(transit.rateLimitText(n))
                        }
                    }
                }
                // Unreachable data providers (possibly network restrictions): one per line, with an explanation at the end
                if !transit.reachNotices.isEmpty {
                    let offline = transit.reachNotices.contains { $0.problem == .offline }
                    // Problems on the provider's side (URL changed, format changed, not updating)
                    let sourceProblem = transit.reachNotices.contains { !$0.problem.isNetwork }
                    StatusRow(icon: offline ? "wifi.slash" : (sourceProblem ? "exclamationmark.triangle" : "wifi.exclamationmark"),
                              title: offline ? l.t("No internet connection")
                                  : (sourceProblem ? l.t("Some data sources have problems") : l.t("Can't reach some data sources"))) {
                        Label(sourceProblem && !offline ? l.t("Problem") : l.t("Not reachable"),
                              systemImage: "xmark.circle.fill").foregroundStyle(Color.noticeOrange)
                    } detail: {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(transit.reachNotices(at: nil), id: \.self) { n in
                                Text(transit.reachText(n)).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            }
                            if let why = transit.reachExplanation() {
                                Text(why).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                // Operators whose new data looked wrong and wasn't used (DataUpdateGate): which one and why, how many stops the data
                // in use (and from when) and the new data have, the lines the new data leaves out, and Report an Issue…, which opens
                // a new issue on GitHub with the details filled in (the user's browser; the app sends nothing). The button goes under
                // its operator's lines, so each operator's lines have the width and the buttons line up. Then that the app goes on
                // with the data it had and tries the new data again each day
                let kept = transit.dataChanges.kept
                if !kept.isEmpty {
                    StatusRow(icon: "exclamationmark.triangle", title: l.t("Some new data wasn't used")) {
                        Label(l.t("Problem"), systemImage: "xmark.circle.fill").foregroundStyle(Color.noticeOrange)
                    } detail: {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(kept, id: \.key) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(transit.dataNotUsedReason(entry)).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                    ForEach(transit.dataNotUsedDetails(entry), id: \.self) { line in
                                        Text(line).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Button(l.t("Report an Issue…")) { openURL(transit.issueReport(entry)) }
                                        .appButtonStyle()
                                        .controlSize(.small)
                                        .fixedSize()
                                        .padding(.top, 2)
                                        // One for each operator: screen readers say whose
                                        .accessibilityLabel(Text(l.t("Report an Issue…") + l.comma + transit.dataOperatorName(entry.key)))
                                }
                            }
                            Text(l.t("The app keeps using the data it had and tries the new data again each day."))
                                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                // The data in use has what this version doesn't know (UnknownData): it's used, and only that part shows less. Which
                // operator and what, that the rest works as usual, then Check for Updates… (checks once and shows the result, as the
                // app menu's item does) and Report an Issue…
                if !transit.unknownData.isEmpty {
                    StatusRow(icon: "arrow.down.circle", title: l.t("Part of the new data needs a newer version")) {
                        Label(l.t("Update"), systemImage: "arrow.down.circle.fill").foregroundStyle(Color.noticeOrange)
                    } detail: {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(transit.unknownData, id: \.self) { finding in
                                Text(transit.unknownDataText(finding)).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            }
                            Text(l.t("Everything else works as usual. A newer version of the app may know them."))
                                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            // Side by side where they fit, else one under the other: two buttons that keep their titles on one
                            // line would otherwise make the whole page wider than its window (French with the larger text)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { unknownDataButtons(l) }
                                VStack(alignment: .leading, spacing: 6) { unknownDataButtons(l) }
                            }
                            .padding(.top, 2)
                            // Why Check for Updates… is grayed out, where it shows
                            if let reason = transit.checkOnlineReason {
                                Text(reason).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                // This Mac's clock is off: the app goes by the servers' time, and this says how to set the clock right
                if let offset = transit.clockOffset {
                    StatusRow(icon: "clock.badge.exclamationmark", title: l.t("Check this Mac's date and time")) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color.noticeOrange)
                            .accessibilityHidden(true)
                    } detail: {
                        Text(l.clockOffsetText(offset)).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Whether there's a row to show
    private var hasRows: Bool {
        return !transit.rateLimits.isEmpty || !transit.reachNotices.isEmpty || !transit.dataChanges.kept.isEmpty
            || !transit.unknownData.isEmpty || transit.clockOffset != nil
    }

    /// Check for Updates… (checks once and shows the result, as the app menu's item does) and Report an Issue…, under the data
    /// this version doesn't know; each keeps its title on one line
    @ViewBuilder
    private func unknownDataButtons(_ l: UIText) -> some View {
        CheckOrStartButton(title: l.t("Check for Updates…"), small: true) {
            transit.checkForUpdates()
            SettingsJump.to(.updates)
            NSApp.activate()
            openSettings()
        }
        .fixedSize()
        Button(l.t("Report an Issue…")) { openURL(transit.unknownIssueReport()) }
            .appButtonStyle()
            .controlSize(.small)
            .fixedSize()
            // Told apart from each operator's above it: screen readers say which row it's in
            .accessibilityLabel(Text(l.t("Report an Issue…") + l.comma + l.t("Part of the new data needs a newer version")))
    }

    /// "20260826-X-long-term…" → "August 26, 2026" (MTA feed version numbers start with a date).
    static func feedDate(_ version: String) -> Date? {
        let digits = String(version.prefix(8))
        guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        // The subway timetable's day, in its metro area's time zone
        f.timeZone = Timetable.timeZone
        f.dateFormat = "yyyyMMdd"
        return f.date(from: digits)
    }
}

extension TransitModel {
    /// An operator's name in Settings by its key in the log of data checks: MTA's two station lists and NJ Transit's buses as
    /// their rows call them, the others by their own names
    func dataOperatorName(_ key: String) -> String {
        switch key {
        case DataChangeLog.subwayKey: return l10n.t("MTA subway")
        case DataChangeLog.cityBusKey: return l10n.t("MTA buses (MTA Bus Time)")
        case DataChangeLog.key(bus: RegionalBusFeed.njTransit.code): return l10n.t("NJ Transit buses")
        default: return DataChangeLog.operatorName(of: key)
        }
    }

    /// Why an operator's new data wasn't used, in Status: it looks incomplete (most stops gone, or none), or the number of
    /// its stops changed too much
    func dataNotUsedReason(_ entry: DataChangeLog.Entry) -> String {
        let name = dataOperatorName(entry.key)
        if entry.reason == .countJump {
            return l10n.f("%@: the number of stops in the new data changed too much, so it wasn't used.", name)
        }
        return l10n.f("%@: the new data looks incomplete, so it wasn't used.", name)
    }

    /// "New data not used since …": the line in an operator's Data source row while its new data isn't in use; nil otherwise
    func dataNotUsedLine(_ key: String) -> String? {
        guard let entry = dataChanges.entries[key], entry.outcome == .kept else { return nil }
        let l = l10n
        return l.f("New data not used since %@. Using the data it had.", l.day(entry.notUsedSince, timeZone: l.macZone))
    }

    /// Under an operator's reason in Status: how many stops the data in use has (and from when) and the new data, and the lines
    /// the new data leaves out: by name when they are three at most, otherwise only how many (DataChangeLog.Entry.linesGone).
    /// Nothing an entry written before these were kept doesn't have
    func dataNotUsedDetails(_ entry: DataChangeLog.Entry) -> [String] {
        let l = l10n
        var lines: [String] = []
        if let inUse = entry.stopsInUse, let new = entry.stopsNew {
            let stops = l.number(Double(inUse)), newStops = l.number(Double(new))
            if let since = entry.inUseSince ?? dataInUseDay(entry.key) {
                lines.append(l.f("Data in use: %1$@ stops, from %2$@. New data: %3$@ stops.", stops, l.day(since, timeZone: l.macZone), newStops))
            } else {
                lines.append(l.f("Data in use: %1$@ stops. New data: %2$@ stops.", stops, newStops))
            }
        }
        let gone = entry.linesGone
        if !gone.names.isEmpty {
            lines.append(l.f("Lines not in the new data: %@.", l.joinedList(gone.names)))
        } else if gone.count > 0 {
            lines.append(l.f("Not in the new data: %@ lines.", l.number(Double(gone.count))))
        }
        return lines
    }

    /// The day an operator's data in use came, when its log entry doesn't tell (one written before it was kept): its last good
    /// download; for the subway, its timetable's own date. Nil for the city buses' stop list
    func dataInUseDay(_ key: String) -> Date? {
        if key == DataChangeLog.subwayKey { return catalog.flatMap { DataStatusSettings.feedDate($0.feedVersion) } }
        if key.hasPrefix("bus:") { return FerryStore.njBus.operatorDates[String(key.dropFirst(4))] }
        for store in [FerryStore.train, .shared, .path, .lightRail] where store.sources.contains(where: { $0.rawValue == key }) {
            return store.operatorDates[key]
        }
        return nil
    }

    /// A line of Status for data this version doesn't know (UnknownData): the operator and what shows less
    func unknownDataText(_ finding: UnknownData.Finding) -> String {
        let name = dataOperatorName(finding.key)
        switch finding.kind {
        case .stations: return l10n.f("%@: some stations in its data are new to this version. Their trains aren't shown.", name)
        case .lines: return l10n.f("%@: some lines in its data are new to this version. They show the operator's own codes.", name)
        case .directions:
            return l10n.f("%@: some stations in its data are new to this version. Their directions show only where the trains end.", name)
        }
    }

    /// The gray line in an operator's Data source row while its data has what this version doesn't know; nil otherwise
    func dataPartlyKnownLine(_ key: String) -> String? {
        unknownData.contains { $0.key == key } ? l10n.t("Part of its data is new to this version.") : nil
    }

    /// GitHub's new issue page for the data this version doesn't know, filled in with this app's and this Mac's versions
    func unknownIssueReport() -> URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return IssueReport.unknownData(unknownData, appVersion: appVersion,
                                       macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    /// At a station whose operator's new data hasn't been used for `DataChangeLog.longHeldDays`: the same line as in its Data
    /// source row. Every operator of the station counts (a big station can be several companies'): with more than one held that
    /// long, one line each after its name, as in a row of several operators. None with no station (a station's own operators
    /// only) and in Demo mode (its stations are made up)
    func heldLongLines(at station: BoardStation?, now: Date) -> [String] {
        guard !isDemo, let station else { return [] }
        var keys: [String] = []
        for id in station.stations.isEmpty ? [station.id] : station.stations.map(\.id) {
            if let key = DataChangeLog.key(station: id, mode: system), !keys.contains(key) { keys.append(key) }
        }
        let held = keys.filter { dataChanges.entries[$0]?.isHeldLong(now: now) == true }
        if held.count == 1 { return dataNotUsedLine(held[0]).map { [$0] } ?? [] }
        return dataNotUsedLines(held.map { (key: $0, name: dataOperatorName($0)) })
    }

    /// The same for a row of several operators (Other bus companies): one line each, after its name
    func dataNotUsedLines(_ names: [(key: String, name: String)]) -> [String] {
        names.compactMap { item in dataNotUsedLine(item.key).map { l10n.labeled(item.name, $0) } }
    }

    /// GitHub's new issue page for an operator's data that wasn't used, filled in with this app's and this Mac's versions
    func issueReport(_ entry: DataChangeLog.Entry) -> URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return IssueReport.dataProblem(entry, appVersion: appVersion,
                                       macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    /// Where What Changed looks for changes near the user's own places: the favorites and the commute presets' places, and how
    /// far from them (the walking range's radius)
    var dataChangePlaces: (points: [Coordinate], meters: Double) {
        let points = SharedStore.favoritePlaces.map(\.coordinate) + SharedStore.commutePresets.compactMap { $0.place?.coordinate }
        return (points, effectiveSettings.sanitized().extendedCandidateRadiusMeters)
    }
}

/// What Changed, opened by Show Changes… in the Timetables and stations row: one mode's operators whose last update changed stops
/// or lines, the latest first, each with its day and its changes (an operator's new data taken after a week says so); at the top,
/// on their own, the changes near the user's own places (TransitModel.dataChangePlaces). Only stops and lines are compared, and it says so
struct DataChangesSheet: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.dismiss) private var dismiss
    /// The entries with changes, the latest first (DataChangeLog.News.changed)
    let entries: [DataChangeLog.Entry]

    var body: some View {
        let l = transit.l10n
        let places = transit.dataChangePlaces
        let near = entries.compactMap { entry -> Near? in
            let changes = entry.changes.near(places.points, within: places.meters)
            return changes.isEmpty ? nil : Near(key: entry.key, changes: changes)
        }
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("What Changed"))
                .font(.scaled(.title3).bold())
                .accessibilityAddTraits(.isHeader)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if !near.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(l.t("Near your places"))
                                .font(.scaled(.headline))
                                .accessibilityAddTraits(.isHeader)
                            ForEach(near) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(transit.dataOperatorName(item.key)).font(.scaled(.callout).weight(.semibold))
                                    DataChangeLines(changes: item.changes, l: l)
                                }
                            }
                        }
                        Divider()
                    }
                    ForEach(entries, id: \.key) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transit.dataOperatorName(entry.key))
                                .font(.scaled(.headline))
                                .accessibilityAddTraits(.isHeader)
                            Text(l.f("Updated on %@", l.day(entry.checkedAt, timeZone: l.macZone)))
                                .font(.scaled(.caption))
                                .foregroundStyle(.secondary)
                            if entry.outcome == .takenAfterWaiting {
                                Text(l.t("Used after a week: the same data kept coming."))
                                    .font(.scaled(.caption))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            DataChangeLines(changes: entry.changes, l: l)
                            // The lists were cut to what is kept (DataChangeLog.listLimit): the count of the rest
                            let more = entry.count - entry.changes.count
                            if more > 0 {
                                Text(l.f("More not shown: %@", l.number(Double(more))))
                                    .font(.scaled(.callout))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 320 * TextScale.factor)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            .contrastBorder(cornerRadius: 8)
            Text(l.t("Only stops and lines are compared, not departure times."))
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(l.t("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .appButtonStyle(.defaultAction)
            }
        }
        .font(.scaled(.body))
        .padding(20)
        .frame(width: 460 + 200 * (TextScale.factor - 1))
        .environment(\.locale, transit.language.locale)
        .environment(\.layoutDirection, transit.layoutDirection)
        .onExitCommand { dismiss() }
    }

    /// An operator's changes near the user's own places
    private struct Near: Identifiable {
        let key: String
        let changes: DataChanges
        var id: String { key }
    }
}

/// An operator's changes in What Changed, one line each: new stops, stops gone, renamed stops, new lines, lines gone (each with
/// the stops that went with it, under it), renamed lines. A rename says the old name, then the new one, in words (an arrow is
/// read out as "right arrow")
struct DataChangeLines: View {
    let changes: DataChanges
    let l: UIText

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(changes.addedStops, id: \.id) { Text(l.f("New stop: %@", $0.name)) }
            ForEach(changes.removedStops, id: \.id) { Text(l.f("Stop no longer listed: %@", $0.name)) }
            ForEach(changes.renamedStops, id: \.id) { Text(l.f("Stop renamed: %1$@, now %2$@", $0.from, $0.to)) }
            ForEach(changes.addedRoutes, id: \.id) { Text(l.f("New line: %@", $0.name)) }
            ForEach(changes.removedRoutes, id: \.route.id) { lost in
                Text(l.f("Line no longer listed: %@", lost.route.name))
                if !lost.stops.isEmpty {
                    Text(l.f("Its stops no longer listed: %@", l.commaList(lost.stops.map(\.name))))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                }
            }
            ForEach(changes.renamedRoutes, id: \.id) { Text(l.f("Line renamed: %1$@, now %2$@", $0.from, $0.to)) }
        }
        .font(.scaled(.callout))
        .fixedSize(horizontal: false, vertical: true)
    }
}

