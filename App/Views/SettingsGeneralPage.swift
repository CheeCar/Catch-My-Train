import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// Settings, General page: language, units, clock, text size and appearance, then the commute presets and the keyboard shortcuts.
struct GeneralSettingsPage: View {
    @EnvironmentObject var transit: TransitModel

    var body: some View {
        let l = transit.l10n
        let general = GeneralChoices(l)
        SettingsPageForm(.general) {
            SettingsSection(AppLanguage.otherLanguagesEnabled ? l.t("Language and units") : l.t("Units and appearance")) {
                // The Language row (set otherLanguagesEnabled to false to hide it and return the UI to English): a click opens the
                // list of languages with its search field (LanguageListSheet): "System Language (<the Mac's language now>)", which
                // follows the Mac, the suggested ones, then every language.
                // Switching to a language with a different layout direction (left-to-right ↔ right-to-left, either way): don't switch right away; ask in a dialog first,
                // and on confirm switch and restart automatically; on cancel keep the old language.
                if AppLanguage.otherLanguagesEnabled {
                    LanguageSetting()
                    // Restart after switching language failed
                    if let err = transit.relaunchError {
                        Text(err).font(.scaled(.caption)).foregroundStyle(Color.noticeRed)
                    }
                }
                // The app's own segmented switches (SettingSegments), so they slide like the ones in the main window.
                // All four are as wide as the widest of them, so they line up on both sides
                SettingSegments(title: general.unitsTitle, selection: deferred(\.units), choices: general.units, group: general.group)
                // 12 / 24-hour clock; all clock times change together, widgets too
                SettingSegments(title: general.clockTitle, selection: deferred(\.clock), choices: general.clock, group: general.group)
                SettingSegments(title: general.textSizeTitle, selection: deferred(\.textSize), choices: general.textSize, group: general.group)
                SettingSegments(title: general.appearanceTitle, selection: deferred(\.appearance), choices: general.appearance, group: general.group)
            }

            // The commute presets: made and changed here, used from the sidebar and the menu bar's panel
            PresetSettings(presets: transit.presetCenter)

            // Menu bar shortcuts: list them all; click one and press a new key to change it
            ShortcutSettings()
        }
    }

    /// Segmented controls and menus in Settings: after a tap, change the data once this UI update pass ends, and not at all if the value didn't change (see Binding.afterViewUpdate).
    private func deferred<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<TransitModel, T>) -> Binding<T> {
        let model = transit
        return Binding.afterViewUpdate(get: { model[keyPath: keyPath] }, set: { model[keyPath: keyPath] = $0 })
    }
}

/// The switches under the first Settings heading, made in one place so each can be measured against the others (SettingSegments.group)
private struct GeneralChoices {
    let unitsTitle: String
    let clockTitle: String
    let textSizeTitle: String
    let appearanceTitle: String
    let units: [SettingChoice<DistanceUnit>]
    let clock: [SettingChoice<ClockStyle>]
    let textSize: [SettingChoice<AppTextSize>]
    let appearance: [SettingChoice<AppAppearance>]

    init(_ l: UIText) {
        unitsTitle = l.t("Distance units")
        clockTitle = l.t("Time format")
        textSizeTitle = l.t("Text size")
        appearanceTitle = l.t("Appearance")
        units = [SettingChoice(DistanceUnit.usCustomary, l.t("US feet (ft, mph)")), SettingChoice(DistanceUnit.metric, l.t("Meters (m, km/h)"))]
        clock = [SettingChoice(ClockStyle.twelveHour, l.t("12-hour")), SettingChoice(ClockStyle.twentyFourHour, l.t("24-hour"))]
        textSize = [SettingChoice(AppTextSize.standard, l.t("Default")), SettingChoice(AppTextSize.large, l.t("Large")),
                    SettingChoice(AppTextSize.larger, l.t("Larger"))]
        appearance = [SettingChoice(AppAppearance.system, l.t("System"), symbol: "circle.lefthalf.filled"),
                      SettingChoice(AppAppearance.light, l.t("Light"), symbol: "sun.max"),
                      SettingChoice(AppAppearance.dark, l.t("Dark"), symbol: "moon")]
    }

    var group: SegmentGroup {
        SegmentGroup(titles: [unitsTitle, clockTitle, textSizeTitle, appearanceTitle],
                     choices: [units.map(\.text), clock.map(\.text), textSize.map(\.text), appearance.map(\.text)])
    }
}

/// "Keyboard shortcuts" in Settings: each item is ⌘ plus one key, or none. Click the key on the right, then press a new key;
/// Delete removes the key, Esc cancels. Keys used by macOS itself (⌘Q, ⌘W, ⌘H, ⌘M, ⌘, and so on) or already used by another item
/// aren't allowed.
struct ShortcutSettings: View {
    @EnvironmentObject var transit: TransitModel
    @State private var recording: AppShortcut?
    @State private var message: String?
    @State private var monitor: Any?
    /// The window recording started in (this Settings window): only keys pressed there set a shortcut
    @State private var recordingWindow: Int?

