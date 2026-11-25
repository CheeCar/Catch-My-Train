import AppIntents
import CatchText
import SwiftUI
import TransitCore
import WidgetKit

/// Mode and region, e.g. "<bus icon> Bus · Long Island".
/// The small size has no room, so only the mode icon is drawn. In the other sizes the status beside it keeps its room:
/// when the line is short of space the region goes first, then the mode name, so no word is cut (the icon always stays).
struct WidgetAreaLine: View {
    var snap: TransitSnapshot
    var l: UIText
    var iconOnly = false
    /// Contains .privacy where the system hides private things (the area with them): screen readers then get the mode only
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        let mode = snap.transitSystem.mode
        let name = l.modeName(mode)
        HStack(spacing: 3) {
            Image(systemName: mode.symbol)
            if !iconOnly {
                // Only these few words are measured again, not the whole layout
                ViewThatFits(in: .horizontal) {
                    // The area tells roughly where the place is: redacted like the place itself
                    Text(l.dotted([name, snap.areaName].compactMap { $0 }))
                        .privacySensitive()
                    Text(name)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        // The mode and the area, as the line shows them (the area also when only the icon or the mode fits)
        .accessibilityLabel(Text(redaction.contains(.privacy) ? name : l.commaList([name, snap.areaName].compactMap { $0 })))
    }
}

/// Origin out of service range: show the place and an explanation (same for all three sizes, only the font size differs).
struct WidgetOutsideView: View {
    var snap: TransitSnapshot
    var l: UIText
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            WidgetAreaLine(snap: snap, l: l, iconOnly: true)
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: compact ? 16 : 20))
                .foregroundStyle(Color.noticeOrange)
            if let place = snap.areaName {
                Text(place)
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .lineLimit(2)
                    .privacySensitive()
            }
            Text(l.t("Outside the service area"))
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(Color.noticeOrange)
            if !compact {
                Text(l.t("Open Catch My Train to choose a place inside the areas it covers."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Standby is reachable here too (in the free space at the top, so nothing moves): while on, Catch My Train keeps refreshing
        .overlay(alignment: .topTrailing) {
            WidgetStandbyButton(l: l, size: 13)
        }
    }
}

/// The starting place's times are in another time zone than this Mac's clock (TransitSnapshot.timesInAnotherZone): no times, only
/// where and a hint to open the app (same for all three sizes, only the font size differs, as WidgetOutsideView)
struct WidgetOtherZoneView: View {
    var snap: TransitSnapshot
    var l: UIText
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            WidgetAreaLine(snap: snap, l: l, iconOnly: true)
            Spacer(minLength: 0)
            Image(systemName: "clock")
                .font(.system(size: compact ? 16 : 20))
                .foregroundStyle(.secondary)
            if let place = snap.areaName {
                Text(place)
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .lineLimit(2)
                    .privacySensitive()
            }
            Text(l.t("These times are in another time zone. Open Catch My Train to see them."))
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 4 : 3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Standby is reachable here too, as on WidgetOutsideView
        .overlay(alignment: .topTrailing) {
            WidgetStandbyButton(l: l, size: 13)
        }
    }
}

/// Data status: live / mock / stale, plus the data's own update time (MTA timestamp, not when the widget redrew).
struct WidgetStatusLine: View {
    var snap: TransitSnapshot
    var entry: TrainEntry
    var l: UIText
    /// The station shown: rate limits and connection notices only about its providers (nil: the whole mode's, see NoticeScope)
    var station: BoardStation?
    var compact = false
    /// False drops the data time (the small size uses it when the status and the time don't fit on one line)
    var showsTime = true
    /// False drops the front part when it only says where the data comes from ("MTA live"), never a notice: the small size's
    /// first choice when the line doesn't fit, so the time stays (the same order as a line with a second sentence)
    var showsSource = true

    /// What the line says, worked out once: `body` lays it out in up to three ways
    private struct Parts {
        var symbol: String
        var text: String
        /// False when the front part only says where the data comes from ("MTA live"); a notice is never dropped
        var isNotice: Bool
        var stamp: String
        /// A second sentence after the time ("updates about every 5 min", "open the app to update", a new version)
        var hint: String?
        var isOrange: Bool
    }

