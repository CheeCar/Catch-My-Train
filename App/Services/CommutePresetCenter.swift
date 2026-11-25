import Combine
import Foundation
import TransitCore

/// The commute presets as the app shows them: one object for the whole app. The rules are CommutePresets (TransitCore) and
/// SharedStore saves them; this keeps the list on screen in step. It reads them again when they change (in Settings in any
/// window, or a favorite they walk from was taken out or put back), when the favorites change (a preset walking from one may be
/// usable or not now), and when Demo mode is turned on or off (it has its own; TransitModel.useDemoPlaces). The views that show
/// presets watch this object, which changes only then, not the main model.
@MainActor
final class CommutePresetCenter: ObservableObject {
    static let shared = CommutePresetCenter()

    /// The presets this version can read, in their order (Demo mode's own while it's on)
    @Published private(set) var presets: [CommutePreset] = []
    /// The favorites, to tell which presets can be used (CommutePreset.state)
    @Published private(set) var favorites: [UserPlace] = []
    /// Saved presets this version can't read are kept as they are: Settings says so
    @Published private(set) var hasUnreadable = false

    private var observers: [NSObjectProtocol] = []


    /// Always false: the presets shown are the saved ones
    var sampling: Bool {
        return false
    }

    private init() {
        reload()
        // Posted on the main thread, after the change is saved: read once the posting is over
        for name in [SharedStore.presetsChanged, SharedStore.placesChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            })
        }
    }

    /// Reads the presets, the favorites and whether some presets can't be read, and changes what differs
    func reload() {
        let read = readLists()
        if read.presets != presets { presets = read.presets }
        if read.favorites != favorites { favorites = read.favorites }
        if read.unreadable != hasUnreadable { hasUnreadable = read.unreadable }
    }

    private func readLists() -> (presets: [CommutePreset], favorites: [UserPlace], unreadable: Bool) {
        return (SharedStore.commutePresets, SharedStore.favoritePlaces, SharedStore.hasUnreadablePresets)
    }

    // MARK: Changes from Settings

    /// One more, at the end. Nothing happens when the list is full (Add Preset… is gray then)
    func add(_ preset: CommutePreset) {
        guard !sampling, CommutePresets.canAdd(to: SharedStore.commutePresets) else { return }
        save(SharedStore.commutePresets + [preset])
    }

    /// The preset with this id, changed (CommutePreset.with); nothing when it's gone meanwhile (deleted in another window)
    func update(_ preset: CommutePreset) {
        guard !sampling else { return }
        var list = SharedStore.commutePresets
        guard let i = list.firstIndex(where: { $0.id == preset.id }) else { return }
        list[i] = preset
        save(list)
    }

    func delete(id: String) {
        guard !sampling else { return }
        let list = SharedStore.commutePresets
        guard list.contains(where: { $0.id == id }) else { return }
        save(list.filter { $0.id != id })
    }

    /// One place up (-1) or down (+1)
    func move(id: String, by offset: Int) {
        guard !sampling else { return }
        let list = SharedStore.commutePresets
        let moved = CommutePresets.moved(list, id: id, by: offset)
        if moved != list { save(moved) }
    }

    private func save(_ list: [CommutePreset]) {
        SharedStore.commutePresets = list
        reload()
    }
}
