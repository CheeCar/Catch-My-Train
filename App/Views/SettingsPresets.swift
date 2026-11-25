import CatchText
import SwiftUI
import TransitCore

/// Settings, General: the commute presets. Each is a name, where walking starts from and a transit mode; a click on its button in
/// the sidebar or the menu bar's panel switches both (PresetButtons). One row each, in their order, with Change (PresetEditor) and
/// the arrows that move it up and down; Add Preset… under them makes one more, at most four (CommutePresets.limit).
/// It watches the presets, not the main model, which doesn't publish their changes.
struct PresetSettings: View {
    @EnvironmentObject var transit: TransitModel
    @ObservedObject var presets: CommutePresetCenter
    /// The preset being changed, or a new one, while its window is open
    @State private var editing: PresetDraft?

    var body: some View {
        let l = transit.l10n
        let list = presets.presets
        let canAdd = CommutePresets.canAdd(to: list)
        Section {
            Text(l.t("A preset switches your starting place and transit mode in one click."))
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Presets a later version saved, or damaged ones: kept as they are, not shown
            if presets.hasUnreadable {
                Label(l.t("Some saved presets couldn't be read, so they aren't shown. They are kept, in case a later version can read them."),
                      systemImage: "exclamationmark.triangle")
                    .font(.scaled(.caption))
                    .foregroundStyle(Color.noticeOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { index, preset in
                PresetSettingsRow(preset: preset, note: transit.presetNote(preset), usable: transit.presetState(preset) == .ready,
                                  first: index == 0, last: index == list.count - 1, l: l,
                                  change: { editing = PresetDraft(preset: preset, isNew: false) },
                                  move: { presets.move(id: preset.id, by: $0) })
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(l.t("Add Preset…")) { editing = newDraft() }
                    .appButtonStyle()
                    .disabled(!canAdd)
                if !canAdd {
                    Text(l.t("The list is full. Delete a preset to add another."))
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // On this row, which is always there, rather than on the section, whose modifiers can go to each of its rows
            .sheet(item: $editing) { draft in
                PresetEditor(draft: draft, favorites: presets.favorites, otherMode: transit.system,
                             save: { preset in
                                 if draft.isNew { presets.add(preset) } else { presets.update(preset) }
                             },
                             delete: draft.isNew ? nil : { presets.delete(id: draft.preset.id) })
                    .environmentObject(transit)
            }
        } header: {
            Text(l.t("Commute presets"))
                .settingsSectionTitle()
        }
    }

    /// A new preset to start from: walking from where the app walks from now when that is a favorite or "My current location"
    /// (not with "Use my location" off; then the first favorite), in the mode shown now. No name yet: Save needs one
    private func newDraft() -> PresetDraft {
        let favorites = presets.favorites
        let start: CommutePreset.Start
        if transit.locationMode == .manual, let favorite = favorites.first(where: { SharedStore.samePlace($0, transit.place) }) {
            start = .favorite(favorite)
        } else if transit.presetLocationAllowed || favorites.isEmpty {
            start = .currentLocation
        } else {
            start = .favorite(favorites[0])
        }
        let preset = CommutePreset(name: "", place: nil, system: transit.system).with(name: "", start: start, system: transit.system)
        return PresetDraft(preset: preset, isNew: true)
    }
}

/// One preset in Settings: its mode's symbol, its name, and under it where it walks from and its mode, or in orange why it can't
/// be used now; at its end the arrows that move it up and down (only with more than one) and Change. The symbol sits in a column
/// as wide as the widest one a row can show, so the names of the rows start at the same place
private struct PresetSettingsRow: View {
    let preset: CommutePreset
    let note: String
    let usable: Bool
    let first: Bool
    let last: Bool
    let l: UIText
    let change: () -> Void
    let move: (Int) -> Void

    private static let unknownSymbol = "questionmark.circle"
    private static let unusableSymbol = "exclamationmark.triangle"
    /// Every symbol a row can show: the modes', and those of a mode this version doesn't know and of a preset that can't be used
    private static let symbols = TransitSystem.modes.map(\.symbol) + [unknownSymbol, unusableSymbol]

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    ForEach(Self.symbols, id: \.self) { Image(systemName: $0).hidden() }
                    Image(systemName: usable ? (preset.mode?.symbol ?? Self.unknownSymbol) : Self.unusableSymbol)
                        .foregroundStyle(usable ? Color.secondary : Color.noticeOrange)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                    Text(note)
                        .font(.scaled(.caption))
                        .foregroundStyle(usable ? Color.secondary : Color.noticeOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Read as one: the name, then where it walks from (or why it can't be used), all in the name, as macOS reads a
            // value before the name
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(preset.name + l.comma + note))
            if !(first && last) {
                arrow("chevron.up", l.t("Move Up"), enabled: !first) { move(-1) }
                arrow("chevron.down", l.t("Move Down"), enabled: !last) { move(1) }
            }
            Button(l.t("Change"), action: change)
                .appButtonStyle()
                // Screen readers hear which preset too: every row has a button like this one
                .accessibilityLabel(Text(l.t("Change") + l.comma + preset.name))
        }
        .padding(.vertical, 2)
    }

    private func arrow(_ symbol: String, _ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.scaled(.body))
                .frame(minWidth: 16)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(Text(title + l.comma + preset.name))
    }
}

/// What the preset window starts from: a preset to change, or a new one (saved only with Save)
struct PresetDraft: Identifiable {
    var preset: CommutePreset
    var isNew: Bool
    var id: String { preset.id }
}

/// The window that changes a preset or makes one: its name (up to 24 characters), where it walks from (a favorite or "My current
/// location"; a place has to be a favorite first) and its mode. Under them, in orange, why it couldn't be used as it is. Save
/// needs a name; Delete Preset takes a saved one away (no question first: it's only a name and two choices)
struct PresetEditor: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.dismiss) private var dismiss
    let draft: PresetDraft
    /// The favorites to choose from (Demo mode's own while it's on)
    let favorites: [UserPlace]
    let save: (CommutePreset) -> Void
    /// Nil for a new preset
    let delete: (() -> Void)?
    @State private var name: String
    @State private var start: CommutePreset.Start
    @State private var mode: TransitSystem
    /// The preset's mode was one this version doesn't know (saved by a later one): kept as it was until one is chosen here
    @State private var modeChosen: Bool
    /// The list of places to walk from is open
    @State private var showStarts = false

