import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// A row in Settings → Data source: icon, name and a line of small text on the left, an optional button on the right, and a "Live" or "Timetable" badge at the far right.
/// Badge at the right of a Data source row. "Checking" and "Not checked yet" are for keys and accounts that haven't been confirmed yet.
enum SourceBadge {
    case live, timetable, checking, notChecked

    /// Badge for a key or account row: "Live" only after it worked
    static func credential(has: Bool, refused: Bool, check: CredentialCheck?) -> SourceBadge? {
        guard has else { return nil }
        if refused || check == .rejected { return .timetable }
        switch check {
        case .works?: return .live
        case .checking?: return .checking
        default: return .notChecked
        }
    }

    /// Badge of an NJ Transit operator's row: "Timetable" where the account doesn't make its times live (liveWithAccount),
    /// without an account or when refused; "Live" only after the account worked
    static func njTransit(liveWithAccount: Bool, has: Bool, refused: Bool, check: CredentialCheck?) -> SourceBadge {
        guard liveWithAccount else { return .timetable }
        return credential(has: has, refused: refused, check: check) ?? .timetable
    }
}

/// A data source's mark: "Live", "Timetable", or how the check of a key stands. At the end of Settings' data source rows and of the
/// rows in the sidebar header's popover
struct SourceBadgeLabel: View {
    var badge: SourceBadge
    var l: UIText

