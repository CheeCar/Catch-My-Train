import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// "Downloaded data" in Settings: each metro area's data on this Mac, why it stays and what it takes, with Remove…; the data of
/// operators in several areas; all of it, with Delete Downloaded Data… (see AreaData and DownloadedData)
struct DownloadedDataSettings: View {
    @EnvironmentObject var transit: TransitModel
    @State private var sizes: [DownloadedData.Part: Int64] = [:]
    @State private var reasons: [MetroArea: AreaData.Reason] = [:]
    @State private var removing: MetroArea?
    @State private var confirmDelete = false
    /// The full list of areas is open (Show All…)
    @State private var showAll = false
    /// The area whose Remove… was clicked in the full list: it asks there, over the list
    @State private var removingInList: MetroArea?

    struct Row: Identifiable, Equatable {
        let area: MetroArea
        let reason: AreaData.Reason?
        /// Its own operators' data (an operator in several areas counts in the shared row); nil: none, or removed by the user
        let size: Int64?
        var id: MetroArea { area }
    }

    var body: some View {
        let l = transit.l10n
        let shown = Self.shown(sizes: sizes, reasons: reasons)
        // With more areas than AreaList.shownAtOnce, only that many have a row here; the others share one, with Show All…
        let folded = Self.folded(shown.rows)
        Section {
            ForEach(folded.listed) { row in
                areaRow(Self.item(row, l), l) { removing = $0 }
            }
            if !folded.others.isEmpty {
                let othersSize = folded.others.compactMap(\.size).reduce(0, +)
                SourceRow(icon: "ellipsis.circle", name: l.f("Other areas: %@", l.number(Double(folded.others.count)))) {
                    if othersSize > 0 {
                        Text(Self.size(othersSize, l)).font(.scaled(.caption)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button(l.t("Show All…")) { showAll = true }
                        .appButtonStyle()
                }
            }
            if shown.shared > 0 {
                SourceRow(icon: "square.stack.3d.up", name: l.t("Shared by several areas"),
                          detail: l.t("Companies that run in more than one area, such as Amtrak. Kept while one of their areas is kept.")) {
                    Text(Self.size(shown.shared, l)).font(.scaled(.caption)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            // The button at the end of the text's line, or under the text (still at the end) when beside it the text would keep
            // less than about half the row: larger text, a long language. Its words then stay on one line
            NameAndKindsLayout(spacing: 12) {
                Text(l.f("All downloaded data: %@", Self.size(shown.total, l)))
                    .fixedSize(horizontal: false, vertical: true)
                Button(l.t("Delete Downloaded Data…")) { confirmDelete = true }
                    .appButtonStyle()
                    .disabled(transit.isActive || !transit.networkAllowed)
            }
            // Settings can be opened at this row (SettingsJump)
            .id(SettingsJump.Target.downloadedTotal.id)
            // The full list (Show All…) hangs on this row, the one that is always there: every area with its data, the ones
            // taking the most first, each with its Remove…, which asks over the list; a search field finds an area by name
            .sheet(isPresented: $showAll) {
                AreaListSheet(title: l.t("Downloaded data"), items: listItems(folded.all, l)) { item in
                    areaRow(item, l) { removingInList = $0 }
                        .padding(.horizontal, AreaListRow.sidePadding)
                        .padding(.vertical, AreaListRow.edgePadding)
                }
                .modifier(RemoveAreaAlert(area: $removingInList, reasons: reasons, l: l, remove: remove))
                .environmentObject(transit)
            }
            // Why the button is off, where it is, not only in a tooltip
            if let blocked = deleteBlocked(l) {
                Text(blocked).font(.scaled(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = transit.deleteError {
                Text(error).font(.scaled(.caption)).foregroundStyle(Color.noticeRed).fixedSize(horizontal: false, vertical: true)
            }
            // Deleted, but restarting failed: said under the button that restarts, not only on the General page
            if let error = transit.relaunchError {
                Text(error).font(.scaled(.caption)).foregroundStyle(Color.noticeRed).fixedSize(horizontal: false, vertical: true)
            }
            Text(l.t("An area is kept while your starting point or a favorite is in it. Other areas are removed 30 days after you last used them, and downloaded again when you need them."))
                .font(.scaled(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(l.t("Downloaded data"))
                .settingsSectionTitle()
                .id(SettingsJump.Target.downloadedData.id)
        }
        .task { await load() }
        .modifier(RemoveAreaAlert(area: $removing, reasons: reasons, l: l, remove: remove))
        .alert(l.t("Delete downloaded data?"), isPresented: $confirmDelete) {
            Button(l.t("Cancel"), role: .cancel) {}
            Button(l.t("Delete and Restart"), role: .destructive) { transit.deleteDownloadedData() }
        } message: {
            Text(l.t("Catch My Train restarts. Only your starting point's area is downloaded again right away; other areas when you choose a place in them."))
        }
    }

    /// An area's row, here and in the full list: its name, why its data stays, what it takes and Remove… (not for one the user
    /// removed; off for the starting point's and Plan a Trip's areas)
    private func areaRow(_ item: AreaListItem, _ l: UIText, remove: @escaping (MetroArea?) -> Void) -> some View {
        SourceRow(icon: "internaldrive", name: item.name, detail: item.detail) {
            if let size = item.size, size > 0 {
                Text(Self.size(size, l)).font(.scaled(.caption)).foregroundStyle(.secondary).monospacedDigit()
            }
            if item.reason != .removedByYou {
                // Screen readers hear which area too: every row has this button
                Button(l.t("Remove…")) { remove(item.area) }
                    .appButtonStyle()
                    .disabled(!(item.reason?.canRemove ?? true))
                    .accessibilityLabel(Text(l.t("Remove…") + l.comma + item.name))
            }
        }
    }

    /// A row as the full list has it: found by the area's own name, its regions' and its states'
    static func item(_ row: Row, _ l: UIText) -> AreaListItem {
        AreaListItem(id: row.area.rawValue, area: row.area, name: l.metroAreaName(row.area),
                     detail: reasonText(row.reason, area: row.area, l), size: row.size, reason: row.reason,
                     searchNames: row.area.searchNames { l.t($0) })
    }

    /// The full list's rows
    private func listItems(_ rows: [Row], _ l: UIText) -> [AreaListItem] {
        return rows.map { Self.item($0, l) }
    }

    /// The rows listed one by one, the others (which share a row), and all of them in the full list's order: the starting
    /// point's and Plan a Trip's areas, then the ones taking the most (AreaList.folded, AreaList.bySize)
    static func folded(_ rows: [Row]) -> (listed: [Row], others: [Row], all: [Row]) {
        let stored = rows.map { AreaList.Stored(id: $0.area, reason: $0.reason, size: $0.size) }
        func row(_ area: AreaList.Stored<MetroArea>) -> Row { Row(area: area.id, reason: area.reason, size: area.size) }
        let folded = AreaList.folded(stored)
        return (folded.listed.map(row), folded.others.map(row), AreaList.bySize(stored).map(row))
    }

    private func deleteBlocked(_ l: UIText) -> String? {
        if transit.isActive { return l.t("Go on standby first.") }
        if !transit.networkAllowed { return l.t("Turn on “Allow network” first, so the data can be downloaded again.") }
        return nil
    }

    private func load() async {
        reasons = DownloadedData.reasons()
        sizes = await DownloadedData.sizes()
    }

    private func remove(_ area: MetroArea) {
        let l = transit.l10n
        Task {
            let ok = await DownloadedData.removeArea(area)
            transit.deleteError = ok ? nil : l.t("Some downloaded data couldn't be deleted. Quit Catch My Train and try again.")
            await load()
        }
    }

    /// The rows: each area with its own data, and the starting point's, Plan a Trip's and removed areas even without; the starting
    /// point's first, then Plan a Trip's, the favorites', the unused ones, the removed ones. And the shared and total sizes
    static func shown(sizes: [DownloadedData.Part: Int64], reasons: [MetroArea: AreaData.Reason]) -> (rows: [Row], shared: Int64, total: Int64) {
        let (own, shared, total) = AreaData.split(sizes.map { (areas: $0.key.areas, size: $0.value) })
        func rank(_ reason: AreaData.Reason?) -> Int {
            switch reason {
            case .start?: return 0
            case .planner?: return 1
            case .favorites?: return 2
            case .unused?: return 3
            case nil: return 4
            case .removedByYou?: return 5
            }
        }
        let listed = MetroArea.allCases.filter { area in
            let reason = reasons[area]
            return (own[area] ?? 0) > 0 || reason == .start || reason == .planner || reason == .removedByYou
        }
        let rows = listed.map { Row(area: $0, reason: reasons[$0], size: reasons[$0] == .removedByYou ? nil : own[$0]) }
            .enumerated().sorted { a, b in rank(a.element.reason) != rank(b.element.reason) ? rank(a.element.reason) < rank(b.element.reason) : a.offset < b.offset }
            .map(\.element)
        return (rows, shared, total)
    }

    /// Why an area's data is on this Mac; its days in the area's time zone (the app's own dates are in this Mac's)
    static func reasonText(_ reason: AreaData.Reason?, area: MetroArea, _ l: UIText) -> String? {
        switch reason {
        case .start?: return l.t("Your starting point is in this area.")
        case .planner?: return l.t("A Plan a Trip place is in this area.")
        case .favorites?: return l.t("Your favorites are in this area.")
        case .unused(let since, let until)?: return l.f("Not used since %@. Removed on %@ unless you use it again.", l.day(since, timeZone: area.timeZone),
                                             l.day(until, timeZone: area.timeZone))
        case .removedByYou?: return l.t("Removed by you. Downloaded again when you choose a place in this area.")
        case nil: return nil
        }
    }

    /// Megabytes, one decimal under 10 (never 0 for some data)
    static func size(_ bytes: Int64, _ l: UIText) -> String {
        let mb = Double(bytes) / 1_000_000
        let shown = mb < 10 ? max((mb * 10).rounded() / 10, bytes > 0 ? 0.1 : 0) : mb.rounded()
        return l.f("%@ MB", l.number(shown, fractionDigits: shown < 10 ? 1 : 0))
    }

}

/// Remove… asks first, whether it was clicked in Settings' Downloaded data or in its full list
private struct RemoveAreaAlert: ViewModifier {
    @Binding var area: MetroArea?
    let reasons: [MetroArea: AreaData.Reason]
    let l: UIText
    let remove: (MetroArea) -> Void

    func body(content: Content) -> some View {
        content.alert(area.map { l.f("Remove the data for %@?", l.metroAreaName($0)) } ?? "",
                      isPresented: Binding(get: { area != nil }, set: { if !$0 { area = nil } }), presenting: area) { area in
            Button(l.t("Cancel"), role: .cancel) {}
            Button(l.t("Remove"), role: .destructive) { remove(area) }
        } message: { area in
            Text(reasons[area] == .favorites
                 ? l.t("Your favorites and recent places in this area stay. Its data is downloaded again when you choose one of them.")
                 : l.t("It's downloaded again when you use a place in this area."))
        }
    }
}

/// A row of the full list of areas (AreaListSheet): an area, with what the list says under its name and the names its search
/// finds it by
struct AreaListItem: Identifiable {
    let id: String
    var area: MetroArea?
    let name: String
    /// Under the name: why its data stays (Downloaded data), or the states it is in (Data source)
    var detail: String?
    /// What its own operators' data takes, and why it stays (Downloaded data)
    var size: Int64?
    var reason: AreaData.Reason?
    /// Its own name, its regions' and its states', in the app's language and in English (MetroArea.searchNames)
    var searchNames: [String]
}

/// The full list of areas, for the two places in Settings a list of every area would get too long in (Downloaded data's Show
/// All… and the area menu's All Areas…): a title, a search field, the areas and Done (Cancel where one is chosen). Typing shows
/// only the areas whose name, regions or states have that text (AreaList.matches). The rows are the caller's, with their own
/// padding (AreaListRow), so a row that is one button is lit up and clicked from edge to edge. The search field has the keyboard
/// when the list opens; Return closes it (with `submit` and text in the field, it first hands over the first area found, as the
/// app's other search fields take their first suggestion), and so does Esc
struct AreaListSheet<Row: View>: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.dismiss) private var dismiss
    let title: String
    let items: [AreaListItem]
    var submit: ((AreaListItem) -> Void)? = nil
    @ViewBuilder var row: (AreaListItem) -> Row
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let l = transit.l10n
        let found = items.filter { AreaList.matches(search, names: $0.searchNames) }
        let field = RoundedRectangle(cornerRadius: 6)
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.scaled(.title3).bold())
                .accessibilityAddTraits(.isHeader)
            // A magnifying glass, then the text: one box, drawn like Plan a Trip's place field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(l.t("Search areas"), text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let submit, let first = found.first, !AreaList.searchKey(search).isEmpty { submit(first) }
                        dismiss()
                    }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(field.fill(Color(nsColor: .textBackgroundColor)))
            .overlay(field.strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
            .overlay {
                // The focus ring, outside the edge like the system's
                if searchFocused {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5), lineWidth: 3).padding(-2)
                }
            }
            // As tall with one row as with fifty, so the window doesn't jump while typing
            ScrollView(.vertical) {
                if found.isEmpty {
                    Text(l.f("No areas match “%@”.", search.trimmingCharacters(in: .whitespacesAndNewlines)))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(found.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.horizontal, 12) }
                            row(item)
                        }
                    }
                }
            }
            .frame(height: 300 * TextScale.factor)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            .contrastBorder(cornerRadius: 8)
            HStack {
                Spacer()
                // Choosing one (`submit`): Cancel, as the app's other lists to choose from; only looking: Done
                if submit != nil {
                    Button(l.t("Cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .appButtonStyle()
                } else {
                    Button(l.t("Done")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .appButtonStyle(.defaultAction)
                }
            }
        }
        // The rows' names follow the text size, as in the Settings window
        .font(.scaled(.body))
        .padding(20)
        .frame(width: 440 + 200 * (TextScale.factor - 1))
        .environment(\.locale, transit.language.locale)
        .environment(\.layoutDirection, transit.layoutDirection)
        .onExitCommand { dismiss() }
        .onAppear {
            searchFocused = true
        }
    }
}

/// The space around a row of the full list of areas: the same for the rows of both lists
enum AreaListRow {
    static let sidePadding: CGFloat = 12
    static let edgePadding: CGFloat = 8
}

/// An area in the full list where one is chosen: its name with the states it is in under it, and a checkmark before the one
/// Data source shows now. A click anywhere in the row chooses it. Under the pointer it lights up like a suggestion of the app's
/// search fields: blue with white text (its gray line a lighter white); screen readers hear the one shown now as selected
struct AreaChoiceRow: View {
    let item: AreaListItem
    let chosen: Bool
    let choose: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.scaled(.caption).weight(.semibold))
                    .opacity(chosen ? 1 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.scaled(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AreaListRow.sidePadding)
            .padding(.vertical, AreaListRow.edgePadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovered ? Color.white : Color.primary)
        .background {
            if hovered {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor).padding(.horizontal, 5).padding(.vertical, 2)
            }
        }
        .onHover { hovered = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

