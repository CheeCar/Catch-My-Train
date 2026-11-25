import Foundation
import MapKit
import TransitCore

/// The app's own station names for the place search (the place picker and Plan a Trip), found without the network: the current
/// mode's. Subway: the NYC Subway's (built in) and those of the subway and light rail timetables on this Mac; train: the train
/// stations; ferry: the piers; bus: none (too many stops, with names alike). Each timetable's are read from the small list beside it
/// (FerryStore.stationNames) and kept while that mode is searched, until the list changes
@MainActor
enum StationSearch {
    /// The station names among Plan a Trip's suggestions, at most (the place picker shows fewer). Passed in rather than used as
    /// the default value: a default value can't use the main actor's properties
    static let shownAtMost = 4

    static func matching(_ query: String, system: TransitSystem, catalog: StationCatalog?, limit: Int) -> [StationName] {
        guard system.mode != .bus,
              query.trimmingCharacters(in: .whitespaces).count >= StationNames.shortestSearch else { return [] }
        var names = system.mode == .subway ? catalog.map(StationNames.of) ?? [] : []
        var used: [URL: (date: Date, names: [StationName])] = [:]
        for part in system.mode.timetableSystems {
            let store = FerryStore.store(for: part)
            guard let url = store.namesURL,
                  let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            let list = kept[url].flatMap { $0.date == date ? $0.names : nil } ?? store.stationNames()
            used[url] = (date, list)
            names += list
        }
        // Only this mode's lists stay in memory
        kept = used
        return StationNames.matching(query, in: names, limit: limit)
    }

    /// The lists read, by file, with the file's date then
    private static var kept: [URL: (date: Date, names: [StationName])] = [:]
}

