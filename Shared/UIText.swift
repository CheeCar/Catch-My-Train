import AppKit
import CatchText
import SwiftUI
import TransitCore
import WidgetKit

/// All UI text comes from CatchText (multilingual, meters / feet); this file holds only SwiftUI-related colors and icons.
typealias UIText = AppText

extension AppText {
    /// Pick a sentence by transit system (fetch every sentence with l.t or l.f first). train is the subway one;
    /// rail is for commuter rail (LIRR, Metro-North), path is for PATH; omit them when they match the subway one (e.g. "Loading train times…").
    func pick(_ system: TransitSystem, train: String, bus: String, ferry: String, rail: String? = nil,
              path: String? = nil) -> String {
        switch system {
        case .subway: return train
        case .bus, .njBus: return bus
        case .train, .njTrain, .lightRail: return rail ?? train
        case .ferry, .njFerry: return ferry
        case .path: return path ?? train
        }
    }

    /// Explanation shown when there are no stations within walking range. Shared by the main window, menu bar and widget
    /// (Plan a Trip has its own walk: noStationWithinWalk).
    func noStationNearby(_ system: TransitSystem) -> String {
        pick(system,
             train: t("No subway or light rail station is within walking range. Choose another place, or widen the range in Settings."),
             bus: t("No bus stop is within walking range. Choose another place, or widen the range in Settings."),
             ferry: t("No ferry pier is within walking range. Choose another place, or widen the range in Settings."),
             rail: t("No train station is within walking range. Choose another place, or widen the range in Settings."),
             path: t("No PATH station is within walking range. Choose another place, or widen the range in Settings."))
    }

    /// Plan a Trip's explanation when no station is within the walk chosen there: a longer walk is chosen next to it, not in Settings.
    func noStationWithinWalk(_ system: TransitSystem, walkSeconds: TimeInterval) -> String {
        let walk = minutes(walkSeconds)
        return pick(system,
                    train: f("No subway or light rail station is within a %@ walk. Choose another place, or a longer walk.", walk),
                    bus: f("No bus stop is within a %@ walk. Choose another place, or a longer walk.", walk),
                    ferry: f("No ferry pier is within a %@ walk. Choose another place, or a longer walk.", walk),
                    rail: f("No train station is within a %@ walk. Choose another place, or a longer walk.", walk),
                    path: f("No PATH station is within a %@ walk. Choose another place, or a longer walk.", walk))
    }

