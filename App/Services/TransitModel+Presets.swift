import CatchText
import Foundation
import TransitCore

extension TransitModel {
    /// The commute presets: one object for the whole app (CommutePresetCenter)
    var presetCenter: CommutePresetCenter { .shared }

    /// Presets walking from "My current location" can be used: not while "Use my location" is off in Settings (in Demo mode they
    /// can: its current location is Times Square)
    var presetLocationAllowed: Bool { isDemo || locationAllowed }

    /// Whether this preset can be used now, and if not why (CommutePreset.State)
    func presetState(_ preset: CommutePreset) -> CommutePreset.State {
        preset.state(favorites: presetCenter.favorites, locationAllowed: presetLocationAllowed)
    }

    /// The preset in use now, whose button is marked: the first with this starting place and this mode. Nil when either was
    /// changed by hand to something no preset has
    var activePreset: CommutePreset? {
        CommutePresets.active(CommutePresets.shown(presetCenter.presets), fromCurrentLocation: locationMode == .current,
                              place: hasPlace ? place : nil, system: system)
    }

    /// A preset's button was clicked: walks from its place and shows its mode, the same as choosing them by hand (the place goes
    /// first in the recent places too, see walk(from:)). On standby it starts too, as a click on a reminder or "Show trains" on the
    /// map does: a preset is clicked to see its trains. Nothing happens for one that can't be used (its button is gray)
    func usePreset(_ preset: CommutePreset) {
        guard !presetCenter.sampling,
              let change = preset.switched(favorites: presetCenter.favorites, locationAllowed: presetLocationAllowed) else { return }
        // The place first: changing the mode then drops what was worked out for the old place in the old mode
        if let place = change.place {
            walk(from: place)
        } else if locationMode != .current {
            requestLocationMode(.current) {}
        }
        system = change.system
        // Started after both are set, so its first refresh is for them
        if !isActive { start() }
    }

    /// What a preset's button says while the pointer rests on it, and screen readers after its name (CommutePreset.note)
    func presetNote(_ preset: CommutePreset) -> String {
        preset.note(presetState(preset), l: l10n)
    }
}

extension CommutePreset {
    /// Where it walks from and its mode ("Home · Subway") when it can be used; otherwise why not, and what to do. Settings says
    /// the same under its name
    func note(_ state: State, l: UIText) -> String {
        switch state {
        case .ready:
            return l.dotted([placeName ?? l.t("Current location")] + [mode.map { l.modeName($0) }].compactMap { $0 })
        case .placeMissing:
            return l.f("“%@” is no longer in your favorites. Choose a starting place for this preset.", placeName ?? "")
        case .locationOff:
            return l.t("This preset starts from your current location, and location is off in Settings → Privacy.")
        case .modeUnknown:
            return l.t("This preset's transit mode isn't in this version. Choose one again.")
        }
    }
}
