import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    /// All language changes in Settings go through here (nil: "System Language", the first of the Mac's languages the app has):
    /// same direction as at launch switches directly; a different direction asks first, then switches and restarts once confirmed.
    func chooseLanguage(_ choice: AppLanguage?) {
        let lang = choice ?? AppLanguage.macLanguage(preferred: Locale.preferredLanguages)
        let follows = choice == nil
        guard lang != language || follows != languageFollowsMac else { return }
        if Self.needsRestart(rightToLeftNow: layoutDirection == .rightToLeft, for: lang) {
            pendingFollowsMac = follows
            pendingLanguage = lang
        } else {
            languageFollowsMac = follows
            if lang != language { language = lang }
        }
    }

    /// Whether switching to this language needs a restart: only when the layout direction (left-to-right ↔ right-to-left) changes, either way
    nonisolated static func needsRestart(rightToLeftNow: Bool, for lang: AppLanguage) -> Bool {
        lang.isRightToLeft != rightToLeftNow
    }
    /// Language code that needs a restart to switch to (for tests)
    nonisolated static func languageCodesNeedingRestart(rightToLeftNow: Bool) -> [String] {
        AppLanguage.allCases.filter { needsRestart(rightToLeftNow: rightToLeftNow, for: $0) }.map(\.rawValue)
    }

    /// Confirmed: save the new language (and its direction), then restart
    func confirmPendingLanguage() {
        guard let lang = pendingLanguage else { return }
        pendingLanguage = nil
        languageFollowsMac = pendingFollowsMac
        language = lang
        relaunch()
    }

    /// "Delete Downloaded Data" in Settings' Downloaded data: deletes every area's downloaded timetables, maps and station data, the
    /// shared folder's rate limits, widget status and last snapshot, and the package copies kept in the temporary folder, then
    /// reopens the app (clearing old in-memory data too). Only the starting point's area is downloaded again right away: the others
    /// are marked as removed by the user, until a place there is chosen. Only on standby and with the network allowed (Settings says why otherwise). Favorites, recent places, settings and
    /// Keychain keys are untouched. When something couldn't be deleted, the app says so and doesn't restart
    func deleteDownloadedData() {
        guard !isActive, networkAllowed else { return }
        let fm = FileManager.default
        var items: [URL] = []
        for folder in [DownloadedData.supportFolder, StaticData.directory].compactMap({ $0 }) {
            items += (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }
        if let shared = SharedStore.sharedFolder {
            items += SharedStore.downloadedStateFiles.map { shared.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        }
        var failed = 0
        for item in items {
            do {
                try fm.removeItem(at: item)
            } catch {
                failed += 1
                AppLog.data.error("Deleting \(item.lastPathComponent, privacy: .public) failed: \(AppLog.reason(error), privacy: .public)")
            }
        }
        // The copies of a package several modes read, kept a few hours in the temporary folder for the others (see SharedPackage)
        SharedPackage.removeAll()
        // Only the starting point's area downloads again at once: the other areas with favorites wait until a place there is chosen
        let start = origin.flatMap { MetroArea.of($0.coordinate) }
        let removed = PlacesInUse.areas(.favorites).union(AreaData.removed()).subtracting(start.map { [$0] } ?? [])
        AreaData.saveRemoved(removed)
        PlacesInUse.setRemoved(removed)
        // Also clear the last check time, otherwise it won't re-download for a month
        let defaults = UserDefaults.standard
        // and the source list's (its saved copy was in the folder), each operator's last good download, which way of reading built
        // each bus company's copy, and since when their problems lasted
        for key in defaults.dictionaryRepresentation().keys
        where key.hasSuffix(".lastChecked") || key.hasSuffix(".lastChecked.content") || key.hasSuffix(".lastChecked.operators")
            || key.hasSuffix(".lastChecked.readWith")
            || key.hasPrefix("coverage.") || key.hasPrefix("sourceList.") || key == SourceListStore.historyKey {
            defaults.removeObject(forKey: key)
        }
        AppLog.data.notice("Deleted downloaded data: \(items.count - failed, privacy: .public) items, \(failed, privacy: .public) couldn't be deleted")
        guard failed == 0 else {
            deleteError = l10n.t("Some downloaded data couldn't be deleted. Quit Catch My Train and try again.")
            return
        }
        deleteError = nil
        relaunch()
    }

    /// Reopen the app: open a new instance first, then quit this one. The new one lays out in the new language's direction.
    /// Opened with the system NSWorkspace (the app is sandboxed and can't run scripts itself).
    func relaunch() {
        // First remove this one from the Dock and hide its windows (including the menu bar icon's window),
        // so the Dock won't show two icons at once while the new one opens
        let visible = NSApp.windows.filter(\.isVisible)
        let policy = NSApp.activationPolicy()
        for window in visible { window.orderOut(nil) }
        NSApp.setActivationPolicy(.prohibited)
        relaunchError = nil
        AppRelaunch.inProgress = true
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        let url = Bundle.main.bundleURL
        // Quitting this one before opening the new one would be too late (no code runs after quitting), so wait until the new one starts launching, then quit
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            let opened = app != nil && error == nil
            let reason = error.map { AppLog.reason($0) } ?? "no app"
            Task { @MainActor in
                if opened { NSApp.terminate(nil); return }
                // The new one didn't open (e.g. the app was moved, or the system refused): restore the Dock icon and windows, don't quit.
                // The new language is already saved, so it applies when the user reopens the app themselves.
                AppLog.data.error("relaunch failed: \(reason, privacy: .public)")
                AppRelaunch.inProgress = false
                NSApp.setActivationPolicy(policy == .prohibited ? .regular : policy)
                for window in visible { window.orderFront(nil) }
                NSApp.activate()
                self?.relaunchError = self?.l10n.t("Couldn't restart. Please quit and open Catch My Train again.")
            }
        }
    }

    /// Have macOS lay out the whole app (windows, sidebar, menus) right-to-left: stored in the app's own defaults; AppKit reads it next launch and flips everything.
    /// Flipping only in SwiftUI isn't enough: the sidebar is an AppKit split view that doesn't flip; opened in Urdu without these keys, the sidebar is pushed to the right and cut off.
    /// These two keys are the ones Xcode's "Right-to-Left Pseudolanguage" testing uses. Only writes this app's defaults, not system settings.
    nonisolated static func saveLayoutDirection(rightToLeft: Bool) {
        let defaults = UserDefaults.standard
        for key in ["NSForceRightToLeftWritingDirection", "AppleTextDirection"] {
            if rightToLeft { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    /// Called first thing at launch (CatchMyTrainLaunch), before AppKit reads the direction: makes AppKit match launchLanguage for this launch.
    /// Saving it only when the language changes isn't enough: a first launch in a right-to-left Mac language, or after a crash before it was saved,
    /// would read the old value and push the sidebar off the window.
    nonisolated static func applyLaunchLayoutDirection() {
        saveLayoutDirection(rightToLeft: launchLanguage.isRightToLeft)
    }
}