    /// Small tag at the top right of a station: what kind of station it is (e.g. "Subway", "Tram", "PATH"),
    /// for rail and ferries it names the operator ("LIRR", "Amtrak", "NY Waterway"); a station group with several lists them all, up to 3.
    func stationKinds(_ routes: [String], system: TransitSystem) -> [String] {
        if system.family == .bus { return [t("Bus")] }
        var kinds: [String] = []
        for route in routes {
            let kind: String
            if route == RooseveltIslandTram.route {
                kind = t("Tram")
            } else if system == .subway && (route == "SI" || route == "SIR") {
                kind = "SIR"
            } else if let source = FerryFeed.Source.of(route: route) {
                switch source {
                case .njTransitLightRail: kind = t("Light Rail")
                case .path: kind = "PATH"
                // Shore Line East comes in Amtrak's package but is CTrail's, like the Hartford Line
                case .amtrakNY: kind = FerryFeed.isShoreLineEast(route) ? FerryFeed.Source.hartfordLine.shortName : "Amtrak"
                default: kind = source.shortName
                }
            } else {
                kind = t("Subway")
            }
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        return Array(kinds.prefix(3))
    }

    /// No departures in one direction within the configured arrival window, e.g. "No trains in the next 2 hr".
    func noArrivals(_ system: TransitSystem, within seconds: TimeInterval) -> String {
        let d = duration(seconds)
        return pick(system, train: f("No trains in the next %@", d), bus: f("No buses in the next %@", d),
                    ferry: f("No ferries in the next %@", d))
    }

    /// When the next one comes after that window, e.g. "Next: 6:05 AM" (BoardDirection.next; less than a day ahead, so the clock
    /// time alone says when)
    func nextDeparture(_ date: Date) -> String { f("Next: %@", time(date)) }

    /// Both in one line, e.g. "No trains in the next 2 hr · Next: 6:05 AM"; only the first part when no next one is known
    func noArrivals(_ system: TransitSystem, within seconds: TimeInterval, next: Date?) -> String {
        let none = noArrivals(system, within: seconds)
        return next.map { none + " · " + nextDeparture($0) } ?? none
    }

    /// The arrival window in the sidebar legend, e.g. "Trains in the next 2 hr".
    func arrivalsWithin(_ system: TransitSystem, _ seconds: TimeInterval) -> String {
        let d = duration(seconds)
        return pick(system, train: f("Trains in the next %@", d), bus: f("Buses in the next %@", d),
                    ferry: f("Ferries in the next %@", d))
    }

    /// Name of the transit mode (title bar, menu bar, widget)
    func modeName(_ system: TransitSystem) -> String {
        switch system.mode {
        case .subway: return t("Subway")
        case .bus: return t("Bus")
        case .ferry: return t("Ferry")
        case .path: return "PATH"
        case .lightRail: return t("Light Rail")
        default: return t("Train")
        }
    }

    /// The line under the sidebar title, the same form in all four modes: the kinds of vehicles the mode has in the start
    /// place's metro area, e.g. "Subway · Light Rail · Tram"; all areas together for a place outside them (nil). A dot between
    /// them, not "and", so no language needs its own grammar here. The header's popover lists the operators.
    /// Generated from ModeCoverage, so it stays in sync automatically when data sources or metro areas are added or removed
    func modeParts(_ system: TransitSystem, in area: MetroArea?) -> String {
        let kinds = ModeCoverage.kinds(for: system, in: area)
        guard !kinds.isEmpty else { return t("No data for this transit system in this area yet.") }
        // A kind's own words stay together, and the dot stays with the kind before it: no-break spaces there
        return kinds.map { vehicleKind($0).replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: "\u{00A0}· ")
    }

    /// A kind of vehicle in the UI language. The keys are written out here, so the key check in CatchTextTests sees them used
    /// (VehicleKind.nameKey has the same ones; ModeCoverageTextTests checks that every one is translated)
    func vehicleKind(_ kind: VehicleKind) -> String {
        switch kind {
        case .subway: return t("Subway")
        case .trolley: return t("Trolley")
        case .lightRail: return t("Light Rail")
        case .tram: return t("Tram")
        case .localBus: return t("Local Bus")
        case .expressBus: return t("Express Bus")
        case .commuterRail: return t("Commuter Rail")
        case .intercityRail: return t("Intercity Rail")
        case .passengerFerry: return t("Passenger Ferry")
        case .carFerry: return t("Car Ferry")
        }
    }

    /// One row of the sidebar header's popover: its operators, after their group's name when they have one
    /// ("MTA: Local, Limited, Select Bus Service and Express"); one operator that runs several kinds of vehicles there is written
    /// the same way, with its kinds ("MBTA Subway: Subway, Trolley and Light Rail"). Generated from ModeCoverage, in sync with
    /// data sources
    func operatorRow(_ row: ModeCoverage.Operator) -> String {
        let names = joinedList(row.names.map(coverageName))
        if let group = row.group { return labeled(coverageName(group), names) }
        if row.names.count == 1, row.kinds.count > 1 { return labeled(names, joinedList(row.kinds.map(vehicleKind))) }
        return names
    }

    /// A name or group from ModeCoverage in the UI language: the ones that are keys are translated, operators' own names stay as they are.
    /// The keys only ModeCoverage holds are written out here, so the key check in CatchTextTests sees them used.
    func coverageName(_ name: String) -> String {
        switch name {
        case "NYC Subway": return t("NYC Subway")
        case ModeCoverage.withoutTimesGroup: return t("Without times")
        case ModeCoverage.privateCommuterBuses:
            return t("Not included: private commuter buses whose times aren't published in a form Catch My Train can use.")
        default: return t(name)
        }
    }

    /// A list as the UI language writes one ("A, B, and C" in English)
    func joinedList(_ items: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        // Right-to-left languages: isolate each item so English names and the Arabic comma (U+060C) and "and" (U+0648) don't get jumbled
        let parts = items.map(isolated)
        return formatter.string(from: parts) ?? commaList(items)
    }

    /// A metro area's name ("New York Metropolitan Area", "Lehigh Valley"): its English name in areas.json, translated
    func metroAreaName(_ a: MetroArea) -> String { t(a.nameKey) }

    /// Region name within the metro area (title bar "New York Metropolitan Area · Long Island"): from areas.json too
    func subRegionName(_ r: MetroSubRegion) -> String { t(r.nameKey) }

    /// The main window footer's first line: the start place's metro area by name only (the operators are in the sidebar header's
    /// popover and Settings → Data source). A mode with none there (the Lehigh Valley has no subway or ferry) says so as
    /// the sidebar does. Made from areas.json, so no sentence names the areas
    func coverageLine(_ system: TransitSystem, in area: MetroArea) -> String {
        guard !ModeCoverage.kinds(for: system, in: area).isEmpty else { return t("No data for this transit system in this area yet.") }
        return metroAreaName(area)
    }

    /// The live data line of the main window footer and Plan a Trip: only the operators of the selected station or of
    /// the results, usually one to three, grouped by where their times come from now (ModeCoverage.liveNames), so it follows the
    /// operators and the keys the user added
    func liveDataLine(_ names: [ModeCoverage.LiveName]) -> String {
        ModeCoverage.LiveState.allCases.compactMap { state -> String? in
            let these = names.filter { $0.state == state }.map { coverageName($0.name) }
            guard !these.isEmpty else { return nil }
            let list = joinedList(these)
            switch state {
            case .live: return f("Live data: %@.", list)
            case .needsKey: return f("Live once you add your key or account: %@.", list)
            case .notNow: return f("%@: timetable (live data isn't available right now).", list)
            case .timetable: return f("Timetable only: %@.", list)
            case .estimated: return f("Estimated from its hours: %@.", list)
            }
        }.joined(separator: " ")
    }

    /// Source shown in the data status (menu bar panel and widget), from the departures themselves (see LiveSource): one
    /// operator by its name from areas.json ("MTA live", "SEPTA live"), "Ferry live" for several ferries, "Live" for any other
    /// mix, or "Timetable" when nothing shown is live. Only the station shown's departures, when one is
    func liveSource(_ system: TransitSystem, arrivals: [Arrival], station: BoardStation? = nil) -> (text: String, symbol: String, isLive: Bool) {
        let text: String
        switch LiveSource.of(arrivals, at: station, system: system) {
        case .one(let name): text = f("%@ live", name)
        case .ferries: text = t("Ferry live")
        case .several: text = t("Live")
        case .timetable: return (t("Timetable"), "calendar", false)
        }
        return (text, "dot.radiowaves.left.and.right", true)
    }

    /// Notice when ferry (rail) live data failed to download (those operators fall back to timetables); nil when everything downloaded.
    func realtimeError(_ system: TransitSystem, failed: [FerryFeed.Source]) -> String? {
        // PATH has live data only: if it didn't download there are no departures
        if failed.contains(.path) { return liveDataFailed(ofOperator: FerryFeed.Source.path.rawValue) }
        switch failed.count {
        case 0: return nil
        case 1: return f("Couldn't get %@ live data. Showing timetable times for now.", failed[0].name)
        default: return system.family == .rail ? t("Couldn't get live train data. Showing timetable times for now.")
            : t("Couldn't get live ferry data. Showing timetable times for now.")
        }
    }

    /// The line in a departure's details and in Plan a Trip's walk tip for the time from reaching the stop to boarding, which the
    /// verdict counts (Station.entranceToPlatformSeconds), worded by the routes there: at a station, the way to the platform; at a pier
    /// or a bus stop, boarding; for the Statue of Liberty ferry, tickets and security (FerryFeed.Source.boardingSeconds). By the
    /// routes, not the stop's id, so the demo's stops read the same. Nil when there is none (MTA's buses)
    func boardingLine(seconds: TimeInterval, routes: [String]) -> String? {
        guard seconds > 0 else { return nil }
        let sources = routes.compactMap(FerryFeed.Source.of(route:))
        if sources.contains(where: \.needsSecurityCheck) { return f("Ticket and security check: %@", minutes(seconds)) }
        if sources.contains(where: { [.ferry, .bus].contains($0.system.mode) }) { return f("Time to board: %@", minutes(seconds)) }
        return f("Station entrance to platform: %@", minutes(seconds))
    }

    /// An operator's live data couldn't be had at all, with nothing earlier to show instead: by its name from areas.json ("PATH",
    /// "MTA"; see ModeCoverage.liveName)
    func liveDataFailed(ofOperator id: String) -> String {
        f("Couldn't get %@ live data. Check your network.", ModeCoverage.liveName(ofOperator: id) ?? id)
    }
}

/// Colors for each verdict (shared by the main app and the widget).
/// Small text must be readable too (the standard green and orange have too little contrast as small text on light backgrounds):
/// light mode uses darker green, orange, red and gray; dark mode uses system colors.
extension CatchVerdict {
    var color: Color {
        switch self {
        case .canTry: return .adaptive(light: 0x1E7B34, dark: NSColor.systemGreen)
        case .tight: return .adaptive(light: 0xA85300, dark: NSColor.systemOrange)
        case .takeNext: return .adaptive(light: 0xC0262D, dark: NSColor.systemRed)
        case .insufficientInfo: return .adaptive(light: 0x63636A, dark: NSColor.systemGray)
        }
    }
    /// Each verdict gets a differently shaped icon so color-blind users can tell them apart without color.
    /// In color-blindness simulation (Machado 2009) the red, green and orange small-text colors look very similar under red-green color blindness, so an icon and text are required besides color.
    var symbol: String {
        switch self {
        case .canTry: return "checkmark.circle.fill"
        case .tight: return "exclamationmark.triangle.fill"
        case .takeNext: return "xmark.circle.fill"
        case .insufficientInfo: return "questionmark.circle.fill"
        }
    }