/// Search addresses or places in the service area with Apple Maps (no key needed). Suggests while typing, looks up coordinates once one is chosen.
/// Search text stays in memory only and isn't saved.
@MainActor
final class AddressSearch: NSObject, ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            // Editing the search text drops the lookup of a suggestion clicked before (see PlaceLookupGate)
            cancelLookup()
            retry.reset()
            // Don't search when networking is turned off in Settings (Apple Maps search needs the network), nor in Demo mode (it
            // searches its own places); a search still running for the earlier text stops too
            if !usesAppleMaps || !USAddress.isSearchable(query) || !NetworkSwitch.isAllowed {
                completer?.cancel()
                suggestions = []
                nothingFound = false
            } else {
                searchCompleter().queryFragment = query
            }
        }
    }
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    /// Apple Maps found no place in the US for the text (see USAddress.saysNothingFound): a line under the field says so, and suggests a station name
    @Published private(set) var nothingFound = false
    /// Off in Demo mode: the text is kept for the demo's own search, and Apple Maps isn't asked
    var usesAppleMaps = true {
        didSet {
            guard !usesAppleMaps else { return }
            completer?.cancel()
            suggestions = []
            nothingFound = false
        }
    }

    /// Created only on first input (the Apple Maps search service uses a fair amount of memory).
    private var completer: MKLocalSearchCompleter?
    /// The simpler text asked when the text as typed found nothing (see SearchRetry)
    private var retry = SearchRetry()

    private func searchCompleter() -> MKLocalSearchCompleter {
        if let completer { return completer }
        let c = Self.makeCompleter(delegate: self)
        completer = c
        return c
    }

    /// Shared by the location picker and the trip planner search fields.
    static func makeCompleter(delegate: MKLocalSearchCompleterDelegate) -> MKLocalSearchCompleter {
        let c = MKLocalSearchCompleter()
        c.delegate = delegate
        c.resultTypes = [.address, .pointOfInterest]
        limitToServiceArea(c)
        return c
    }

    /// Search results: keep only the ones in the US (the caller lists the first few, see SearchRetry.listed); nothing = none of
    /// them is in the US, said for this text (see USAddress.saysNothingFound); fragment = the text they were found for (read
    /// together with the results, so the caller can drop them once the field shows other text).
    nonisolated static func results(of completer: MKLocalSearchCompleter)
        -> (results: [MKLocalSearchCompletion], nothing: Bool, fragment: String) {
        let results = completer.results.filter(looksLikeUS)
        let fragment = completer.queryFragment
        return (results, USAddress.saysNothingFound(kept: results.count, found: completer.results.count, for: fragment), fragment)
    }

    /// Search looks first in the whole service area (the search region is the box around all of it, ServiceArea.bounds, so results in any of
    /// its metro areas rank first); only US places are kept (no places like Greece or the UK; elsewhere in the US can be found, and choosing
    /// one explains it's outside the service area).
    static func limitToServiceArea(_ c: MKLocalSearchCompleter) {
        let b = ServiceArea.bounds
        c.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (b.lat.lowerBound + b.lat.upperBound) / 2, longitude: (b.lon.lowerBound + b.lon.upperBound) / 2),
            span: MKCoordinateSpan(latitudeDelta: b.lat.upperBound - b.lat.lowerBound, longitudeDelta: b.lon.upperBound - b.lon.lowerBound))
    }

    /// This suggestion looks like a US place (see USAddress.looksLikeUS)
    nonisolated static func looksLikeUS(_ r: MKLocalSearchCompletion) -> Bool {
        USAddress.looksLikeUS(title: r.title, subtitle: r.subtitle)
    }

    /// What a suggestion says: its name and its address (see SearchRetry.listed)
    nonisolated static func said(_ r: MKLocalSearchCompletion) -> String {
        r.title + ", " + r.subtitle
    }

    /// The address lookup in flight, and whether its answer is still wanted (see lookUp)
    private var lookupTask: Task<Void, Never>?
    private var lookup = PlaceLookupGate()

    /// Look up the coordinates of a suggestion, then call done (nil if not found).
    /// Another lookup or cancelLookup drops this one, and done is then never called: a slow answer can't replace what the user did since.
    func lookUp(_ completion: MKLocalSearchCompletion, done: @escaping @MainActor (Coordinate?) -> Void) {
        // Also stop the older request early; the gate ignores its answer either way
        lookupTask?.cancel()
        let id = lookup.start()
        lookupTask = Task {
            let c = await resolve(completion)
            guard lookup.finish(id) else { return }
            lookupTask = nil
            done(c)
        }
    }

    /// Another place was picked, the search text was edited, or the window was cancelled, closed or switched to another purpose: drop the lookup in flight
    func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil
        lookup.drop()
    }

    /// Look up the coordinates of a suggestion. Returns nil if not found (or when dropped: the request stops with the task, see MapsRequest).
    private func resolve(_ completion: MKLocalSearchCompletion) async -> Coordinate? {
        guard NetworkSwitch.isAllowed, let response = await MapsRequest.search(MKLocalSearch.Request(completion: completion)),
              let item = response.mapItems.first else { return nil }
        let c = item.placemark.coordinate
        return Coordinate(latitude: c.latitude, longitude: c.longitude)
    }

    func clear() {
        query = ""
        suggestions = []
        nothingFound = false
    }
}

extension AddressSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let (results, nothing, fragment) = AddressSearch.results(of: completer)
        Task { @MainActor in
            // Only results for the text the field shows now: an edit, Clear or turning the network off since then makes them stale
            guard self.usesAppleMaps, NetworkSwitch.isAllowed,
                  self.retry.isCurrent(fragment: fragment, query: self.query) else { return }
            // Nothing in the US for the text as typed: ask once more with a simpler one before saying so
            if results.isEmpty, let simpler = self.retry.next(after: fragment, query: self.query) {
                self.searchCompleter().queryFragment = simpler
                return
            }
            self.suggestions = self.retry.listed(results, text: AddressSearch.said)
            self.nothingFound = nothing
        }
    }

    /// Apple Maps couldn't search (it can't be reached, or found nothing at all): no suggestions, and for a long enough text the
    /// same sentence as for no place found
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let fragment = completer.queryFragment
        Task { @MainActor in
            self.suggestions = []
            guard self.usesAppleMaps, NetworkSwitch.isAllowed,
                  self.retry.isCurrent(fragment: fragment, query: self.query) else { return }
            if let simpler = self.retry.next(after: fragment, query: self.query) {
                self.searchCompleter().queryFragment = simpler
                return
            }
            self.nothingFound = USAddress.saysNothingFound(kept: 0, found: 0, for: fragment)
        }
    }
}
