import AppIntents
import CatchText
import SwiftUI
import TransitCore
import WidgetKit

// MARK: - Timeline

/// One point in time for the widget.
struct TrainEntry: TimelineEntry {
    let date: Date
    /// nil means there's no shared data yet (the main app was never opened, or the shared folder is unavailable).
    let snapshot: TransitSnapshot?
    /// Trips grouped by station; nil in standby.
    let board: NearbyBoard?
    /// The selected station (shared with the main app).
    let selection: BoardSelection
    /// Whether this point in time is in the "started" state.
    let isActive: Bool
    let isPlaceholder: Bool
    /// Language and units chosen in the main app.
    let text: AppText
    /// Whether the main app was running when this timeline was built (if not, the widget can only update MTA subway itself, see WidgetRefresher.canUpdate)
    var appRunning = true
    /// The extra point after the last minute of the timeline: shown only when macOS reloads the widget late, so its times may be out of date
    var pastTimeline = false

    /// The widget has used up its snapshot and can't update it by itself (see TransitSnapshot.isUsedUp)
    func usedUp(_ snap: TransitSnapshot, _ l: UIText) -> Bool {
        snap.isUsedUp(at: date, appRunning: appRunning, canUpdateItself: WidgetRefresher.canUpdate(snap) == .all,
                      isLive: l.liveSource(snap.transitSystem, arrivals: snap.arrivals).isLive)
    }
}

/// Timeline provider.
///
/// In standby: show only a "Start" button, no downloads, and no next refresh scheduled (wait for the button or a main app notification).
/// When started: if the main app is running, use the data it saved (the main app tells the widget to redraw whenever its data changes, so both match);
/// if the main app isn't running, download once on its own when the data is over 60 seconds old.
/// Then generate one point per minute for the next 15 minutes, so countdowns and decisions change by the minute;
/// at the auto-standby time it switches to the standby view. macOS decides how often it actually refreshes.
struct TrainProvider: TimelineProvider {

