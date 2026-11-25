import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

extension SubwayMapView {
    /// Frames the whole service area when the empty page asked for it (MapWindow.open(with:showingServiceArea:))
    func showServiceAreaIfAsked() {
        // Once the map and its buttons' panel have their places, so it's fitted clear of them
        guard MapWindow.serviceAreaPending, mapFrame.width > 0, !overlayFrames.isEmpty else { return }
        MapWindow.serviceAreaPending = false
        showServiceArea()
    }

    func showServiceArea() {
        serviceAreaRefit?.cancel()
        serviceAreaRefit = nil
        let fit = serviceAreaFit()
        let fitted: MapCameraPosition = fit.map { MapCameraPosition.rect($0.rect) } ?? .region(ServiceAreaMap.region)
        position = fitted
        serviceAreaShown = fitted
        serviceAreaFitted = fit
        serviceAreaMeasuring = fit != nil
        serviceAreaAsked = fit?.rect
        serviceAreaCorrections = 0
        if let fit {
            noteServiceAreaFit("fitted to the place \(Self.box(fit.place).text) of a map view \(Int(fit.size.width))x\(Int(fit.size.height))")
        }
    }

    static func box(_ r: CGRect) -> ServiceArea.Box {
        ServiceArea.Box(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }

    /// At most this many corrections after Service Area fits the map: two were enough in a simulation of the ways MapKit was seen
    /// to be off (larger, moved, or a stop measured before it took the ask); a third for good measure
    static let maxServiceAreaCorrections = 3

    /// Each time the map stops where Service Area put it: where the rings really are (worked out from the area the map reported at
    /// that stop, MapScreen, in the map's own points, whose top is `hiddenTop` below MapKit's view's), against where they should be
    /// in the place they were fitted to. MapKit doesn't always show an area exactly as asked (the rings came out about 6% larger, or
    /// moved), and a stop can come before it took the last ask, so every stop is measured and, while the rings aren't in place, the
    /// map is asked again from where they really are (ServiceArea.check), at most maxServiceAreaCorrections times. Each step goes to
    /// the log. True while the map is still being put in place (asked again, or about to be fitted again).
    /// `screen` nil (turned or tilted, or no area at the view's size): nothing measured at this stop
    func measureServiceArea(_ screen: MapScreen?) -> Bool {
        guard let shown = serviceAreaShown, position == shown else { return false }
        // The window or the panel is changing: fitted again once they stop (fitServiceAreaAgain)
        guard serviceAreaRefit == nil else { return true }
        guard serviceAreaMeasuring, let fit = serviceAreaFitted, let asked = serviceAreaAsked else { return false }
        let stop = "stop \(serviceAreaCorrections + 1): "
        let gaveUp = "; gave up after \(Self.maxServiceAreaCorrections) corrections"
        // A change fitServiceAreaAgain didn't hear of: fitted again, which counts as a correction (so this can't go on and on)
        if let now = serviceAreaFit(), !now.samePlace(as: fit) {
            guard serviceAreaCorrections < Self.maxServiceAreaCorrections else {
                noteServiceAreaFit(stop + "the window or the panel changed since it was fitted" + gaveUp)
                serviceAreaMeasuring = false
                return false
            }
            let corrections = serviceAreaCorrections + 1
            noteServiceAreaFit(stop + "the window or the panel changed since it was fitted, so fitted again")
            showServiceArea()
            serviceAreaCorrections = corrections
            return true
        }
        let points = ServiceAreaMap.ringPoints
        let drawn = points.compactMap { screen?.point($0) }
        guard drawn.count == points.count else { return false }
        let world = MKMapRect.world
        guard let check = ServiceArea.check(points, asked: ServiceArea.Box(x: asked.minX / world.width, y: asked.minY / world.height,
                                                                           width: asked.width / world.width, height: asked.height / world.height),
                                            drawn: drawn.map { (x: Double($0.x), y: Double($0.y + fit.hiddenTop)) },
                                            view: (Double(fit.size.width), Double(fit.size.height)),
                                            visible: (Double(fit.place.minX), Double(fit.place.minY),
                                                      Double(fit.place.width), Double(fit.place.height))) else {
            noteServiceAreaFit(stop + "nothing to measure")
            serviceAreaMeasuring = false
            return false
        }
        guard !check.inPlace else {
            noteServiceAreaFit(stop + check.text + "; in place")
            serviceAreaMeasuring = false
            return false
        }
        guard let next = check.next else {
            noteServiceAreaFit(stop + check.text + "; too far off to be MapKit's own way (moved by hand?), left as it is")
            serviceAreaMeasuring = false
            return false
        }
        guard serviceAreaCorrections < Self.maxServiceAreaCorrections else {
            noteServiceAreaFit(stop + check.text + gaveUp)
            serviceAreaMeasuring = false
            return false
        }
        serviceAreaCorrections += 1
        let rect = MKMapRect(x: next.x * world.width, y: next.y * world.height, width: next.width * world.width,
                             height: next.height * world.height)
        noteServiceAreaFit(stop + check.text + "; asked again")
        let corrected: MapCameraPosition = .rect(rect)
        position = corrected
        serviceAreaShown = corrected
        serviceAreaAsked = rect
        return true
    }

    /// A step of fitting the service area: in the log, a line or a few each time Service Area is used
    private func noteServiceAreaFit(_ text: String) {
        AppLog.ui.notice("Service area fit: \(text, privacy: .public)")
    }

    /// The window got a new size, or the panel a new place, while the map still shows what Service Area put there: fitted again
    /// once they have stopped changing for 0.3 s (a window being resized changes many times a second), and the map's stops
    /// meanwhile aren't measured (measureServiceArea). Not when only the station card came or went and the rings are in place
    func fitServiceAreaAgain() {
        guard let shown = serviceAreaShown, position == shown else { return }
        serviceAreaRefit?.cancel()
        serviceAreaRefit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            serviceAreaRefit = nil
            guard let shown = serviceAreaShown, position == shown else { return }
            if !serviceAreaMeasuring, let now = serviceAreaFit(), let was = serviceAreaFitted, now.samePlace(as: was) { return }
            noteServiceAreaFit("the window or the panel changed, so fitted again")
            showServiceArea()
        }
    }

    /// The whole service area, clear of the toolbar the map runs on under, of the buttons' panel and of the edges. MapKit frames a
    /// region in its whole view, toolbar strip included: with only the region, the north of Greater Boston went under the legend.
    /// Nil before the map has a size
    private func serviceAreaFit() -> ServiceAreaMap.Fit? {
        let hiddenTop = max(0, mapFrame.minY)
        let size = CGSize(width: mapFrame.width, height: mapFrame.height + hiddenTop)
        // The panel at the top (the station card at the bottom comes and goes)
        let panel = overlayFrames.min { $0.minY < $1.minY }
        return ServiceAreaMap.fit(size: size, hiddenTop: hiddenTop, panel: panel)
    }
}