    private var parts: Parts {
        // Same time as the main window's "Data updated"
        let dataTime = snap.updateTime ?? snap.createdAt
        let source = l.liveSource(snap.transitSystem, arrivals: snap.arrivals, station: station)
        // The data time is the server's: compare with server time (in case the local clock is off, see ClockSkew)
        let age = (snap.updateTime == nil ? entry.date : ClockSkew.now(entry.date)).timeIntervalSince(dataTime)
        // Timetable-only data (e.g. Staten Island Ferry) never goes stale; the point after the timeline's last minute always is
        let stale = (source.isLive && age > snap.widgetStaleAfterSeconds(appRunning: entry.appRunning)) || entry.pastTimeline
        // Timetable data the widget can't update by itself has run out (see TransitSnapshot.isUsedUp)
        let usedUp = entry.usedUp(snap, l)
        // Data from an earlier day shows its date rather than a time that looks like today's
        let stamp = Timetable.calendar(in: l.timeZone).isDate(dataTime, inSameDayAs: entry.date) ? l.time(dataTime) : l.day(dataTime)
        // A data provider said too many requests and is paused: show a notice
        let members = station?.stations.map(\.id)
        let limit = snap.rateLimits(at: entry.date, stationIDs: members).max { $0.until < $1.until }
        // Data providers that can't be reached (possibly network restrictions): explain why, like the main app.
        // Once the app has quit, a passing problem it saw long ago is dropped (see reachNotices(at:stationIDs:appRunning:))
        let reach = limit == nil ? snap.reachNotices(at: entry.date, stationIDs: members, appRunning: entry.appRunning) : []
        // Network turned off in Settings: the widget doesn't download either, just says "Network off"
        let offline = !NetworkSwitch.isAllowed
        // When not updating along with each main app refresh (main app in background or closed), tell the user how often it updates.
        // When the main app isn't running, the widget can only update the NYC Subway, the Staten Island Railway and the Roosevelt Island
        // Tram itself; other operators' times need the main app open
        let slow = !offline && !compact && limit == nil && reach.isEmpty && !snap.containsMockData && source.isLive && age > 90
        let selfUpdate = WidgetRefresher.canUpdate(snap)
        let needsApp = (slow && !entry.appRunning && selfUpdate != .all)
            || (usedUp && !offline && !compact && limit == nil && reach.isEmpty)

        var parts = Parts(symbol: source.symbol, text: source.text, isNotice: false, stamp: stamp, hint: nil,
                          isOrange: stale || usedUp || limit != nil || !reach.isEmpty)
        if offline {
            parts.symbol = "wifi.slash"
            parts.text = l.t("Network off")
            parts.isNotice = true
        } else if let limit {
            parts.symbol = "hourglass"
            parts.text = compact ? l.f("Paused until %@", l.time(limit.until))
                                 : l.f("%@: too many requests, paused until %@", l.t(limit.provider), l.time(limit.until))
            parts.isNotice = true
        } else if let first = reach.first {
            let summary = l.reachShortSummary(reach)
            parts.symbol = summary != nil ? "wifi.exclamationmark" : l.reachSymbol(first)
            if compact {
                parts.text = first.problem == .offline ? l.t("No internet connection")
                    : first.problem.isNetwork ? l.t("Can't connect") : l.t("Data problem")
            } else {
                parts.text = summary ?? l.reachShortText(first)
            }
            parts.isNotice = true
        } else if stale || (usedUp && compact) {
            parts.symbol = "exclamationmark.arrow.circlepath"
            parts.text = l.t("Stale")
            parts.isNotice = true
        } else if snap.containsMockData {
            // Demo mode (same as the main app's "Demo data only")
            parts.symbol = "theatermasks"
            parts.text = l.t("Demo data only")
            parts.isNotice = true
        }
        if needsApp {
            parts.hint = selfUpdate == .none ? l.t("open the app to update") : l.t("PATH, light rail: open the app to update")
        } else if slow && !stale {
            parts.hint = l.t("updates about every 5 min")
        } else if !compact, let version = snap.updateAvailable, limit == nil, reach.isEmpty, !stale, !usedUp {
            // New version available (found by the main app): mention it, like the main window and menu bar
            parts.hint = l.f("Version %@ is available", version)
        }
        return parts
    }

    /// One way to lay the line out: with or without its front part, with or without the second sentence
    private func line(_ parts: Parts, front: Bool, hint: String?) -> some View {
        HStack(spacing: 3) {
            if front {
                Image(systemName: parts.symbol)
                Text(parts.text)
            }
            // Still says how old the data is while rate-limited (the times shown are from then)
            if showsTime {
                if front { Text("·") }
                Text(compact ? parts.stamp : l.f("Updated %@", parts.stamp))
            }
            if let hint {
                if front || showsTime { Text("·") }
                Text(hint)
            }
        }
        .lineLimit(1)
    }

    /// What a screen reader says when the line has a second sentence: all of it, whichever layout fits
    private func spoken(_ parts: Parts, hint: String) -> String {
        var items = [parts.text]
        if showsTime { items.append(l.f("Updated %@", parts.stamp)) }
        items.append(hint)
        return l.commaList(items)
    }

    var body: some View {
        let parts = self.parts
        Group {
            if let hint = parts.hint {
                // The second sentence is shown whole or not at all: when the line is too long, first without the front part that
                // only says where the data comes from, then without the second sentence. A screen reader gets all of it either way.
                ViewThatFits(in: .horizontal) {
                    line(parts, front: true, hint: hint)
                    if !parts.isNotice {
                        line(parts, front: false, hint: hint)
                    }
                    line(parts, front: true, hint: nil)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(spoken(parts, hint: hint)))
            } else {
                line(parts, front: showsSource || parts.isNotice || !showsTime, hint: nil)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(parts.isOrange ? Color.noticeOrange : Color.secondary)
    }
}