    var body: some View {
        let color: Color = badge == .live ? .noticeGreen : badge == .notChecked ? .noticeOrange : .secondary
        Text(badge == .live ? l.t("Live") : badge == .timetable ? l.t("Timetable")
                 : badge == .checking ? l.t("Checking…") : l.t("Not checked yet"))
            .font(.scaled(.caption2).weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .fixedSize()
    }
}

struct SourceRow<Trailing: View>: View {
    @EnvironmentObject var transit: TransitModel
    typealias Badge = SourceBadge
    let icon: String
    let name: String
    /// A line under the name before the detail, always gray (a key's "For: …", see AccountKeyRow)
    var about: String? = nil
    var detail: String? = nil
    var detailColor: Color = .secondary
    /// Operators' own problems, one each: the reason, and after 14 days since when, with Check for Updates… (see OperatorProblemLines)
    var problems: [NetworkReach.Notice] = []
    /// While the operator's new data isn't used (DataChangeLog): since when, in orange (see TransitModel.dataNotUsedLine)
    var notUsed: [String] = []
    /// While its data has what this version doesn't know (UnknownData), in gray (see TransitModel.dataPartlyKnownLine)
    var partlyKnown: String? = nil
    /// Notes under the name, one per line, each after a "*" in a column of its own: a wrapped line starts under its text, not under
    /// the "*" (the "Known issues" row)
    var notes: [String] = []
    var badge: Badge? = nil
    /// Adds "*" next to the badge: explained in the "Known issues" row below
    var footnote = false
    /// The Keychain couldn't read this key: a retry line under the name (see KeychainRetryLine)
    var keychainRetry: Credential? = nil
    /// A small button under the lines (Timetables and stations' Show Changes…)
    var action: SourceRowAction? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let l = transit.l10n
        // The icon and what is on the right (the badge, a button) line up with the name, not with the middle of the row: a long
        // explanation under the name would otherwise take them far from it
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // The name and the lines that say what it is, read together before what is on the right: a screen reader went from
                // the name to the button there (they are on one line), then back for the rest
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    if let about, !about.isEmpty {
                        Text(about)
                            .font(.scaled(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail {
                        Text(detail)
                            .font(.scaled(.caption))
                            .foregroundStyle(detailColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                ForEach(problems, id: \.self) { n in
                    OperatorProblemLines(notice: n)
                }
                ForEach(notUsed, id: \.self) { line in
                    Text(line)
                        .font(.scaled(.caption))
                        .foregroundStyle(Color.noticeOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let partlyKnown {
                    Text(partlyKnown)
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: "*").accessibilityHidden(true)
                        Text(note).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.scaled(.caption))
                    .foregroundStyle(detailColor)
                }
                if let keychainRetry {
                    KeychainRetryLine(credential: keychainRetry)
                        .font(.scaled(.caption))
                }
                if let action {
                    Button(action.title, action: action.run)
                        .appButtonStyle()
                        .controlSize(.small)
                        .fixedSize()
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            trailing
            if let badge {
                SourceBadgeLabel(badge: badge, l: l)
                if footnote {
                    Text(verbatim: "*")
                        .font(.scaled(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

extension SourceRow where Trailing == EmptyView {
    init(icon: String, name: String, detail: String? = nil, detailColor: Color = .secondary, problems: [NetworkReach.Notice] = [],
         notUsed: [String] = [], partlyKnown: String? = nil, notes: [String] = [], badge: Badge? = nil, footnote: Bool = false) {
        self.init(icon: icon, name: name, detail: detail, detailColor: detailColor, problems: problems, notUsed: notUsed,
                  partlyKnown: partlyKnown, notes: notes, badge: badge, footnote: footnote) { EmptyView() }
    }
}

/// A small button under a Data source row's lines: its title and what it does
struct SourceRowAction {
    let title: String
    let run: () -> Void
}

/// An operator's own problem in its Settings row: the reason, in the same words as at its stations, and once it has lasted 14 days,
/// since when (see LongProblemLine)
struct OperatorProblemLines: View {
    @EnvironmentObject var transit: TransitModel
    let notice: NetworkReach.Notice

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(transit.l10n.reachText(notice))
                .foregroundStyle(Color.noticeOrange)
                .fixedSize(horizontal: false, vertical: true)
            LongProblemLine(provider: notice.provider)
        }
        .font(.scaled(.caption))
    }
}

/// "Not working since …" with Check for Updates…, once an operator's own problem has lasted 14 days (NetworkReach.longProblemSince):
/// at its stations' notice and in its Settings row. The button does what the app menu's item does: checks for a new version once
/// (a new version may read the data again) and opens Settings to show the result. Automatic checks stay as they are
struct LongProblemLine: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openSettings) private var openSettings
    let provider: String
    var now = Date()

    var body: some View {
        if let since = NetworkReach.longProblemSince(provider, now: now) {
            let l = transit.l10n
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(l.f("Not working since %@.", l.day(since, timeZone: l.macZone)))
                        .foregroundStyle(Color.noticeOrange)
                        .fixedSize(horizontal: false, vertical: true)
                    // Checks, then opens Settings at Updates to show the result; on standby Start in its place
                    CheckOrStartButton(title: l.t("Check for Updates…"), small: true) {
                        transit.checkForUpdates()
                        SettingsJump.to(.updates)
                        NSApp.activate()
                        openSettings()
                    }
                    .fixedSize()
                }
                // Why the button is grayed out, where it shows
                if let reason = transit.checkOnlineReason {
                    Text(reason)
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Timetable data rows in Settings → Data source: one per provider (all free, no key needed); the last row shows when it was checked, with an option to check now.
/// For subway, PATH and light rail are two datasets checked together; for buses, each agency with realtime data gets a row and the rest share one ("Other bus companies").
struct FerrySourceRows: View {
    @EnvironmentObject var transit: TransitModel
    let systems: [TransitSystem]
    /// Only the operators with stations in this metro area get a row; nil: all
    let area: MetroArea?
    private let stores: [FerryStore]
    @State private var checking = false
    @State private var failed = false
    @State private var lastChecked: Date?
    /// What Changed is open (Show Changes…)
    @State private var showChanges = false
    /// Providers whose timetables have run out (e.g. the Statue of Liberty ferry between seasons): the landing is hidden for now, and this says there's no timetable now and it's checked daily
    @State private var idle: Set<FerryFeed.Source> = []
    /// Providers whose timetables are about to run out (a train timetable within a few days, since LIRR's only go a few weeks out,
    /// or any timetable within the next week): checked daily
    @State private var ending: Set<FerryFeed.Source> = []

    init(systems: [TransitSystem], area: MetroArea? = nil) {
        let stores = systems.map { FerryStore.store(for: $0) }
        self.systems = systems
        self.area = area
        self.stores = stores
        _lastChecked = State(initialValue: stores.compactMap { $0.lastChecked }.min())
    }

    /// The timetable data sets of a mode's Settings page: for subway, PATH's and light rail's (MTA's own data is checked separately)
    static func systems(of mode: TransitSystem) -> [TransitSystem] {
        switch mode.mode {
        case .subway: return [.path, .lightRail]
        case .bus: return [.njBus]
        case .ferry: return [.ferry]
        default: return [.train]
        }
    }

    /// Whether any operator of these data sets has stations in the area
    static func hasRows(systems: [TransitSystem], area: MetroArea) -> Bool {
        if systems == [.njBus] { return RegionalBusFeed.all.contains { MetroArea.areas(ofBus: $0).contains(area) } }
        return systems.flatMap { FerryStore.store(for: $0).sources }.contains { MetroArea.areas(of: $0).contains(area) }
    }

    private func inArea(_ source: FerryFeed.Source) -> Bool { area.map { MetroArea.areas(of: source).contains($0) } ?? true }
    private func inArea(_ feed: RegionalBusFeed) -> Bool { area.map { MetroArea.areas(ofBus: feed).contains($0) } ?? true }

    private var isBus: Bool { systems == [.njBus] }
    /// The subway page's rows: only PATH and light rail data is checked here (MTA's own data is checked separately), so the row says so
    private var isPathAndLightRail: Bool { systems.contains(.path) }

    var body: some View {
        let l = transit.l10n
        // An operator's own problem is said in its row (one each in the shared row of the bus companies without live data)
        let problems = transit.operatorProblems()
        if isBus {
            // One row per company with realtime data (NJ Transit needs an account; CTtransit, Bee-Line are free); the timetable-only rest share one row
            ForEach(RegionalBusFeed.all.filter { $0.hasRealtime && inArea($0) }, id: \.code) { feed in
                if feed.needsAccount {
                    SourceRow(icon: "key", name: l.t("NJ Transit buses"), detail: busAccountDetail(l),
                              detailColor: feed.liveWithAccount && transit.njTransitBusRejected ? .noticeRed : .secondary,
                              problems: problems[feed.name].map { [$0] } ?? [],
                              notUsed: transit.dataNotUsedLine(DataChangeLog.key(bus: feed.code)).map { [$0] } ?? [],
                              badge: njTransitBadge(.njTransitBus, liveWithAccount: feed.liveWithAccount,
                                                    refused: transit.njTransitBusRejected))
                } else if feed.needsKey {
                    // Suffolk County Transit: realtime data needs a key the user requests from Swiftly
                    SuffolkKeyRow(feed: feed)
                } else {
                    // When the download fails (e.g. Bee-Line's server returns 503), say the timetable is in use instead of showing "Live"
                    // The operator's own problem, so no orange note: the badge says "Timetable" and the gray line why (a known issue
                    // keeps "Free, no key needed": its own row at the bottom says why)
                    let down = transit.busRealtimeFailed.contains(feed.code)
                    let known = TransitModel.developerOnlyProviders.contains(feed.name)
                    SourceRow(icon: "dot.radiowaves.left.and.right", name: feed.name,
                              detail: !feed.isWanted ? l.t("Downloaded only once you use a place in its area.")
                                  : down && !known ? l.f("Couldn't get %@ live data. Showing timetable times for now.", feed.name)
                                  : l.t("Free, no key needed"),
                              detailColor: .secondary, problems: problems[feed.name].map { [$0] } ?? [],
                              notUsed: transit.dataNotUsedLine(DataChangeLog.key(bus: feed.code)).map { [$0] } ?? [],
                              badge: down ? .timetable : .live,
                              footnote: down && known)
                }
            }
            // Only this area's companies; no row when it has none
            let otherFeeds = RegionalBusFeed.all.filter { !$0.hasRealtime && $0.code != "SCT" && inArea($0) }
            let others = otherFeeds.map(\.name)
            // Suffolk's row is about its key: a problem with its timetable is said here, with the others'
            let shared = otherFeeds + RegionalBusFeed.all.filter { $0.needsKey && inArea($0) }
            let sharedProblems = shared.map(\.name).compactMap { problems[$0] }
            // New data not used: one line each, after the company's name
            let sharedNotUsed = transit.dataNotUsedLines(shared.map { (key: DataChangeLog.key(bus: $0.code), name: $0.name) })
            if !others.isEmpty || !sharedProblems.isEmpty || !sharedNotUsed.isEmpty {
                SourceRow(icon: "bus", name: l.t("Other bus companies"),
                          detail: others.isEmpty ? l.t("No live data is published.") : l.commaList(others) + " · " + l.t("No live data is published."),
                          problems: sharedProblems, notUsed: sharedNotUsed, badge: .timetable)
            }
            // Known issues: the provider's own problems the app can't fix (Bee-Line's realtime server keeps erroring), placed at the bottom in gray text,
            // and not flagged in the main window, menu bar or widgets. The "Timetable" in the row above has a "*"
            let known = RegionalBusFeed.all.filter { feed in
                inArea(feed) && TransitModel.developerOnlyProviders.contains(feed.name) && transit.busRealtimeFailed.contains(feed.code)
            }
            if !known.isEmpty {
                SourceRow(icon: "info.circle", name: l.t("Known issues"),
                          notes: known.map { l.f("%@: its live data server keeps returning errors. This can't be fixed in the app for now, so its times come from the timetable.", $0.name) })
            }
        } else {
            ForEach(stores.flatMap { $0.sources }.filter(inArea), id: \.self) { source in
                if source.liveWithAccount {
                    // NJ Transit's trains: like MTA Bus Time, realtime data once you enter your own developer account (under Keys and
                    // accounts above, see AccountKeyRow), otherwise the timetable. Its light rail, which the account doesn't make
                    // live, is a timetable row like any other below
                    SourceRow(icon: "key", name: source.name, detail: accountDetail(source, l),
                              detailColor: transit.njTransitRejected ? .noticeRed : .secondary,
                              problems: problems[source.name].map { [$0] } ?? [],
                              notUsed: transit.dataNotUsedLine(source.rawValue).map { [$0] } ?? [],
                              partlyKnown: transit.dataPartlyKnownLine(source.rawValue),
                              badge: njTransitBadge(.njTransitRail, liveWithAccount: source.liveWithAccount,
                                                    refused: transit.njTransitRejected))
                } else {
                    SourceRow(icon: source.hasRealtime ? "dot.radiowaves.left.and.right" : "calendar", name: source.name,
                              detail: !source.isWanted ? l.t("Downloaded only once you use a place in its area.")
                                  : idle.contains(source) ? l.t("No current timetable · checked daily")
                                  : ending.contains(source) ? l.t("Timetable ending soon · checked daily")
                                  : source == .path ? l.t("Live times only. Stations come from its last timetable.")
                                  : source.hasRealtime ? l.t("Free, no key needed") : nil,
                              problems: problems[source.name].map { [$0] } ?? [],
                              notUsed: transit.dataNotUsedLine(source.rawValue).map { [$0] } ?? [],
                              partlyKnown: transit.dataPartlyKnownLine(source.rawValue),
                              badge: source.hasRealtime ? .live : .timetable)
                }
                // CTrail's Shore Line East: a line of its own, its timetable in Amtrak's package
                if source == .amtrakNY, ModeCoverage.listsShoreLineEast(in: area) {
                    SourceRow(icon: "calendar", name: ModeCoverage.shoreLineEast, badge: .timetable)
                }
            }
        }
        // What the latest update of this mode's data changed (DataChangeLog): its day, how many changes, and Show Changes…
        let news = transit.dataChanges.news(of: changeKeys)
        SourceRow(icon: "arrow.triangle.2.circlepath",
                  name: l.t("Timetables and stations"),
                  detail: [failed ? failedText(l) : checkedText(l, kept: news.kept), latestUpdateText(news, l),
                           checking ? nil : transit.checkOnlineReason]
                      .compactMap { $0 }.joined(separator: "\n"),
                  detailColor: failed ? .noticeRed : .secondary,
                  action: news.changed.isEmpty ? nil : SourceRowAction(title: l.t("Show Changes…")) { showChanges = true }) {
            if checking {
                ProgressView().controlSize(.small)
            } else {
                CheckOrStartButton(title: l.t("Check Timetables Now")) { check() }
            }
        }
        .task { await loadIdle() }
        .sheet(isPresented: $showChanges) {
            DataChangesSheet(entries: news.changed)
                .environmentObject(transit)
        }
        // Where the app downloads each operator's data (see SourceList): what the list is, written under the name (a hover tip
        // shows only after a while), then the day the list in use was changed and when the app last got the repository's copy
        let list = SourceList.current.list
        let dates = list.updatedDay.map { updated in
            SourceListStore.lastChecked.map { l.f("Updated %@, checked %@", l.day(updated, timeZone: l.macZone), l.day($0, timeZone: l.macZone)) }
                ?? l.f("Updated %@, not checked yet", l.day(updated, timeZone: l.macZone))
        }
        let about = l.t("Where the app downloads each operator's data, and the stations without times. It can change without an app update.")
        SourceRow(icon: "list.bullet.rectangle", name: l.t("Source list"),
                  detail: [about, dates].compactMap { $0 }.joined(separator: "\n"))
    }

    /// The keys of this mode's operators in the log of data checks (DataChangeLog): its timetables', and on the subway's and the
    /// buses' pages MTA's station list too. For the whole mode, like Check Timetables Now
    private var changeKeys: Set<String> {
        if isBus { return Set([DataChangeLog.cityBusKey] + RegionalBusFeed.all.map { DataChangeLog.key(bus: $0.code) }) }
        var keys = Set(stores.flatMap { $0.sources }.map(\.rawValue))
        if isPathAndLightRail { keys.insert(DataChangeLog.subwayKey) }
        return keys
    }

    /// "Latest update …, no changes" or "…, changes: N", once an update of this mode's data was checked; nil before
    private func latestUpdateText(_ news: DataChangeLog.News, _ l: UIText) -> String? {
        guard let latest = news.latest else { return nil }
        let day = l.day(latest, timeZone: l.macZone)
        return news.count == 0 ? l.f("Latest update %@, no changes", day)
            : l.f("Latest update %1$@, changes: %2$@", day, l.number(Double(news.count)))
    }

    /// The day these timetables are up to date as of (the earliest operator's last good download, see FerryStore.upToDate), and the
    /// next monthly check: never a day gone by, also while an operator keeps failing (it's tried again meanwhile, see MonthlyCheck).
    /// With operators whose new data isn't used (`kept`): up to date except them (their day leaves the others' out), and the next
    /// check is when the first of them is downloaded again (DataChangeLog.recheckHours), not next month
    private func checkedText(_ l: UIText, kept: [DataChangeLog.Entry] = []) -> String {
        let keptKeys = Set(kept.map { $0.key.hasPrefix("bus:") ? String($0.key.dropFirst(4)) : $0.key })
        let dates = stores.map { kept.isEmpty ? $0.upToDate : $0.upToDate(of: $0.operatorKeys.subtracting(keptKeys)) }
        let retry = kept.map { $0.checkedAt.addingTimeInterval(Double(DataChangeLog.recheckHours) * 3600) }.min()
        let next = l.day(retry.map { max($0, Date()) } ?? DownloadDates.nextCheck(), timeZone: l.macZone)
        if !dates.contains(where: { $0 == nil }), let day = dates.compactMap({ $0 }).min() {
            if !kept.isEmpty {
                let names = l.joinedList(kept.map { transit.dataOperatorName($0.key) })
                return l.f("Up to date as of %1$@ except %2$@, next check %3$@", l.day(day, timeZone: l.macZone), names, next)
            }
            return l.f("Up to date as of %@, next check %@", l.day(day, timeZone: l.macZone), next)
        }
        return lastChecked.map { l.f("Last checked %@, next check %@", l.day($0, timeZone: l.macZone), next) }
            ?? l.t("Downloaded the first time you turn the app on.")
    }

    /// Check Timetables Now got nothing: the network, or the operators' own problems in the short form (each one's own row says more)
    private func failedText(_ l: UIText) -> String {
        let network = isPathAndLightRail ? l.t("Couldn't download the subway and light rail data. Check your network.")
            : l.t("Couldn't download. Check your network.")
        return l.downloadFailedText(network, problems: TransitModel.timetableNotices(systems), short: true)
    }

    /// NJ Transit badge: "Timetable" where the account doesn't make that operator's times live, without an account or when
    /// refused; "Live" only after the account worked (see SourceBadge.njTransit)
    private func njTransitBadge(_ credential: Credential, liveWithAccount: Bool, refused: Bool) -> SourceBadge {
        SourceBadge.njTransit(liveWithAccount: liveWithAccount, has: transit.hasNJTransitAccount, refused: refused,
                              check: transit.credentialChecks[credential])
    }

    /// Small text in the NJ Transit rail row: whether the account above gives live times (situations like an
    /// expired timetable take priority). How the account stands is said in its own row (see AccountKeyRow)
    private func accountDetail(_ source: FerryFeed.Source, _ l: UIText) -> String {
        if idle.contains(source) { return l.t("No current timetable · checked daily") }
        if !transit.hasNJTransitAccount { return l.t("Live times need your free NJ Transit account (above). Using the timetable for now.") }
        if transit.njTransitRejected { return l.t("NJ Transit didn't accept your account (above). Using the timetable for now.") }
        return l.t("Live times with your NJ Transit account (above).")
    }

    /// Small text in the NJ Transit bus row: the same, for the buses
    private func busAccountDetail(_ l: UIText) -> String {
        let uses = l.t("Uses your NJ Transit account (above). Live where NJ Transit provides it, otherwise the timetable.")
        if !RegionalBusFeed.njTransit.liveWithAccount { return uses }
        if !transit.hasNJTransitAccount { return l.t("Live times need your free NJ Transit account (above). Using the timetable for now.") }
        if transit.njTransitBusRejected { return l.t("NJ Transit didn't accept your account (above). Using the timetable for now.") }
        return uses
    }

    /// Looks at stored data to see which providers have no timetable now and which are about to run out (offline). Released after reading when this data isn't in use, to save memory.
    private func loadIdle() async {
        var newIdle: Set<FerryFeed.Source> = []
        var newEnding: Set<FerryFeed.Source> = []
        let now = Date()
        for store in stores where !store.isIndexed {
            // Use the stored small summary first (no need to load the whole timetable into memory); read once only if missing (reading saves it)
            if let coverage = await store.coverage(now: now) {
                newIdle.formUnion(coverage.idleSources(from: now))
                newEnding.formUnion(coverage.endingSources(from: now).union(coverage.endingSoonSources(from: now)))
                continue
            }
            let feed = await store.load()
            newIdle.formUnion(feed?.idleSources(from: now) ?? [])
            newEnding.formUnion(feed.map { $0.endingSources(from: now).union($0.endingSoonSources(from: now)) } ?? [])
            if !transit.system.timetableSystems.contains(store.system) { await store.release() }
        }
        idle = newIdle
        ending = newEnding
    }

    private func check() {
        checking = true
        failed = false
        // The places in use now: the operators downloaded only for places in their area are checked once one is there
        transit.notePlacesInUse()
        Task {
            // The source list first: a moved address is used by this check
            await transit.checkSourceListNow()
            for store in stores {
                do {
                    _ = try await store.update()
                } catch {
                    // Stopped by standby (or refused there): not a failed download
                    if !NetworkReach.isCancellation(error) { failed = true }
                }
            }
            if transit.system.timetableSystems.contains(where: { systems.contains($0) }) { transit.refresh() }
            lastChecked = stores.compactMap { $0.lastChecked }.min()
            await loadIdle()
            checking = false
        }
    }
}