    /// Icon + text, both in the verdict's color (shared by the main window, menu bar and widget)
    func line(_ text: String) -> Text {
        Text(Image(systemName: symbol)) + Text(" ") + Text(text)
    }
}

/// The first one of a direction you can catch (can try or tight): a bar at its leading edge and a light wash, both in its
/// verdict's color. The bar is a shape, so it shows without telling colors apart. nil: not that one, nothing drawn. Used by the main
/// window, the menu bar panel and the widget
struct FirstCatchableMark: ViewModifier {
    var verdict: CatchVerdict?
    var inset: CGFloat = 6

    func body(content: Content) -> some View {
        if let verdict {
            content
                .background(verdict.color.opacity(0.08))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(verdict.color)
                        .frame(width: 3)
                        .padding(.vertical, inset)
                }
        } else {
            content
        }
    }
}

/// Whether the row this view is in is lit up (white on the accent color), for the few icons that keep a color of their own
private struct RowHighlightedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var rowHighlighted: Bool {
        get { self[RowHighlightedKey.self] }
        set { self[RowHighlightedKey.self] = newValue }
    }
}

/// A favorite's star (gold) or a recent place's clock (gray) in a list row; white like the text when the row is lit up
struct FavoriteStarStyle: ViewModifier {
    var favorite: Bool
    @Environment(\.rowHighlighted) private var highlighted

