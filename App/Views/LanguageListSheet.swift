import CatchText
import Combine
import SwiftUI
import TransitCore

/// What was chosen in the list of languages: to follow the Mac's language, or one language
enum LanguageListChoice: Equatable {
    case followMac
    case language(AppLanguage)

    /// As TransitModel.chooseLanguage takes it: nil follows the Mac
    var language: AppLanguage? {
        if case .language(let language) = self { return language }
        return nil
    }
}

/// Settings, General: the Language row. The language in use, as a pop-up button shows its value; a click opens the list of
/// languages (LanguageListSheet). What is chosen there is switched to once the list has closed (TransitModel.chooseLanguage),
/// so the question before a restart (a language written in the other direction, LanguageRestartSheet) comes after the list,
/// not over it
struct LanguageSetting: View {
    @EnvironmentObject var transit: TransitModel
    @State private var showList = false
    /// Chosen in the list: switched to as the list closes
    @State private var picked: LanguageListChoice?

    var body: some View {
        let l = transit.l10n
        let value = transit.languageFollowsMac ? LanguageListSheet.systemName(l) : transit.language.nativeName
        LabeledContent(l.t("Language")) {
            Button { showList = true } label: {
                AppMenuLabel(text: value, plain: true)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(Text(l.t("Language")))
            .accessibilityValue(Text(value))
            // On the button, not on the row, which has the list's sheet
            .sheet(item: Binding.afterViewUpdate(get: { transit.pendingLanguage },
                                                 set: { transit.pendingLanguage = $0 })) { lang in
                LanguageRestartSheet(language: lang)
                    .environmentObject(transit)
            }
        }
        .sheet(isPresented: $showList, onDismiss: {
            guard let choice = picked else { return }
            picked = nil
            transit.chooseLanguage(choice.language)
        }) {
            LanguageListSheet(choose: { picked = $0 })
                .environmentObject(transit)
        }
    }
}

/// The list of languages the Language row opens: a title, a search field, then "System Language (…)", the suggested languages
/// (the Mac's own languages the app has, LanguageList.suggested) and every language (LanguageList.rows), each by its own name and,
/// in gray after it, its name in the language the app is shown in; the one in use checked. Typing shows only the languages with
/// every word typed in their names or code (LanguageList.search), or a sentence when there is none. A click on a row chooses it
/// and closes the list; Return chooses the first one found when something is typed, else only closes it; Cancel and Esc close
/// it and change nothing. Built like the full list of areas (AreaListSheet)
struct LanguageListSheet: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.dismiss) private var dismiss
    let choose: (LanguageListChoice) -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    /// "System Language (<the Mac's language now, by its own name>)": the row and the Language row's value while the app follows
    /// the Mac
    static func systemName(_ l: UIText) -> String {
        l.f("System Language (%@)", AppLanguage.macLanguage(preferred: Locale.preferredLanguages).nativeName)
    }

    var body: some View {
        let l = transit.l10n
        let rows = LanguageList.rows(in: transit.language)
        let typed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = LanguageList.search(search, in: rows)
        let suggested = LanguageList.suggested(preferred: Self.preferred).compactMap { language in
            rows.first { $0.language == language }
        }
        let current: LanguageListChoice = transit.languageFollowsMac ? .followMac : .language(transit.language)
        let field = RoundedRectangle(cornerRadius: 6)
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("Language"))
                .font(.scaled(.title3).bold())
                .accessibilityAddTraits(.isHeader)
            // A magnifying glass, then the text: one box, drawn like the full list of areas' field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(l.t("Search languages"), text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if !typed.isEmpty, let first = found.first {
                            pick(.language(first.language))
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
                // The focus ring, outside the edge like the system's
                if searchFocused {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5), lineWidth: 3).padding(-2)
                }
            }
            // As tall with one row as with all of them, so the window doesn't jump while typing
            ScrollView(.vertical) {
                if !typed.isEmpty && found.isEmpty {
                    Text(l.f("No languages match “%@”.", typed))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if typed.isEmpty {
                            LanguageChoiceRow(name: Self.systemName(l), second: nil, spoken: Self.systemName(l),
                                              chosen: current == .followMac) { pick(.followMac) }
                            if !suggested.isEmpty {
                                sectionTitle(l.t("Suggested"))
                                languageRows(LanguageList.items(suggested, in: .suggested), current: current, l: l)
                            }
                            sectionTitle(l.t("All languages"))
                        }
                        languageRows(LanguageList.items(typed.isEmpty ? rows : found, in: .all), current: current, l: l)
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
        .frame(width: 440 + 200 * (TextScale.factor - 1))
        .environment(\.locale, transit.language.locale)
        .environment(\.layoutDirection, transit.layoutDirection)
        .onExitCommand { dismiss() }
        .onAppear {
            searchFocused = true
        }
    }

    /// The Mac's languages, most preferred first: what the suggested rows come from
    private static var preferred: [String] {
        return Locale.preferredLanguages
    }

    private func pick(_ choice: LanguageListChoice) {
        choose(choice)
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

    /// One part's rows. Their ids are the part's own (LanguageListItem): the suggested languages are under "All languages" too,
    /// and the same id twice in this lazy list drew the second row blank
    @ViewBuilder
    private func languageRows(_ items: [LanguageListItem], current: LanguageListChoice, l: UIText) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let row = item.row
            if index > 0 { Divider().padding(.horizontal, AreaListRow.sidePadding) }
            LanguageChoiceRow(name: row.nativeName, second: row.secondName,
                              spoken: row.secondName.map { row.nativeName + l.comma + $0 } ?? row.nativeName,
                              chosen: current == .language(row.language)) { pick(.language(row.language)) }
        }
    }
}

/// A row of the list of languages (and of a commute preset's list of places to walk from): a checkmark before the one in use,
/// the language's own name and, in gray, its name in the app's language; under the first when the two don't fit side by side.
/// Each name is a text of its own, so each runs in its own direction (a Hebrew name in an English list). A click anywhere in the
/// row chooses it; under the pointer it lights up like a suggestion of the app's search fields (blue with white text), as the
/// full list of areas does (AreaChoiceRow)
struct LanguageChoiceRow: View {
    let name: String
    let second: String?
    /// What screen readers say: both names
    let spoken: String
    let chosen: Bool
    let choose: () -> Void
    @State private var hovered = false

    /// Written out, so other files can make one (a commute preset's list of places to walk from, PresetStartList): the
    /// memberwise one is private, as `hovered` is
    init(name: String, second: String?, spoken: String, chosen: Bool, choose: @escaping () -> Void) {
        self.name = name
        self.second = second
        self.spoken = spoken
        self.chosen = chosen
        self.choose = choose
    }

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.scaled(.caption).weight(.semibold))
                    .opacity(chosen ? 1 : 0)
                    .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(name)
                        if let second { secondName(second) }
                    }
                    .lineLimit(1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .fixedSize(horizontal: false, vertical: true)
                        if let second {
                            secondName(second)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AreaListRow.sidePadding)
            .padding(.vertical, AreaListRow.edgePadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovered ? Color.white : Color.primary)
        .background {
            if hovered {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor).padding(.horizontal, 5).padding(.vertical, 2)
            }
        }
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(spoken))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func secondName(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(hovered ? Color.white.opacity(0.8) : Color.secondary)
    }
}

