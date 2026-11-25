import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

extension SubwayMapView {
    // MARK: Selected station

    /// A station chosen in Nearby stations: selected as a click on its dot or label selects it (the complex's station with a dot on
    /// this map), its card opens. The map moves to it when it's out of sight, or zoomed out too far to tell it apart
    func selectFromMenu(_ b: BoardStation) {
        let drawn = drawnStations
        guard let first = b.stations.first(where: { drawn[$0.id] != nil }) ?? b.stations.first else { return }
        let dot = drawn[first.id] ?? dotStation(first)
        let center = CLLocationCoordinate2D(latitude: dot.lat, longitude: dot.lon)
        let shown = sight.visible.map { visible in
            visible.rect.contains(MKMapPoint(center))
                && visible.rect.size.width / MKMapPointsPerMeterAtLatitude(center.latitude) <= MapAccessibility.closeEnoughMeters
        } ?? false
        withAnimation(Motion.ease(0.4)) {
            if !shown {
                position = .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)))
            }
            selected = dot
        }
    }

    func stationCard(_ s: SubwayMap.Station, l: UIText) -> some View {
        let routes = NearbyBoardBuilder.sortRoutes(transit.routes(atStation: s.id))
        let boardStation = board.stations.first { $0.stations.contains { $0.id == s.id } }
        let place = NoTimesStations.station(id: s.id)
        // The station as a favorite: its name, where its dot is (drawn then as a small star on the dot: FavoriteMarks.stations)
        let favorite = UserPlace(name: s.name, coordinate: Coordinate(latitude: s.lat, longitude: s.lon))
        return mapCard {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.name).font(.scaled(.headline)).lineLimit(2)
                    if let place {
                        KindBox(text: place.agency.shortName)
                            .foregroundStyle(.secondary)
                    } else {
                        RouteBullets(routes: routes, size: 18, limit: 10)
                    }
                }
                Spacer(minLength: 8)
                starButton(favorite, l: l)
                if let place {
                    // No trains to show: say so, and offer the operator's own page instead, in or out of walking range
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(l.t("No times available"))
                            .font(.scaled(.caption))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        OpenWebsiteButton(place: place, l: l)
                    }
                } else if let boardStation {
                    Button(l.pick(system, train: l.t("Show trains"), bus: l.t("Show buses"), ferry: l.t("Show ferries"))) {
                        showStation(boardStation.id)
                    }
                        .appButtonStyle(.prominent)
                } else {
                    Text(l.t("Outside your walking range"))
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                closeButton(l)
            }
            removedNote(for: favorite, l: l)
        }
    }

    /// The box every card on the map is drawn in, at the bottom of the map, at most 460 points wide: its rows one under the other
    func mapCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .shadow(radius: 4, y: 1)
    }

    func closeButton(_ l: UIText) -> some View {
        Button {
            closeCards()
        } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(l.t("Close"))
        .accessibilityLabel(Text(l.t("Close")))
    }

    // MARK: Bottom: data source and updates

    /// A check that got nothing. With no map yet, the timetables couldn't be downloaded: the network, or the operators' own problems
    /// (one line each, see AppText.downloadFailedText)
    private func failedText(_ l: UIText) -> String {
        let network: String
        if model.map == nil, system.family == .ferry {
            network = l.t("Couldn't download the ferry timetables. Check your network.")
        } else if model.map == nil, system.family == .rail {
            network = l.t("Couldn't download the train timetables. Check your network.")
        } else if model.map == nil, bus {
            network = l.t("Couldn't download the bus timetables. Check your network.")
        } else {
            return l.t("Couldn't check for updates. Will try again later.")
        }
        return l.downloadFailedText(network, problems: TransitModel.timetableNotices(system.timetableSystems))
    }

    func footer(_ l: UIText) -> some View {
        HStack(spacing: 8) {
            // The icon lines up with the first line of the text, not with the middle of it; the button stays in the middle
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: system.symbol).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    // The map and station list are checked monthly together (see SubwayMapStore)
                    Text(DataSources.summary(system, l))
                        .lineLimit(3)
                    Group {
                        switch model.status {
                        case .checking:
                            Text(l.t("Checking for updates…"))
                        case .updated:
                            Text(system.family == .ferry ? l.t("Updated with the latest ferry data.")
                                 : system.family == .rail || bus ? l.t("Updated with the latest timetable data.")
                                 : l.t("Updated with the latest MTA data."))
                        case .upToDate:
                            Text(l.t("The map is up to date."))
                        case .failed:
                            Text(failedText(l))
                        case .idle:
                            // Like Settings: the day the data is up to date as of, and the next monthly check (never a day gone by)
                            if let day = model.upToDate {
                                Text(l.f("Up to date as of %@, next check %@", l.day(day, timeZone: l.macZone), l.day(DownloadDates.nextCheck(), timeZone: l.macZone)))
                            } else if let last = model.lastChecked {
                                Text(l.f("Last checked %@, next check %@", l.day(last, timeZone: l.macZone), l.day(DownloadDates.nextCheck(), timeZone: l.macZone)))
                            } else if !transit.isActive {
                                Text(l.t("Checks for updates when the app is on."))
                            }
                        }
                    }
                    .foregroundStyle(.secondary)
                    // Why "Check Map Data Now" is grayed out, where it shows
                    if model.status != .checking, let reason = transit.checkOnlineReason {
                        Text(reason)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .font(.scaled(.caption))
            }
            Spacer(minLength: 8)
            if model.status == .checking {
                ProgressView().controlSize(.small)
            } else {
                // On standby Start in its place (as in Settings)
                CheckOrStartButton(title: l.t("Check Map Data Now"), small: true) { model.checkNow() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .animation(Motion.ease(0.2), value: model.status)
    }
}