    func body(content: Content) -> some View {
        content.foregroundStyle(highlighted ? AnyShapeStyle(Color.white)
                                : favorite ? AnyShapeStyle(Color.favoriteStar) : AnyShapeStyle(.secondary))
    }
}

extension Color {
    /// One color each for light and dark mode (light mode color written as 0xRRGGBB).
    static func adaptive(light: UInt32, dark: NSColor) -> Color {
        let lightColor = NSColor(srgbRed: CGFloat(light >> 16 & 0xFF) / 255, green: CGFloat(light >> 8 & 0xFF) / 255,
                                 blue: CGFloat(light & 0xFF) / 255, alpha: 1)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : lightColor
        })
    }

    /// Orange and red for hint text ("Paused until…", "Can't connect", "Data stale", etc.): system orange text on white has only about 2.2:1 contrast, red about 3.6:1,
    /// so light mode uses darker ones (all above 4.5:1); dark mode keeps system colors
    static let noticeOrangeLight: UInt32 = PaletteHex.noticeOrangeLight
    static let noticeRedLight: UInt32 = PaletteHex.noticeRedLight
    static let noticeOrange = adaptive(light: noticeOrangeLight, dark: .systemOrange)
    static let noticeRed = adaptive(light: noticeRedLight, dark: .systemRed)
    /// Green for hint text ("Live", "Connected", "Key saved…" in Settings): system green text on white is only about 2.1:1,
    /// so light mode uses dark green (about 6.3:1 on white, about 5:1 on the "Live" tag's light green background); dark mode unchanged
    static let noticeGreenLight: UInt32 = PaletteHex.noticeGreenLight
    static let noticeGreen = adaptive(light: noticeGreenLight, dark: .systemGreen)
    /// Walking-range circles on the map and their legend: teal, since blue is kept for things you can click. Light mode about 5.2:1 on white
    /// and 4.7:1 on the light map (graphics need 3:1); dark mode system mint. No route line uses this color
    static let walkRangeLight: UInt32 = PaletteHex.walkRangeLight
    static let walkRange = adaptive(light: walkRangeLight, dark: .systemMint)

    /// Contrast ratio of two colors (0xRRGGBB) (WCAG 2 formula, 1 to 21)
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ c: UInt32) -> Double {
            func channel(_ v: UInt32) -> Double {
                let x = Double(v & 0xFF) / 255
                return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c >> 16) + 0.7152 * channel(c >> 8) + 0.0722 * channel(c)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// Favorite stars (place picker, Plan a Trip's ★ popover): system yellow is only about 1.5:1 on white (an icon needs 3:1), so
    /// light mode uses a dark gold (about 4.7:1); dark mode keeps system yellow. On the accent color the star is white instead
    static let favoriteStarLight: UInt32 = PaletteHex.favoriteStarLight
    static let favoriteStar = adaptive(light: favoriteStarLight, dark: .systemYellow)
    /// The place's pin on Plan a Trip's map: the same red as the app's other red
    static let placePin = noticeRed
    /// Metro area names on the map: system purple text is about 4.1:1 on white, so light mode uses a darker purple (about
    /// 6.1:1); dark mode keeps system purple (about 4.7:1)
    static let metroNameLight: UInt32 = PaletteHex.metroNameLight
    static let metroName = adaptive(light: metroNameLight, dark: .systemPurple)
    /// The service area's dashed edge on the map
    static let serviceAreaLine = Color(nsColor: .systemPurple).opacity(0.75)
    /// Fill of the map dots of stations with no times the app can use
    static let noTimesDot = Color(nsColor: .systemGray)
    /// A box that only explains (nothing in it to click): neutral gray like the sidebar's range note, since blue is kept for what
    /// you can click
    static let noteBackground = Color.secondary.opacity(0.08)
    /// The thin line around a station's card in the sidebar, and under the range legend above the cards (the system's separator color)
    static let stationSeparator = Color(nsColor: .separatorColor)
    /// A station's card in the sidebar: a little lighter than the sidebar (the buttons above the cards are a little darker), 28% white
    /// in the light appearance, 5% in the dark one
    static let stationCard = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.05) : NSColor.white.withAlphaComponent(0.28)
    })
    /// Demo mode's notice box
    static let demoBackground = Color(nsColor: .systemYellow).opacity(0.18)
    /// The bus key prompt's box (it has its own Add key… button)
    static let keyPromptBackground = Color(nsColor: .systemOrange).opacity(0.12)

    /// Orange for the express tag (used by subway and bus): darker than system orange so white text is readable (contrast 4.5:1 or more)
    static let expressOrange = Color(red: 0.70, green: 0.30, blue: 0.0)
    /// Local / regular bus tag: mid gray; white text is readable in both light and dark mode
    static let localGray = Color(red: 0.42, green: 0.42, blue: 0.45)
    /// Bus Limited-Stop tag: magenta (a teal would be almost identical to Local gray in red-green simulation, color difference 2);
    /// with this, all four tags differ pairwise by more than 20 in all three color-blindness simulations, and white text contrast is 7:1
    static let limitedPurple = Color(red: 0.55, green: 0.20, blue: 0.55)
}