    /// `otherMode`: shown chosen when the preset's own mode is one this version doesn't know
    init(draft: PresetDraft, favorites: [UserPlace], otherMode: TransitSystem, save: @escaping (CommutePreset) -> Void,
         delete: (() -> Void)?) {
        self.draft = draft
        self.favorites = favorites
        self.save = save
        self.delete = delete
        _name = State(initialValue: draft.preset.name)
        // The favorite as it is saved now, when it is one (the same name within 30 m), so the menu shows it chosen
        var start = draft.preset.start
        if case .favorite(let place) = start, let saved = favorites.first(where: { SharedStore.samePlace($0, place) }) {
            start = .favorite(saved)
        }
        _start = State(initialValue: start)
        _mode = State(initialValue: draft.preset.mode ?? otherMode.mode)
        _modeChosen = State(initialValue: draft.preset.mode != nil)
    }

    var body: some View {
        let l = transit.l10n
        let edited = result
        let state = edited.state(favorites: favorites, locationAllowed: transit.presetLocationAllowed)
        VStack(alignment: .leading, spacing: 14) {
            Text(l.t("Commute presets"))
                .font(.scaled(.title3).bold())
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(l.t("Name")) {
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text(l.t("Name")))
                }
                // Where it walks from, as a pop-up button shows its value; a click opens the list to choose from, with a search
                // field (PresetStartList): any favorite can be found there by its name, whatever its place in the user's order
                LabeledContent(l.t("Walk from")) {
                    Button { showStarts = true } label: {
                        AppMenuLabel(text: startName(start, l), plain: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(l.t("Walk from")))
                    .accessibilityValue(Text(startName(start, l)))
                }
                .sheet(isPresented: $showStarts) {
                    PresetStartList(choices: starts(l), chosen: start) { start = $0 }
                        .environmentObject(transit)
                }
                // Where the places come from: only the current location and the favorites
                Text(l.t("Pick your current location or a favorite. To start from another place, add it to your favorites first."))
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingSegments(title: l.t("Transit system"), selection: $mode,
                                choices: TransitSystem.modes.map { SettingChoice($0, SystemSwitcher.name($0, l), symbol: $0.symbol) })
                if state != .ready {
                    Label(edited.note(state, l: l), systemImage: "exclamationmark.triangle")
                        .font(.scaled(.caption))
                        .foregroundStyle(Color.noticeOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if let delete {
                    Button(l.t("Delete Preset"), role: .destructive) {
                        delete()
                        dismiss()
                    }
                    .appButtonStyle()
                }
                Spacer()
                Button(l.t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appButtonStyle()
                Button(l.t("Save")) {
                    save(edited)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .appButtonStyle(.defaultAction)
                .disabled(CommutePresets.cleanName(name) == nil)
            }
        }
        .padding(20)
        .frame(width: (420 * TextScale.factor).rounded())
        .environment(\.locale, transit.language.locale)
        .environment(\.layoutDirection, transit.layoutDirection)
        // No longer than a name can be, as it is typed or pasted
        .onChange(of: name) { _, typed in
            if typed.count > CommutePresets.nameLimit { name = String(typed.prefix(CommutePresets.nameLimit)) }
        }
        .onChange(of: mode) { _, _ in modeChosen = true }
    }

    /// The preset as it would be saved now
    private var result: CommutePreset {
        var preset = draft.preset.with(name: CommutePresets.cleanName(name) ?? name, start: start, system: mode)
        // A mode this version doesn't know stays until one is chosen
        if !modeChosen { preset.system = draft.preset.system }
        return preset
    }

    /// Walk from's choices, as its list shows them (PresetStartList): the preset's own place first when it isn't one of the
    /// favorites now (it was removed, or isn't saved any more), then "My current location", then the favorites
    private func starts(_ l: UIText) -> [(start: CommutePreset.Start, name: String)] {
        var list: [(start: CommutePreset.Start, name: String)] = []
        let own = draft.preset.start
        switch own {
        case .missing:
            list.append((own, startName(own, l)))
        case .favorite(let place) where !favorites.contains(where: { SharedStore.samePlace($0, place) }):
            list.append((own, startName(own, l)))
        default:
            break
        }
        list.append((.currentLocation, l.t("My current location")))
        list += favorites.map { (.favorite($0), $0.name) }
        return list
    }

    private func startName(_ start: CommutePreset.Start, _ l: UIText) -> String {
        switch start {
        case .currentLocation: return l.t("My current location")
        case .favorite(let place): return place.name
        case .missing(let name): return name
        }
    }
}

/// The list a commute preset's Walk from opens: a title, a search field, then the preset's own place when it isn't a favorite now,
/// "My current location" and every favorite, in the user's order (up to 50; the list scrolls), the chosen one checked. Typing
/// shows only the favorites with every word typed in their name (PlaceLists.search), or a sentence when there is none. A click
/// on a row chooses it and closes the list; Return chooses the first one found when something is typed, else only closes it;
/// Cancel and Esc close it and change nothing. Built like the list of languages (LanguageListSheet)
struct PresetStartList: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.dismiss) private var dismiss
    /// As the menu had them: the preset's own place first when it isn't a favorite now, then "My current location", then the
    /// favorites (PresetEditor.starts)
    let choices: [(start: CommutePreset.Start, name: String)]
    let chosen: CommutePreset.Start
    let choose: (CommutePreset.Start) -> Void
    @State private var search: String
    @FocusState private var searchFocused: Bool

    /// `search`: text in the search field as the list opens
    init(choices: [(start: CommutePreset.Start, name: String)], chosen: CommutePreset.Start, search: String = "",
         choose: @escaping (CommutePreset.Start) -> Void) {
        self.choices = choices
        self.chosen = chosen
        self.choose = choose
        _search = State(initialValue: search)
    }

    var body: some View {
        let l = transit.l10n
        let typed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // The rows before the favorites: the preset's own place when it isn't a favorite now, and "My current location"
        let split = (choices.firstIndex { $0.start == .currentLocation } ?? -1) + 1
        let others = Array(choices.prefix(split))
        let favorites = choices.dropFirst(split).compactMap { choice -> UserPlace? in
            if case .favorite(let place) = choice.start { return place }
            return nil
        }
        let found = PlaceLists.search(search, in: favorites)
        let field = RoundedRectangle(cornerRadius: 6)
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("Walk from"))
                .font(.scaled(.title3).bold())
                .accessibilityAddTraits(.isHeader)
            // A magnifying glass, then the text: one box, drawn like the list of languages' field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(l.t("Search favorites"), text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if !typed.isEmpty, let first = found.first {
                            pick(.favorite(first))
                        } else {
                            dismiss()
                        }
                    }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(field.fill(Color(nsColor: .textBackgroundColor)))
            .overlay(field.strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
            .overlay {
                if searchFocused {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5), lineWidth: 3).padding(-2)
                }
            }
            // As tall with one row as with all of them, so the window doesn't jump while typing
            ScrollView(.vertical) {
                if !typed.isEmpty && found.isEmpty {
                    Text(l.f("No favorites match “%@”.", typed))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                } else {
                    // A plain stack, not a lazy one: its two lists of rows both count from 0, and a lazy stack shows only one row
                    // for each number (the first favorite went blank under "My current location"). At most about 50 rows
                    VStack(alignment: .leading, spacing: 0) {
                        if typed.isEmpty {
                            ForEach(Array(others.enumerated()), id: \.offset) { index, choice in
                                if index > 0 { Divider().padding(.horizontal, AreaListRow.sidePadding) }
                                LanguageChoiceRow(name: choice.name, second: nil, spoken: choice.name,
                                                  chosen: choice.start == chosen) { pick(choice.start) }
                            }
                            if !favorites.isEmpty {
                                sectionTitle(l.t("Favorite places"))
                            }
                        }
                        ForEach(Array((typed.isEmpty ? favorites : found).enumerated()), id: \.offset) { index, place in
                            if index > 0 { Divider().padding(.horizontal, AreaListRow.sidePadding) }
                            LanguageChoiceRow(name: place.name, second: nil, spoken: place.name,
                                              chosen: chosen == .favorite(place)) { pick(.favorite(place)) }
                        }
                    }
                }
            }
            .frame(height: 300 * TextScale.factor)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            .contrastBorder(cornerRadius: 8)
            HStack {
                Spacer()
                Button(l.t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appButtonStyle()
            }
        }
        // The rows' names follow the text size, as in the Settings window
        .font(.scaled(.body))
        .padding(20)
        .frame(width: 400 + 200 * (TextScale.factor - 1))
        .environment(\.locale, transit.language.locale)
        .environment(\.layoutDirection, transit.layoutDirection)
        .onExitCommand { dismiss() }
        .onAppear { searchFocused = true }
    }

    private func pick(_ start: CommutePreset.Start) {
        choose(start)
        dismiss()
    }

    /// A small gray title over a part of the list, for screen readers a heading
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.scaled(.caption).weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, AreaListRow.sidePadding)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}
