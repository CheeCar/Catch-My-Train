import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    /// Language when the app opens
    nonisolated static var launchLanguage: AppLanguage { launchSetting.language }
    /// Language when the app opens, and whether it follows the Mac (AppLanguage.atLaunch): with "System Language" chosen, or on a new install
    /// with no language saved yet, the first of the Mac's languages the app has; a Mac updating from an older version keeps English, which it
    /// showed before the update. Saved here, so the widget reads the same language.
    nonisolated static let launchSetting: (language: AppLanguage, followsMac: Bool) = {
        guard AppLanguage.otherLanguagesEnabled else { return (SharedStore.language, false) }
        let launch = AppLanguage.atLaunch(saved: SharedStore.hasSavedLanguage ? SharedStore.language : nil,
                                          followsMac: SharedStore.languageFollowsMac, isNewInstall: isFirstLaunch,
                                          preferred: Locale.preferredLanguages)
        // The tests' host saves nothing (see isTestHost)
        if !TransitModel.isTestHost {
            SharedStore.language = launch.language
            SharedStore.languageFollowsMac = launch.followsMac
        }
        return launch
    }()
    /// The app has never run on this Mac: the activity state it saves at its first launch isn't there yet.
    /// Read before anything of this launch is saved (CatchMyTrainLaunch works out the language and appearance first).
    nonisolated static let isFirstLaunch: Bool = SharedStore.loadActivity() == nil
    /// Appearance when the app opens. No appearance saved yet: a new install follows the Mac (System); a Mac updating from an older version
    /// keeps Light, which it showed before the update. Saved once, so it stays so; not by the tests' host,
    /// which saves no settings (see persistsSettings).
    nonisolated static let launchAppearance: AppAppearance = {
        guard !SharedStore.hasSavedAppearance else { return SharedStore.appearance }
        let firstAppearance: AppAppearance = isFirstLaunch ? .system : .light
        if !TransitModel.isTestHost { SharedStore.appearance = firstAppearance }
        return firstAppearance
    }()
    /// Running as the host of the app tests (xcodebuild test): the app only has to load, so it doesn't locate, download, read the Keychain
    /// or change what this Mac's own copy of the app uses (settings, favorites, the widget's files); only the one-time upgrades of older
    /// saved settings may still run, which change nothing once done. Debug builds only; Xcode's test runner is what sets these variables.
    nonisolated static let isTestHost: Bool = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains { environment[$0] != nil }
        #else
        return false
        #endif
    }()

    /// The saved shortcuts. On the first launch of a version where Nearby and Start / Standby have no default key, someone who had
    /// turned shortcuts on keeps ⌘N and ⌘S for them (ShortcutMap.keepEarlierDefaults); a mark on this Mac (not shared with the
    /// widget) says it's done, so Restore Defaults later isn't undone at the next launch. The log gets one line of counts: whether
    /// the switch was ever switched, how many items are changed, and on that first launch how many kept their earlier key
    nonisolated static func loadShortcuts() -> ShortcutMap {
        let defaults = UserDefaults.standard
        var map = ShortcutMap.decode(defaults.data(forKey: "keyboardShortcuts"))
        let switched = defaults.object(forKey: "keyboardShortcutsEnabled") as? Bool
        let switchText = switched.map { $0 ? "on" : "off" } ?? "never switched (on)"
        guard !defaults.bool(forKey: "keyboardShortcutsKeptEarlierKeys") else {
            AppLog.ui.notice("Keyboard shortcuts: switch \(switchText, privacy: .public), \(map.custom.count, privacy: .public) changed")
            return map
        }
        let changedBefore = map.custom.count
        if switched == true {
            map.keepEarlierDefaults()
            defaults.set(map.encoded(), forKey: "keyboardShortcuts")
        }
        defaults.set(true, forKey: "keyboardShortcutsKeptEarlierKeys")
        AppLog.ui.notice("Keyboard shortcuts: switch \(switchText, privacy: .public), \(changedBefore, privacy: .public) changed before; first launch without the earlier default keys: \(map.custom.count - changedBefore, privacy: .public) kept")
        return map
    }

    /// Read the Bus Time key and NJ Transit account from the Keychain in the background (only record whether they exist; the key itself stays in busKeyCache, never written elsewhere).
    func loadKeys() {
        Task { [weak self] in
            let reads = await Task.detached(priority: .userInitiated) {
                KeychainStore.readKeys(bus: true, account: true, suffolk: true)
            }.value
            guard let self else { return }
            // An account saved or deleted in Settings while reading takes precedence
            let gained = self.applyKeys(reads, account: !self.accountTouched)
            self.keysLoaded = true
            self.verifyUntestedCredentials()
            if gained { self.refresh() }
        }
    }

    /// Settings' retry line: reads again a key or the account the Keychain couldn't read (this may show the system's Keychain prompt).
    /// Both NJ Transit credentials are the same account.
    func retryKeychainRead(_ credential: Credential) {
        guard !retryingKeychainRead else { return }
        let bus = credential == .busTime && busKeyUnreadable
        let suffolk = credential == .suffolk && suffolkKeyUnreadable
        let account = (credential == .njTransitRail || credential == .njTransitBus) && njTransitAccountUnreadable
        guard bus || account || suffolk else { return }
        retryingKeychainRead = true
        Task { [weak self] in
            let reads = await Task.detached(priority: .userInitiated) {
                KeychainStore.readKeys(bus: bus, account: account, suffolk: suffolk)
            }.value
            guard let self else { return }
            self.retryingKeychainRead = false
            // A save or removal while reading settled the account and cleared the flag: its result takes precedence
            let gained = self.applyKeys(reads, account: self.njTransitAccountUnreadable)
            self.verifyUntestedCredentials()
            if gained { self.refresh() }
        }
    }

    /// Records what a Keychain read found (a key saved or deleted in Settings while reading takes precedence; account: whether the account read
    /// may still be used). A failed read leaves everything as it was and only marks the item unreadable. Returns whether a refresh should run
    /// again: only when a key or account was actually read (without one the earlier refresh is already correct).
    private func applyKeys(_ reads: KeychainStore.Reads, account useAccount: Bool) -> Bool {
        var gained = false
        if let busKey = reads.busKey, busKeyCache == nil {
            // A key a removal left in the Keychain is never used, even when it can be read (so there's nothing to read again either)
            busKeyUnreadable = busKey.isFailure && !busKeyLeftover
            if !busKeyUnreadable {
                let usable = busKeyLeftover ? nil : busKey.value
                busKeyCache = .some(usable)
                hasBusKey = usable != nil
                if system == .bus, usable != nil { gained = true }
            }
        }
        if let account = reads.account, useAccount {
            // What a removal, or a save that couldn't be undone, left behind is never used, even when it reads as a whole account
            // (so there's nothing to read again either)
            njTransitAccountUnreadable = account.isFailure && !njTransitPartlyRemoved
            if !account.isFailure {
                hasNJTransitAccount = account.value != nil && !njTransitPartlyRemoved
                if system.hasTimetablePart, hasNJTransitAccount { gained = true }
            }
        }
        if let suffolk = reads.suffolkKey, suffolkKeyCache == nil {
            suffolkKeyUnreadable = suffolk.isFailure && !suffolkKeyLeftover
            if !suffolkKeyUnreadable {
                let usable = suffolkKeyLeftover ? nil : suffolk.value
                suffolkKeyCache = .some(usable)
                hasSuffolkKey = usable != nil
                if system == .bus, usable != nil { gained = true }
            }
        }
        return gained
    }

    nonisolated static func initialSettings() -> CatchSettings {
        SharedStore.upgradeRangeDefaultsIfNeeded()
        return SharedStore.catchSettings
    }
}