/// Official NYC subway line colors (approximate).
enum RouteColor {
    static func color(for route: String) -> Color {
        switch MTARoute.normalize(route) {
        case "1", "2", "3": return Color(red: 0.93, green: 0.21, blue: 0.18)
        case "4", "5", "6": return Color(red: 0.0, green: 0.58, blue: 0.24)
        case "7": return Color(red: 0.73, green: 0.2, blue: 0.68)
        case "A", "C", "E": return Color(red: 0.0, green: 0.22, blue: 0.65)
        case "B", "D", "F", "M": return Color(red: 1.0, green: 0.39, blue: 0.1)
        case "G": return Color(red: 0.42, green: 0.75, blue: 0.27)
        case "J", "Z": return Color(red: 0.6, green: 0.4, blue: 0.2)
        case "L", "S", "GS", "FS", "H": return Color(red: 0.5, green: 0.51, blue: 0.51)
        case "SI": return Color(red: 0.0, green: 0.22, blue: 0.65)
        case "N", "Q", "R", "W": return Color(red: 0.99, green: 0.8, blue: 0.04)
        default: return .gray
        }
    }

    /// Yellow N Q R W and light green G use black text (white on the G line is only 2.3:1)
    static func textColor(for route: String) -> Color {
        ["N", "Q", "R", "W", "G"].contains(MTARoute.normalize(route)) ? .black : .white
    }
}