    var body: some View {
        let l = transit.l10n
        Section {
            Toggle(l.t("Use keyboard shortcuts"), isOn: $transit.shortcutsEnabled)
                .onChange(of: transit.shortcutsEnabled) { _, on in
                    if !on { recording = nil; message = nil }
                }
            ForEach(AppShortcut.allCases, id: \.self) { s in
                LabeledContent(AppShortcuts.name(s, transit)) {
                    Button {
                        message = nil
                        recording = recording == s ? nil : s
                    } label: {
                        Text(recording == s ? l.t("Press a key…") : transit.shortcuts.key(for: s).map(AppShortcuts.display) ?? l.t("None"))
                            .monospacedDigit()
                            .frame(minWidth: 90)
                    }
                    // While it waits for a key: tinted at Standard, blue when the app draws it
                    .appButtonStyle(recording == s && TextScale.factor != 1 ? .prominent : .bordered)
                    .tint(recording == s ? .accentColor : nil)
                }
                .disabled(!transit.shortcutsEnabled)
            }
            if let message {
                Text(message).font(.scaled(.caption)).foregroundStyle(Color.noticeOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(l.t("Click a shortcut, then press the new key. Delete removes it; Esc cancels."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(l.t("Restore Defaults")) {
                    recording = nil
                    message = nil
                    transit.shortcuts.restoreDefaults()
                }
                .appButtonStyle()
                .disabled(transit.shortcuts.isDefault || !transit.shortcutsEnabled)
            }
        } header: {
            Text(l.t("Keyboard shortcuts"))
                .settingsSectionTitle()
        }
        .onChange(of: recording) { _, now in
            if now == nil { stopListening() } else { startListening() }
        }
        // Clicking into another window ends recording
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if recording != nil, let n = recordingWindow, (note.object as? NSWindow)?.windowNumber == n { recording = nil }
        }
        .onDisappear {
            recording = nil
            stopListening()
        }
    }

    private func startListening() {
        guard monitor == nil else { return }
        // Clicking the shortcut made this Settings window the key window. Kept as its number, so the callback below captures only a plain value
        let window = NSApp.keyWindow?.windowNumber
        recordingWindow = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Key events arrive on the main thread
            let code = event.keyCode
            let flags = event.modifierFlags
            // The key as it is, and as it is with ⌘ held, for keyboard layouts that type other scripts (AppShortcut.recordedKey)
            let key = event.charactersIgnoringModifiers
            let withCommand = event.characters
            let here = window != nil && event.windowNumber == window
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let s = recording else { return false }
                // Only keys pressed in this Settings window set a shortcut; one typed in another window ends recording and goes through
                guard here else {
                    recording = nil
                    return false
                }
                handle(keyCode: code, flags: flags, key: key, withCommand: withCommand, for: s)
                return true
            }
            return used ? nil : event   // the key press is only used to set the shortcut and doesn't trigger the menu
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingWindow = nil
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, key: String?, withCommand: String?, for s: AppShortcut) {
        let l = transit.l10n
        if keyCode == 53 {   // Esc
            recording = nil
            return
        }
        // Delete (⌫, or ⌦ on a full keyboard), with or without ⌘: the item has no key from now on
        if keyCode == 51 || keyCode == 117 {
            transit.shortcuts.removeKey(for: s)
            message = nil
            recording = nil
            return
        }
        // Only ⌘ plus one key (pressing a key without ⌘ also works); Shift, Option or Control can't be added
        let extra = flags.intersection([.shift, .option, .control])
        // Function and arrow keys also count as one character in macOS (private use area from 0xF700) and show as boxes: accept only
        // letters, digits and common symbols. On a layout for another script, the Latin character the key gives with ⌘ held
        guard extra.isEmpty, let key = AppShortcut.recordedKey(plain: key, withCommand: withCommand) else {
            message = l.t("Use ⌘ and one other key: a letter, number or symbol.")
            return
        }
        switch transit.shortcuts.problem(with: key, for: s) {
        case nil:
            transit.shortcuts.set(key, for: s)
            message = nil
            recording = nil
        case .notAllowed:
            message = l.t("Use ⌘ and one other key: a letter, number or symbol.")
        case .reserved:
            message = l.f("%@ is used by macOS.", AppShortcuts.display(key))
        case .usedBy(let other):
            message = l.f("%@ is already used by %@.", AppShortcuts.display(key), AppShortcuts.name(other, transit))
        }
    }
}

/// Confirmation before switching to a language with a different layout direction: shown in the new language's text and direction (the language was just chosen, so it can be read),
/// so when switching from Urdu back to English this small area is also normal left-to-right (English right-aligned looks messy).
struct LanguageRestartSheet: View {
    @EnvironmentObject var transit: TransitModel
    var language: AppLanguage

    var body: some View {
        let l = UIText(language: language, units: transit.units, clock: transit.clock)
        VStack(alignment: .leading, spacing: 12) {
            Text(l.t("Restart Catch My Train to switch languages?"))
                .font(.scaled(.headline))
            Text(l.t("This language uses a different layout direction, so Catch My Train restarts to switch. Your settings and places stay the same."))
                .font(.scaled(.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(l.t("Cancel"), role: .cancel) { transit.pendingLanguage = nil }
                    .keyboardShortcut(.cancelAction)
                    .appButtonStyle()
                Button(l.t("Restart Now")) { transit.confirmPendingLanguage() }
                    .keyboardShortcut(.defaultAction)
                    .appButtonStyle(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.locale, language.locale)
    }
}
