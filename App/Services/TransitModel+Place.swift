import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    /// Demo mode's places (SharedStore.DemoPlaces): new ones each time it's turned on (Times Square, the demo's favorites, recent
    /// places and commute presets, the presets named in the app's language), dropped when it's turned off; the place settings are then read again without saving them, so the
    /// user's own places and presets, which nothing in Demo mode changes, are back as they were
    func useDemoPlaces(_ on: Bool) {
        SharedStore.demoPlaces = on ? SharedStore.DemoPlaces(presets: l10n.demoPresets) : nil
        let savedPersists = persistsSettings
        persistsSettings = false
        place = SharedStore.place
        hasPlace = on || SharedStore.hasChosenPlace
        locationMode = SharedStore.locationMode
        persistsSettings = savedPersists
        // "Use my location" turned off while in Demo mode: the user's own "current location" became their chosen place as it was
        // read (locationMode's didSet), and is saved so, as when it's turned off outside Demo mode
        if !on, SharedStore.locationMode != locationMode {
            if persistsSettings { SharedStore.locationMode = locationMode }
        }
        presetCenter.reload()
    }

    /// The transit mode is the user's own outside Demo mode: the one in use when the demo was turned on is noted, and turning the
    /// demo off goes back to it (a mode chosen in the demo was the demo's). Not while settings aren't saved (persistsSettings)
    func keepMode(acrossDemo on: Bool) {
        guard persistsSettings else { return }
        if on {
            SharedStore.systemBeforeDemo = system
        } else if let before = SharedStore.systemBeforeDemo {
            SharedStore.systemBeforeDemo = nil
            if system != before { system = before }
        }
    }

    /// Walks from this place from now on (Use This Place, in the place picker and on the transit map's cards): it goes first in the
    /// recent places too, unless `remember` is false
    func walk(from place: UserPlace, remember: Bool = true) {
        if remember { SharedStore.remember(place) }
        self.place = place
        locationMode = .manual
    }

    // MARK: - Origin

    enum OriginKind {
        /// Current location from Location Services
        case current
        /// Manually chosen place
        case manual
        /// Wanted the current location, but location was denied or failed; using the manual place for now
        case manualFallback
        /// Demo mode's "My current location": Times Square (DemoData.home), not where the Mac is
        case demoCurrent
    }

    struct Origin {
        var coordinate: Coordinate
        var name: String
        var kind: OriginKind
    }

    /// Where walking starts from (the rules: StartingPlace). Demo mode always has a place: Times Square, or one chosen in it.
    var startingPlace: StartingPlace {
        let tooApproximate = locationAccuracy == .tooApproximate
        if isDemo { return locationMode == .current ? .current : .chosen }
        let failed: Bool
        switch locationState {
        case .denied, .failed: failed = true
        // After an earlier failure, while retrying, keep using the chosen place so the UI doesn't flicker back and forth.
        case .idle, .locating, .located: failed = location.failedAt != nil
        }
        return StartingPlace.of(usesCurrentLocation: locationMode == .current, hasPosition: currentCoordinate != nil,
                                positionTooApproximate: tooApproximate, locationFailed: failed, hasChosenPlace: hasPlace)
    }

    /// There is no starting place and none on its way: nothing nearby can be shown until a place is chosen
    var needsPlace: Bool { startingPlace == .missing }

    /// The current position is too far off to find the stations nearby: nothing nearby is shown (locationTooApproximateText says why) until it gets
    /// better or a place is chosen
    var locationTooApproximate: Bool { startingPlace == .tooApproximate }

    /// How far off the position walking starts from may be (meters): the current position's while it's used ("My current
    /// location", not the demo), else nil
    var usedAccuracy: Double? {
        guard !isDemo, locationMode == .current, currentCoordinate != nil else { return nil }
        return currentAccuracy
    }

    /// How exact that is (the steps: LocationAccuracy)
    var locationAccuracy: LocationAccuracy { LocationAccuracy.of(meters: usedAccuracy) }

    /// The line under the place's name while the position is approximate (the sidebar, Settings, the place picker and the large
    /// widget); nil otherwise
    var locationAccuracyNote: String? {
        guard locationAccuracy == .approximate, let meters = usedAccuracy else { return nil }
        return l10n.f("Your location is approximate, within about %@.", l10n.roughDistance(meters))
    }

    /// Why nothing nearby is shown while the position is too far off
    var locationTooApproximateText: String {
        l10n.f("Your location is too approximate to find nearby stations (within about %@). Choose a place instead.",
               l10n.roughDistance(usedAccuracy ?? LocationAccuracy.tooApproximateFrom))
    }

    /// The starting place isn't known yet but on its way: the first position is being found
    var isLocating: Bool { startingPlace == .locating }

    /// "A place I choose" with no place chosen yet ("Use my location" turned off before any was): the place picker opens by itself
    var opensPickerForPlace: Bool {
        !isDemo && StartingPlace.opensPicker(usesCurrentLocation: locationMode == .current, hasChosenPlace: hasPlace)
    }

    /// Origin for walking time. nil while the first position is being found (isLocating) and when there is no starting place (needsPlace).
    var origin: Origin? {
        if isDemo, locationMode == .current {
            return Origin(coordinate: DemoData.home.coordinate, name: DemoData.home.name, kind: .demoCurrent)
        }
        switch startingPlace {
        case .current:
            guard let c = currentCoordinate else { return nil }
            return Origin(coordinate: c, name: l10n.t("Current location"), kind: .current)
        case .chosen:
            return Origin(coordinate: place.coordinate, name: place.name, kind: .manual)
        case .chosenFallback:
            return Origin(coordinate: place.coordinate, name: place.name, kind: .manualFallback)
        case .locating, .missing, .tooApproximate:
            return nil
        }
    }

    // MARK: - Region (shown in the title bar and widget)

    /// Where the origin is: the region name when in the service area (e.g. "Long Island"), otherwise the place name from Apple Maps (e.g. "Albany, New York").
    /// Only which region is stored; the name is generated in the current language each time, so it follows a language change right away (a stored name would stay in the language it was made in).
    var areaName: String? {
        if isOutsideArea { return outsideAreaName }
        return areaRegion.map { l10n.subRegionName($0) }
    }

    /// When the origin changes, re-determine the region (not when within 200 meters of the last determination).
    /// Determining the region needs no network, so changing places on standby updates right away; Apple Maps is used only to look up names outside the area (not on standby).
    func updateArea(force: Bool = false) {
        guard let c = origin?.coordinate else {
            // No starting place, or a position too far off to use: no area either (while a position is only being found, the
            // last area stays)
            if needsPlace || locationTooApproximate, areaCoordinate != nil || areaRegion != nil || outsideAreaName != nil || isOutsideArea {
                areaTask?.cancel()
                areaCoordinate = nil
                areaRegion = nil
                outsideAreaName = nil
                outsideTimeZone = nil
                isOutsideArea = false
            }
            return
        }
        if !force, let old = areaCoordinate, WalkEstimator.distanceMeters(old, c) < 200,
           areaRegion != nil || outsideAreaName != nil, !(areaNameIsFallback && isActive) { return }
        areaCoordinate = c
        areaNameIsFallback = false
        areaTask?.cancel()
        if let region = MetroSubRegion.of(c) {
            isOutsideArea = false
            areaRegion = region
            outsideAreaName = nil
            outsideTimeZone = nil
            return
        }
        isOutsideArea = true
        areaRegion = nil
        outsideAreaName = nil
        outsideTimeZone = nil
        guard isActive else {
            // No name lookup on standby: use the chosen place's name first (e.g. Albany from favorites), so the region box and widget place name aren't empty;
            // switch to the looked-up name after start
            if let o = origin, o.kind == .manual || o.kind == .manualFallback {
                outsideAreaName = o.name
                areaNameIsFallback = true
            }
            return
        }
        // Outside the area: look up the place name with the Mac's built-in Apple Maps (as for walking routes, no extra location upload), in the app's language
        let locale = language.locale
        let comma = l10n.comma
        areaTask = Task { [weak self] in
            let found = await PlaceNamer.place(of: c, locale: locale, separator: comma)
            guard !Task.isCancelled, let self, self.areaCoordinate == c else { return }
            self.outsideAreaName = found?.name
            self.outsideTimeZone = found?.timeZone
            self.saveSnapshot(widgetsNow: true)
        }
    }

    func locationDidUpdate() {
        locationState = location.state
        locationAccessOff = location.accessOff || location.state == .denied
        // A position is used only while it's wanted (on, "My current location", not the demo): otherwise only the state above changes,
        // and no position is kept or sent to Apple Maps for a place name
        guard isActive, location.needed else { return }
        // "Locating" needs no recompute (otherwise requesting location inside refresh would call refresh again).
        guard location.state != .locating else { return }
        guard let c = location.coordinate else {
            if locationMode == .current { refresh() }
            return
        }
        // How exact it is can change without it moving (macOS finds Wi‑Fi networks after a rougher first position)
        let accuracyStepChanged = LocationAccuracy.of(meters: location.accuracy) != LocationAccuracy.of(meters: currentAccuracy)
        if currentAccuracy != location.accuracy { currentAccuracy = location.accuracy }
        // Don't recompute when the location moved less than 30 meters (location jitters a little), unless how exact it is
        // changed step
        if let old = currentCoordinate, WalkEstimator.distanceMeters(old, c) < 30, !accuracyStepChanged { return }
        currentCoordinate = c
        updateCurrentPlaceName()
        if locationMode == .current { refresh() }
    }

    func updateCurrentPlaceName(force: Bool = false) {
        // Only while the current location is in use (on, "My current location", not the demo). A forced lookup that can't run now
        // (the language changed) runs with the next one instead
        // A position too far off to use isn't named either
        guard isActive, location.needed, let c = currentCoordinate, !locationTooApproximate else {
            if force { currentNameCoordinate = nil }
            return
        }
        if !force, let old = currentNameCoordinate, WalkEstimator.distanceMeters(old, c) < 150, currentPlaceName != nil { return }
        // Last lookup failed (no network, Apple Maps temporarily refused): retry after 5 minutes, not on every refresh (Apple's place name lookup is rate-limited)
        if !force, currentPlaceName == nil, let failed = currentNameFailedAt,
           Date().timeIntervalSince(failed) < Self.placeNameRetrySeconds { return }
        currentNameCoordinate = c
        currentNameTask?.cancel()
        let locale = language.locale
        let comma = l10n.comma
        currentNameTask = Task { [weak self] in
            let name = await PlaceNamer.nearbyName(of: c, locale: locale, separator: comma)
            // Cancelled, moved on, or "Use my location" turned off meanwhile: the name isn't wanted any more
            guard !Task.isCancelled, let self, self.currentNameCoordinate == c, self.locationAllowed else { return }
            self.currentNameTask = nil
            self.currentPlaceName = name
            self.currentNameFailedAt = name == nil ? Date() : nil
        }
    }

    /// Keeps LocationService.needed in step (see LocationNeed). Called before every request, and whenever Start, standby, the location mode,
    /// "Use my location" or the demo changes
    func updateLocationNeed() {
        location.needed = LocationNeed.isNeeded(active: isActive, currentLocation: locationMode == .current,
                                                demo: isDemo, allowed: locationAllowed)
    }

    /// Every "Walk from" switch goes through here (sidebar, menu bar, Settings), so all follow the same rules (see locationModeChange)
    /// - Parameter openPicker: opens the place picker; the mode then changes only once a place is chosen there
    func requestLocationMode(_ mode: LocationMode, openPicker: () -> Void) {
        switch Self.locationModeChange(to: mode, isDemo: isDemo, locationAllowed: locationAllowed,
                                       hasChosenPlace: SharedStore.hasChosenPlace) {
        case .keep: return
        case .openPicker: openPicker()
        case .switchMode: locationMode = mode
        }
    }

    enum LocationModeChange: Equatable { case keep, openPicker, switchMode }

    /// "My current location" can't be chosen with "Use my location" off (in Demo mode it can: there it's Times Square): nothing changes.
    /// "A place I choose" before any place was chosen opens the place picker first (see LocationMode.needsPicker).
    nonisolated static func locationModeChange(to mode: LocationMode, isDemo: Bool, locationAllowed: Bool,
                                               hasChosenPlace: Bool) -> LocationModeChange {
        if mode == .current && !locationAllowed && !isDemo { return .keep }
        return mode.needsPicker(hasChosenPlace: hasChosenPlace) ? .openPicker : .switchMode
    }
}