/// In-app text size (Text size in Settings). macOS doesn't follow SwiftUI Dynamic Type, so we scale proportionally ourselves.
/// Always 1 in the widget (follows macOS). When changed, the main window, Settings, location picker and menu bar panel redraw entirely.
enum TextScale {
    /// Only changed on the main thread (when text size changes in Settings), read by the UI. Marked nonisolated(unsafe) so enabling Swift 6 strict checking later won't error
    nonisolated(unsafe) static var factor: CGFloat = 1
}

extension Font {
    /// System font scaled by TextScale. At a factor of 1 it's the original text style, looking exactly the same.
    static func scaled(_ style: Font.TextStyle) -> Font {
        let f = TextScale.factor
        guard f != 1 else { return .system(style) }
        let base: CGFloat
        switch style {
        case .largeTitle: base = 26
        case .title: base = 22
        case .title2: base = 17
        case .title3: base = 15
        case .headline: return .system(size: 13 * f, weight: .bold)
        case .body: base = 13
        case .callout: base = 12
        case .subheadline: base = 11
        case .footnote: base = 10
        case .caption: base = 10
        case .caption2: base = 10
        @unknown default: base = 13
        }
        return .system(size: base * f)
    }
}

/// Outline color for tags and boxes. Uses a darker color when "Increase contrast" is on in System Settings.
/// On a selected list row (the blue highlight) it is the system's secondary style, like the text in the tags, which the system switches at once
/// when a row gets selected. A plain color there was blended during the selection change and showed as solid white partway.
struct OutlineColor: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        if environment.colorSchemeContrast == .increased { return AnyShapeStyle(Color.primary) }
        if environment.backgroundProminence == .increased { return AnyShapeStyle(HierarchicalShapeStyle.secondary) }
        return AnyShapeStyle(Color.secondary.opacity(0.6))
    }
}

/// When "Increase contrast" is on, give light-background boxes a clear border.
struct ContrastBorder: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.7), lineWidth: 1)
            }
        }
    }
}

extension View {
    func contrastBorder(cornerRadius: CGFloat) -> some View {
        modifier(ContrastBorder(cornerRadius: cornerRadius))
    }
}

extension Binding where Value: Equatable {
    /// Binding for AppKit controls (sidebar list, toggles, segmented controls, menus): only changes when the value really changed, and waits until this UI update pass ends.
    /// These controls report changes mid-update, and changing @Published directly makes SwiftUI report "Publishing changes from within view updates"
    /// (thousands at a time while operating the app). Every such control uses this one binding.
    static func afterViewUpdate(get: @escaping () -> Value, set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: get, set: { new in
            guard new != get() else { return }
            DispatchQueue.main.async { set(new) }
        })
    }
}
