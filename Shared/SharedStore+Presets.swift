import Foundation
import TransitCore

extension SharedStore {
    /// Posted in the app when the commute presets change (in Settings, or a favorite they walk from was taken out or put back),
    /// so the rows of buttons and Settings read them again
    static let presetsChanged = Notification.Name("CatchMyTrain.presetsChanged")

    /// The commute presets, stored only on this Mac with the favorites (CommutePresetStore keeps the ones it can't read as they
    /// are). Demo mode's own while it's on: they start as the demo's (DemoData.presets) and are gone when it's turned off, and the
    /// user's own are neither shown nor changed meanwhile. The widget never reads them.
    static var commutePresets: [CommutePreset] {
        get {
            if let demoPlaces { return demoPlaces.presets }
            return CommutePresetStore(defaults: defaults).presets
        }
        set {
            if demoPlaces != nil {
                demoPlaces?.presets = newValue
            } else {
                CommutePresetStore(defaults: defaults).presets = newValue
            }
            NotificationCenter.default.post(name: presetsChanged, object: nil)
        }
    }

    /// Saved presets this version can't read are kept (Settings says so); never in Demo mode
    static var hasUnreadablePresets: Bool {
        guard demoPlaces == nil else { return false }
        let store = CommutePresetStore(defaults: defaults)
        return store.unreadableCount > 0 || store.hasUnreadableCopy
    }

    /// Which presets forgot their place when a favorite was taken out, by that favorite, in memory only and only until the app
    /// quits: Undo putting it back (in the place picker, or on the transit map's card) gives them their place again. Demo mode's
    /// and the user's own apart
    private static var forgottenWith: [(favorite: UserPlace, ids: Set<String>, demo: Bool)] = []

    /// A favorite was taken out: the presets walking from it forget where it is and keep only its name (CommutePresets.forgetting),
    /// so the place is gone from this Mac as taking it out asks
    static func forgetInPresets(_ removed: UserPlace) {
        let presets = commutePresets
        let ids = CommutePresets.ids(startingFrom: removed, in: presets)
        guard !ids.isEmpty else { return }
        forgottenWith.append((removed, ids, demoPlaces != nil))
        commutePresets = CommutePresets.forgetting(removed, in: presets)
    }

    /// A favorite was added: the presets that forgot a place of that name when it was taken out walk from it again, though Undo
    /// was missed (CommutePresets.reconnecting)
    static func reconnectPresets(to added: UserPlace) {
        let presets = commutePresets
        let changed = CommutePresets.reconnecting(added, in: presets)
        if changed != presets { commutePresets = changed }
    }

    /// Undo put a favorite back where it was: the presets that forgot it when it was taken out walk from it again, unless another
    /// place was chosen for them since (CommutePresets.remembering)
    static func favoritePutBack(_ favorite: UserPlace) {
        let demo = demoPlaces != nil
        guard let i = forgottenWith.lastIndex(where: { $0.demo == demo && samePlace($0.favorite, favorite) }) else { return }
        let ids = forgottenWith.remove(at: i).ids
        commutePresets = CommutePresets.remembering(favorite, ids: ids, in: commutePresets)
    }
}
