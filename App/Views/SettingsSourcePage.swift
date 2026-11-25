import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// Settings, Data source page: how the sources are doing when something is wrong (DataStatusSettings), one metro area's keys,
/// accounts and operators, then the data downloaded to this Mac, then Demo mode.
struct SourceSettingsPage: View {
    @EnvironmentObject var transit: TransitModel
    /// Transit system selected in Data source (nil = same as the main window)
    @State private var sourceSystem: TransitSystem?
    /// Transit mode shown in data sources: the one chosen, or the one the main window is showing if none was chosen
    private var shownSource: TransitSystem { (sourceSystem ?? transit.system).mode }
    /// Metro area chosen in Data source (nil = the start place's area)
    @State private var sourceArea: MetroArea?
    /// The full list of areas is open (the area menu's All Areas…)
    @State private var showAllAreas = false
    /// Metro area shown in data sources: the one chosen, or the one How It Works and About write about (TransitModel.sourcesArea:
    /// the start place's, or the nearest)
    private var shownArea: MetroArea { sourceArea ?? transit.sourcesArea }

    var body: some View {
        let l = transit.l10n
        // Opened at Data source or its keys from elsewhere: the main window's transit mode and the start place's metro area
        // again, whatever was chosen here before
        SettingsPageForm(.dataSource, onJump: { target in
            if target == .dataSource || target == .keys {
                sourceSystem = nil
                sourceArea = nil
            }
        }) {
            // What's wrong with the data sources now, if anything
            DataStatusSettings()
                // The log of data checks as it is now: an entry past its days is gone
                .onAppear { transit.reloadDataChanges() }

            // At the top a transit system switch like the one next to the title; below, only the selected system's data sources (so they don't crowd together).
            // When Settings opens, it defaults to the system the main window is showing. The switch lists every mode (TransitSystem.modes).
            // A metro area menu on the right of the header: only the operators with stations in that area are listed; one in
            // several areas is listed in each. The check and Source list rows at the bottom are for the whole mode.
            // First the keys and accounts that area's live times need, then the transit system switch and its operators
            let area = shownArea
            Section {
                AccountKeyRows(area: area)
                SettingSegments(title: l.t("Transit system"), selection: Binding(
                    get: { shownSource },
                    set: { sourceSystem = $0 }
                ), choices: TransitSystem.modes.map { SettingChoice($0, SystemSwitcher.name($0, l), symbol: $0.symbol) },
                   fullWidth: true)
                // How often this mode's data is checked (the providers are the rows below; the map footer says them in a sentence)
                Text(DataSources.settingsSummary(shownSource, l))
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // One row per source: icon, name, a line of small text below, and a "Live" or "Timetable" badge on the right, to keep the list tidy
                let systems = FerrySourceRows.systems(of: shownSource)
                // MTA's subway, the Roosevelt Island Tram and MTA's buses are New York's only
                if area == .newYork, shownSource.mode == .subway {
                    SourceRow(icon: "dot.radiowaves.left.and.right", name: l.t("MTA subway"),
                              detail: l.t("Free, no key needed"), problems: transit.operatorProblems()["MTA"].map { [$0] } ?? [],
                              notUsed: transit.dataNotUsedLine(DataChangeLog.subwayKey).map { [$0] } ?? [],
                              partlyKnown: transit.dataPartlyKnownLine(DataChangeLog.subwayKey), badge: .live)
                    // Roosevelt Island Tram (estimated from RIOC's published operating hours and headways)
                    SourceRow(icon: "cablecar", name: l.t("Roosevelt Island Tram (RIOC)"),
                              detail: l.t("Worked out from RIOC's hours and intervals"), badge: .timetable)
                }
                if area == .newYork, shownSource.mode == .bus {
                    // MTA buses (realtime, key required); NJ Transit and the others below
                    BusKeyRow()
                }
                if !FerrySourceRows.hasRows(systems: systems, area: area) && !(area == .newYork && [.subway, .bus].contains(shownSource.mode)) {
                    Text(l.t("No data for this transit system in this area yet."))
                        .font(.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FerrySourceRows(systems: systems, area: area)
                    .id("\(shownSource.rawValue)-\(area.rawValue)")
            } header: {
                HStack {
                    Text(l.t("Data source"))
                        .settingsSectionTitle(spaceAbove: false)
                        .fixedSize()
                        .layoutPriority(1)
                    Spacer(minLength: 12)
                    // Its whole width when there's room; otherwise it takes what's left and the name ends in "…" (the full name shows
                    // on hover), so the title isn't squeezed
                    ViewThatFits(in: .horizontal) {
                        areaMenu(l).fixedSize()
                        areaMenu(l)
                    }
                    .help(l.metroAreaName(shownArea))
                }
                .settingsSectionSpaceAbove()
                .id(SettingsJump.dataSourceID)
            }

            // Each metro area's downloaded data, with Remove… and Delete Downloaded Data…
            DownloadedDataSettings()

            // Demo mode has its own toggle (not grouped with data sources). It's complete: all four modes anywhere in Manhattan, with
            // made-up times and no data downloads; in the release build too, to show people outside New York how it works
            Section {
                Toggle(isOn: Binding(
                    get: { transit.dataSource == .mock },
                    set: { transit.dataSource = $0 ? .mock : .mtaRealtime }
                )) {
                    Label(l.t("Demo mode"), systemImage: "theatermasks")
                        .labelStyle(IconColumnLabelStyle())
                }
                Text(l.t("Shows made-up subway, bus, train and ferry times in Manhattan. It starts at Times Square, and you can choose another place in Manhattan. It doesn't use your location or download any timetables; only the map comes from Apple Maps. Your own places are kept. Settings you change during the demo stay changed. Turn it off to see real times."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                // The Demo notice's Settings… button scrolls here (SettingsJump)
                Text(l.t("Demo"))
                    .settingsSectionTitle()
                    .id(SettingsJump.Target.demo.id)
            }
        }
        // Every area by name, with the states it is in: a click on one shows its data sources and closes the list
        .sheet(isPresented: $showAllAreas) {
            AreaListSheet(title: l.t("Metropolitan area"), items: areaItems(l), submit: { chooseArea($0) }) { item in
                AreaChoiceRow(item: item, chosen: item.area == shownArea) { chooseArea(item) }
            }
            .environmentObject(transit)
        }
    }

    /// An item of Data source's metro area menu: an area, or the last item, which opens the full list of areas
    private enum AreaChoice: Hashable {
        case area(MetroArea)
        case all
    }

    /// Data source's metro area menu. Up to AreaList.shownAtOnce areas: every area, the start place's first, then the others by
    /// when they were last used, then those never used by name (MetroArea.menuOrder). More: only the areas in use (the ones
    /// Downloaded data gives a reason for) in that order, and the one shown; then a line and All Areas…, which opens the full
    /// list with its search field (AreaList.menu), so the menu doesn't grow with the number of areas. Choosing All Areas… leaves
    /// the area shown as it is
    private func areaMenu(_ l: UIText) -> some View {
        let order = MetroArea.menuOrder(start: transit.areaRegion?.metroArea, lastUsed: AreaUsage.dates(), name: l.metroAreaName)
        let menu = AreaList.menu(order: order, inUse: Set(DownloadedData.reasons().keys), shown: shownArea)
        return AppMenuPicker(l.t("Metropolitan area"), selection: Binding<AreaChoice>(
            get: { .area(shownArea) },
            set: { choice in
                switch choice {
                case .area(let area): sourceArea = area
                case .all: showAllAreas = true
                }
            }
        ), valueText: l.metroAreaName(shownArea), plain: true) {
            ForEach(menu.listed, id: \.self) { Text(l.metroAreaName($0)).tag(AreaChoice.area($0)) }
            if menu.all {
                Divider()
                Text(l.t("All Areas…")).tag(AreaChoice.all)
            }
        }
        .labelsHidden()
    }

    /// The full list's rows: every area by its name in the app's language, with the states it is in under it
    private func areaItems(_ l: UIText) -> [AreaListItem] {
        AreaList.byName(MetroArea.allCases, locale: l.locale, name: l.metroAreaName).map { area in
            AreaListItem(id: area.rawValue, area: area, name: l.metroAreaName(area),
                         detail: l.commaList(area.stateKeys.map { l.t($0) }), searchNames: area.searchNames { l.t($0) })
        }
    }

    /// Data source shows the area chosen in the full list, which closes
    private func chooseArea(_ item: AreaListItem) {
        if let area = item.area { sourceArea = area }
        showAllAreas = false
    }
}