    func placeholder(in context: Context) -> TrainEntry {
        Self.sampleEntry(placeholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrainEntry) -> Void) {
        if context.isPreview {
            completion(Self.sampleEntry(placeholder: false))
            return
        }
        let now = Date()
        SharedStore.adoptAppSettings()
        // Whether the app runs, as in getTimeline: once it has quit, notices and texts only it gets past aren't shown
        completion(Self.entry(at: now, snapshot: SharedStore.loadSnapshot(), activity: Self.activity(now: now),
                              selection: SharedStore.loadSelection(), appRunning: SharedStore.isAppRunning(now: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrainEntry>) -> Void) {
        Task {
            let now = Date()
            // The settings the app handed over (whether the network is allowed among them), before anything here reads one
            SharedStore.adoptAppSettings()
            let activity = Self.activity(now: now)
            let selection = SharedStore.loadSelection()
            // Record when each size was asked to redraw and whether it read started or standby (to debug the three widgets not entering standby together)
            let family = String(describing: context.family)
            AppLog.widget.notice("getTimeline \(family, privacy: .public) active=\(activity.isActive(at: now), privacy: .public)")
            guard activity.isActive(at: now) else {
                SharedStore.saveWidgetHeartbeat(WidgetHeartbeat(ranAt: now, build: SharedStore.buildNumber))
                let entry = Self.entry(at: now, snapshot: SharedStore.loadSnapshot(), activity: activity,
                                       selection: selection)
                completion(Timeline(entries: [entry], policy: .never))
                AppLog.widget.notice("getTimeline \(family, privacy: .public) done standby")
                return
            }
            let snap = await WidgetRefresher.currentSnapshot(now: now)
            SharedStore.saveWidgetHeartbeat(WidgetHeartbeat(ranAt: now, build: SharedStore.buildNumber))
            let horizon = now.addingTimeInterval(15 * 60)
            // Now, then each of the clock's minutes: the three sizes are asked at different seconds, and change together this way
            var dates = Timetable.timelineMoments(from: now, count: 15)
            // While the main app runs, it tells the widget to redraw, so this is only a fallback; if the main app isn't running, download again on our own after 5 minutes
            var nextReload = now.addingTimeInterval(SharedStore.isAppRunning(now: now) ? 15 * 60 : 5 * 60)
            if let until = activity.standbyAt, until < horizon {
                // Auto-standby time reached (or the end of a reminder's hold, see ActivityState.standbyAt): later points switch to
                // the standby view, and refresh once more at that time.
                dates = dates.filter { $0 < until } + [until]
                nextReload = min(nextReload, until)
            }
            let appRunning = SharedStore.isAppRunning(now: now)
            // Pick the 4 stations to show first, and compute trips only for those across the next 15 points (otherwise widget CPU spikes to 100% when changing settings)
            let small = snap.map { Self.trimmed($0, selection: selection, now: now) }
            var entries = dates.map { Self.entry(at: $0, snapshot: small, activity: activity, selection: selection,
                                                 appRunning: appRunning) }
            // One more point after the last minute, marked out of date: if macOS reloads late, the widget says so instead of
            // showing old verdicts as if they were current
            if activity.standbyAt.map({ $0 >= horizon }) ?? true {
                var last = Self.entry(at: horizon, snapshot: small, activity: activity, selection: selection, appRunning: appRunning)
                last.pastTimeline = true
                entries.append(last)
            }
            completion(Timeline(entries: entries, policy: .after(nextReload)))
            AppLog.widget.notice("getTimeline \(family, privacy: .public) done active entries=\(entries.count, privacy: .public)")
        }
    }

    /// Keep only data for the stations the widget shows (the selected one and 3 others nearby). The widget computes 15 points at once,
    /// and regrouping trips for every nearby station each time costs too much CPU. If no station is picked, use the original snapshot.
    static func trimmed(_ snapshot: TransitSnapshot, selection: BoardSelection, now: Date) -> TransitSnapshot {
        let board = snapshot.board(at: now, settings: WidgetRefresher.widgetSettings(snapshot, now: now),
                                   maxTrainsPerDirection: 24, tooSoonKept: 0)
        var shown = Array(board.stations.prefix(4))
        if let selected = selection.station(in: board) {
            shown = [selected] + board.stations.filter { $0.id != selected.id }.prefix(3)
        }
        let ids = Set(shown.flatMap { $0.stations.map(\.id) })
        guard !ids.isEmpty else { return snapshot }
        var result = snapshot
        result.stations = snapshot.stations.filter { ids.contains($0.id) }
        result.walks = snapshot.walks.filter { ids.contains($0.key) }
        result.arrivals = snapshot.arrivals.filter { ids.contains($0.stationID) }
        return result
    }

    /// On/off state. Treated as "started" if it was never saved (main app never opened).
    static func activity(now: Date) -> ActivityState {
        SharedStore.loadActivity() ?? ActivityState.firstLaunch(at: now)
    }

    static func entry(at date: Date, snapshot: TransitSnapshot?, activity: ActivityState,
                      selection: BoardSelection, appRunning: Bool = true) -> TrainEntry {
        let active = activity.isActive(at: date)
        var board: NearbyBoard?
        if active, let snapshot {
            // Compute a few extra trips, then keep only the selected station and 3 nearby, to save memory.
            // Trips too soon to catch are dropped before the cut, so a busy complex still shows ones worth trying.
            var b = snapshot.board(at: date, settings: snapshot.widgetSettings(appRunning: appRunning),
                                   maxTrainsPerDirection: 24, tooSoonKept: 0)
            if let selected = selection.station(in: b) {
                b.stations = [selected] + b.stations.filter { $0.id != selected.id }.prefix(3)
            }
            board = b
        }
        return TrainEntry(date: date, snapshot: snapshot, board: board, selection: selection, isActive: active,
                          isPlaceholder: false, text: SharedStore.text(for: snapshot), appRunning: appRunning)
    }

    /// Sample (mock data) for the widget gallery preview.
    static func sampleEntry(placeholder: Bool) -> TrainEntry {
        let now = Date()
        let place = MockTransitData.previewPlace
        let settings = CatchSettings.default
        var walks: [String: WalkEstimate] = [:]
        for s in MockTransitData.stations {
            walks[s.id] = WalkEstimator.estimate(from: place.coordinate, to: s, settings: settings)
        }
        let snap = TransitSnapshot(createdAt: now, placeName: place.name,
                                   stations: MockTransitData.stations, walks: walks,
                                   arrivals: MockTransitData.arrivals(now: now), settings: settings)
        // Same board settings as the real widget (see entry(at:)), so the gallery shows what the widget will show
        let board = snap.board(at: now, settings: snap.widgetSettings(appRunning: false), maxTrainsPerDirection: 24,
                               tooSoonKept: 0)
        return TrainEntry(date: now, snapshot: snap, board: board,
                          selection: BoardSelection(), isActive: true, isPlaceholder: placeholder,
                          text: SharedStore.text(for: SharedStore.loadSnapshot()))
    }
}

// MARK: - Views

struct CatchMyTrainWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TrainEntry

    var body: some View {
        let l = entry.text
        Group {
            if !entry.isActive {
                WidgetStandbyView(l: l, compact: family == .systemSmall)
            } else if let snap = entry.snapshot, snap.outsideArea == true {
                // Origin isn't in any of the metro areas: say where it is and that it's out of service range
                WidgetOutsideView(snap: snap, l: l, compact: family == .systemSmall)
            } else if let snap = entry.snapshot, snap.timesInAnotherZone(mac: .autoupdatingCurrent, at: entry.date) {
                // The times read differently on this Mac's clock: the app names the zone with each, the widget has no room for it
                WidgetOtherZoneView(snap: snap, l: l, compact: family == .systemSmall)
            } else if let board = entry.board, let snap = entry.snapshot {
                if let station = entry.selection.station(in: board) {
                    switch family {
                    case .systemSmall:
                        SmallStationView(station: station, board: board, entry: entry, snap: snap, l: l)
                    case .systemMedium:
                        MediumStationView(station: station, board: board, entry: entry, snap: snap, l: l)
                    default:
                        LargeStationView(station: station, board: board, entry: entry, snap: snap, l: l)
                    }
                } else {
                    NoStationView(entry: entry, snap: snap, l: l)
                }
            } else {
                NoDataView(l: l)
            }
        }
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
        .widgetURL(DeepLink.nearby.url)
        .containerBackground(.background, for: .widget)
        .environment(\.layoutDirection, l.language.isRightToLeft ? .rightToLeft : .leftToRight)
    }
}

// MARK: - Widget definition

struct CatchMyTrainWidget: Widget {
    let kind = "CatchMyTrainWidget"

    init() {
        // The language the app handed over, for the description below
        SharedStore.adoptAppSettings()
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrainProvider()) { entry in
            CatchMyTrainWidgetView(entry: entry)
        }
        .configurationDisplayName("Catch My Train")
        .description(SharedStore.text.t("Nearby departures you can catch"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct CatchMyTrainWidgetBundle: WidgetBundle {
    var body: some Widget {
        CatchMyTrainWidget()
    }
}

/// The "Start" button in standby. When the widget is desaturated (not in front), a filled button turns into a white block, so it switches to an outline.
struct StartLabel: View {
    var title: String
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let filled = renderingMode == .fullColor
        Label(title, systemImage: "play.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(filled ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(filled ? Color.accentColor : Color.clear))
            .overlay(Capsule().strokeBorder(filled ? Color.clear : Color.primary, lineWidth: 1.2))
    }
}
