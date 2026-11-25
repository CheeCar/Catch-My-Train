import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    // MARK: - Bus Time key

    /// Tests the key with MTA Bus Time first (not saved if MTA refuses it; on standby, in Demo mode or offline it's saved untested),
    /// then saves it to the Keychain and refreshes. A rate-limit pause belongs to the key that got it: a different key is still tested,
    /// and the pause is cleared only for a different key that worked or wasn't tested.
    func saveBusKey(_ key: String) async -> AccountSaveResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected }
        savingBusKey = true
        defer { savingBusKey = false }
        let previous = busTimeKey
        let tested = isActive && !isDemo
        let fetcher = URLSessionFetcher(accept: BusTimeLoader.accept, checksPause: trimmed == previous)
        let works: Bool? = tested ? await CredentialTester.busTime(key: trimmed, fetcher: fetcher) : nil
        if works == false { return .rejected }
        guard KeychainStore.save(trimmed, for: KeychainStore.busTimeAccount) else { return .keychainFailed }
        busKeyLeftover = false
        hasBusKey = true
        busKeyCache = .some(trimmed)
        busKeyUnreadable = false
        busError = nil
        credentialChecks[.busTime] = CredentialCheck(works)
        // New key: the old key's rate-limit record no longer counts, unless this key's own test couldn't tell (it may have been told to wait too)
        if trimmed != previous, works == true || !tested { BusTimeBackoff.forget() }
        updateRateLimits(now: Date())
        if system == .bus { refresh() }
        return works == true ? .saved : .savedUnchecked
    }

    // MARK: - NJ Transit account

    enum AccountSaveResult { case saved, savedUnchecked, rejected, keychainFailed }

    /// Saves the NJ Transit account. While the app is on, first confirms with NJ Transit that it works (not saved if it doesn't); on standby
    /// and in Demo mode nothing goes online, so it's saved for now.
    /// The new account is tried on separate clients (NJTransitClient.tryAccount): until it's saved, the current account keeps its tokens, so a refused
    /// account changes nothing, and a refresh meanwhile doesn't sign in with the old account.
    func saveNJTransitAccount(username: String, password: String) async -> AccountSaveResult {
        let account = NJTransitClient.Account(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                              password: password)
        njTransitTriedRefusal = nil
        njTransitTriedTestOnly = false
        guard !account.username.isEmpty, !account.password.isEmpty else { return .rejected }
        savingNJTransitAccount = true
        defer { savingNJTransitAccount = false }
        // Trains and buses are two APIs, confirmed separately (nil: network down or NJ Transit temporarily failing; save for now and retry on refresh)
        var trials: (rail: NJTransitClient.AccountTrial, bus: NJTransitClient.AccountTrial)?
        var refusal: String?
        if isActive && !isDemo {
            async let rail = FerryStore.njTransit.tryAccount(account)
            async let bus = FerryStore.njTransitBus.tryAccount(account)
            let railTrial = await rail
            let busTrial = await bus
            trials = (rail: railTrial, bus: busTrial)
            refusal = railTrial.works == false ? railTrial.refusal : busTrial.works == false ? busTrial.refusal : nil
            if railTrial.works == false && busTrial.works == false {
                // The saved account stays as it was, including what NJ Transit said about it
                njTransitTriedRefusal = refusal
                njTransitTriedTestOnly = njTransitTestOnly == true && KeychainStore.njTransitAccount == account
                await Self.endNJTransitTrials()
                // A refresh during the test skipped NJ Transit (see NJTransitClient.tryAccount): get its live times now
                refresh()
                return .rejected
            }
        }
        let previous = KeychainStore.njTransitAccountLookup
        guard KeychainStore.save(account.username, for: KeychainStore.njTransitUsername) else {
            await Self.endNJTransitTrials()
            refresh()
            return .keychainFailed
        }
        guard KeychainStore.save(account.password, for: KeychainStore.njTransitPassword) else {
            // Never leave the new username with the old password: put the previous username back (or remove the new one when there was no account).
            // When only the password changed, the stored pair is still the previous account: nothing to undo, and its tokens stay.
            // A previous account the Keychain couldn't read can't be put back.
            let restored: Bool
            switch previous {
            case .found(let old):
                restored = old.username == account.username || KeychainStore.save(old.username, for: KeychainStore.njTransitUsername)
            case .notFound:
                restored = KeychainStore.delete(KeychainStore.njTransitUsername)
            case .failed:
                restored = false
            }
            if restored {
                await Self.endNJTransitTrials()
            } else {
                // Couldn't undo it: the stored pair is neither account, so it's never signed in with. Remove it; whatever is left keeps the Remove button.
                // After a previous account that couldn't be read, nothing is deleted (the pair may still be that account): it stays as a leftover that's never used
                let keep = previous.isFailure
                let passwordDeleted = !keep && KeychainStore.delete(KeychainStore.njTransitPassword)
                let usernameDeleted = !keep && KeychainStore.delete(KeychainStore.njTransitUsername)
                // Before the awaits below, so a refresh meanwhile can't sign in with what's left
                hasNJTransitAccount = false
                njTransitPartlyRemoved = !(passwordDeleted && usernameDeleted)
                njTransitAccountUnreadable = false
                accountTouched = true
                await FerryStore.njTransit.forget()
                await FerryStore.njTransitBus.forget()
                njTransitRejected = false
                njTransitBusRejected = false
                njTransitRefusal = nil
                UserDefaults.standard.removeObject(forKey: Self.njTransitTestProbeKey)
                njTransitTestOnly = nil
                credentialChecks[.njTransitRail] = nil
                credentialChecks[.njTransitBus] = nil
            }
            refresh()
            return .keychainFailed
        }
        njTransitRefusal = refusal
        // Saved: hand the new account's tokens to the clients refreshes use (on standby or in Demo mode nothing was tried: just drop the old account's)
        if let trials {
            await FerryStore.njTransit.adopt(trials.rail)
            await FerryStore.njTransitBus.adopt(trials.bus)
        } else {
            await FerryStore.njTransit.forget()
            await FerryStore.njTransitBus.forget()
        }
        let railOK = trials?.rail.works
        let busOK = trials?.bus.works
        hasNJTransitAccount = true
        njTransitPartlyRemoved = false
        njTransitAccountUnreadable = false
        accountTouched = true
        njTransitRejected = railOK == false
        njTransitBusRejected = busOK == false
        UserDefaults.standard.removeObject(forKey: Self.njTransitTestProbeKey)
        njTransitTestOnly = nil
        if railOK == false || busOK == false { probeNJTransitTestSystem() }
        credentialChecks[.njTransitRail] = CredentialCheck(railOK)
        credentialChecks[.njTransitBus] = CredentialCheck(busOK)
        let checked = railOK == true || busOK == true
        refresh()
        return checked ? .saved : .savedUnchecked
    }

    /// The tried account wasn't saved: the current one stays, and its renewals may run again
    private nonisolated static func endNJTransitTrials() async {
        await FerryStore.njTransit.endTrial()
        await FerryStore.njTransitBus.endTrial()
    }

    /// Whether the account works: true works, false rejected, nil network down or NJ Transit temporarily failing
    private nonisolated static func check(_ account: NJTransitClient.Account, with client: NJTransitClient) async -> Bool? {
        do {
            try await client.signIn(account)
            return true
        } catch NJTransitLive.LiveError.rejected {
            return false
        } catch {
            return nil
        }
    }

    /// Deletes the account from the Keychain and stops using it at once, whether or not every part could be deleted: no more sign-ins,
    /// its tokens are dropped, and Settings shows no account. Returns false when something is left (see KeychainRemoval): Settings then
    /// says so and keeps the Remove button, and what's left is never used, after a relaunch too (njTransitPartlyRemoved), until an account is saved.
    func removeNJTransitAccount() -> Bool {
        // Every delete always runs, so a retry also removes whichever part is left. The two tokens NJ Transit gave for the
        // account are deleted here too, and counted: forget below deletes them as well, but without being waited for, so a
        // quit right after could leave one in the Keychain
        let items = [KeychainStore.njTransitUsername, KeychainStore.njTransitPassword,
                     KeychainStore.njTransitToken, KeychainStore.njTransitBusToken]
        let deleted = items.map(KeychainStore.delete).allSatisfy { $0 }
        // Read again only after every delete worked: after a failed one it's a leftover anyway, and a read may move a copy from the older keychain back
        let removal = KeychainRemoval(deleted: deleted, stillReadable: deleted && KeychainStore.njTransitAccount != nil)
        accountTouched = true
        njTransitPartlyRemoved = removal == .leftover
        // Known again: gone, or a leftover that's never used
        njTransitAccountUnreadable = false
        // Also stops a sign-in still running, so its token can't be saved after this
        Task {
            await FerryStore.njTransit.forget()
            await FerryStore.njTransitBus.forget()
        }
        hasNJTransitAccount = false
        njTransitRejected = false
        njTransitBusRejected = false
        njTransitRefusal = nil
        UserDefaults.standard.removeObject(forKey: Self.njTransitTestProbeKey)
        njTransitTestOnly = nil
        credentialChecks[.njTransitRail] = nil
        credentialChecks[.njTransitBus] = nil
        refresh()
        return removal == .removed
    }

    /// Records whether NJ Transit accepts the account (shown in Settings). Only NJ Transit's own answer says so: another
    /// railroad's live data that came in the same download doesn't (see NJTransitLive.accountEvidence)
    func noteNJTransit(asked: [FerryFeed.Source],
                               result: (realtime: [FerryRealtime], failed: [FerryFeed.Source], rejected: Bool)) {
        guard hasNJTransitAccount,
              let accepted = NJTransitLive.accountEvidence(asked: asked, received: result.realtime.map(\.source), rejected: result.rejected)
        else { return }
        if accepted {
            njTransitRejected = false
            noteCheck(.njTransitRail, .works)
        } else {
            njTransitRejected = true
            noteCheck(.njTransitRail, .rejected)
            noteNJTransitRefusal(from: FerryStore.njTransit)
        }
    }

    /// Keeps what NJ Transit said when it refused the account during a download, so Settings can show it
    func noteNJTransitRefusal(from client: NJTransitClient) {
        Task { [weak self] in
            guard let said = await client.lastRefusal else { return }
            if self?.njTransitRefusal != said { self?.njTransitRefusal = said }
            self?.probeNJTransitTestSystem()
        }
    }

    /// Records what live downloads showed about a key or account (only when it changed)
    func noteCheck(_ credential: Credential, _ check: CredentialCheck) {
        if credentialChecks[credential] != check { credentialChecks[credential] = check }
    }

    /// Keys entered before testing existed (no saved result): test them once while the app can go online (on, not in Demo mode,
    /// network allowed).
    /// Keys saved earlier whose test couldn't tell (offline, server error) are tested again too, at most every 10 minutes: otherwise a Suffolk key
    /// saved untested would stay "Not checked yet" until the user happened to be near a Suffolk stop.
    /// The NJ Transit account too, on each of its two servers whose result isn't known yet: by one live download the way refreshes
    /// make it (see njTransitLiveCheck), so an account that already works or was refused costs no sign-in here.
    func verifyUntestedCredentials(now: Date = Date()) {
        guard canCheckOnline, keysLoaded, !verifyingCredentials else { return }
        func needsTest(_ credential: Credential) -> Bool {
            // At most one retest every 10 minutes however often Settings opens or the Mac wakes
            CredentialCheck.needsRetest(credentialChecks[credential], lastRetest: lastCredentialRetest, now: now)
        }
        let busKey = needsTest(.busTime) ? busTimeKey : nil
        let swiftlyKey = needsTest(.suffolk) ? suffolkKey : nil
        // Only where the account makes times live (the other rows say "Timetable" whatever the account's state)
        var njTransit: [Credential] = []
        if hasNJTransitAccount, !njTransitAccountUnreadable {
            if FerryFeed.Source.njTransitRail.liveWithAccount, needsTest(.njTransitRail) { njTransit.append(.njTransitRail) }
            if RegionalBusFeed.njTransit.liveWithAccount, needsTest(.njTransitBus) { njTransit.append(.njTransitBus) }
        }
        let njTransitAccount = njTransit.isEmpty ? nil : KeychainStore.njTransitAccount
        if njTransitAccount == nil { njTransit = [] }
        guard busKey != nil || swiftlyKey != nil || !njTransit.isEmpty else { return }
        verifyingCredentials = true
        lastCredentialRetest = now
        if busKey != nil { beginRetest(.busTime) }
        if swiftlyKey != nil { beginRetest(.suffolk) }
        for credential in njTransit { beginRetest(credential) }
        let njTransitServers = njTransit
        credentialVerifyTask = Task { [weak self] in
            // Once stopped, the rows were already put back (see stopCredentialTest): nothing more is written
            if let busKey {
                let works = await CredentialTester.busTime(key: busKey)
                if !Task.isCancelled { self?.endRetest(.busTime, result: self?.busTimeKey == busKey ? works : nil) }
            }
            // Standby, Demo mode or the network turned off since the first test: the second one doesn't go online
            if let swiftlyKey, self?.canCheckOnline == true, !Task.isCancelled, let feed = RegionalBusFeed.all.first(where: \.needsKey) {
                let result = await CredentialTester.keyedFeedCheck(feed, key: swiftlyKey)
                if !Task.isCancelled, self?.suffolkKey == swiftlyKey {
                    self?.suffolkCheckNote = result.works == true ? nil : result.said
                    self?.endRetest(.suffolk, result: result.works)
                    if result.works == false { self?.suffolkKeyRejected = true }
                }
            }
            // The same for NJ Transit's servers, one after the other
            if let njTransitAccount {
                for credential in njTransitServers {
                    guard self?.canCheckOnline == true, !Task.isCancelled else { break }
                    let client = credential == .njTransitRail ? FerryStore.njTransit : FerryStore.njTransitBus
                    let works = await TransitModel.njTransitLiveCheck(njTransitAccount, with: client)
                    if !Task.isCancelled { self?.endNJTransitRetest(credential, works: works) }
                }
            }
            // Stopped (standby, Demo mode), which already cleared them all (a newer test may own them by now)
            guard !Task.isCancelled else { return }
            // Not tested after all, or the key changed meanwhile: its row goes back to what it showed
            self?.endRetest(.suffolk, result: nil)
            for credential in njTransitServers { self?.endRetest(credential, result: nil) }
            self?.verifyingCredentials = false
            self?.credentialVerifyTask = nil
        }
    }

    /// Stops a key test still running (standby, Demo mode). A stopped test doesn't count toward the 10-minute limit,
    /// so it runs again as soon as it's allowed: the next Start, or leaving the demo
    func stopCredentialTest() {
        if credentialVerifyTask != nil { lastCredentialRetest = nil }
        credentialVerifyTask?.cancel()
        credentialVerifyTask = nil
        verifyingCredentials = false
        // No row keeps saying "Checking…" for a test that won't finish
        for credential in Array(checksBeforeRetest.keys) { endRetest(credential, result: nil) }
    }

    /// A key's row says "Checking…" while its retest runs
    private func beginRetest(_ credential: Credential) {
        checksBeforeRetest[credential] = .some(credentialChecks[credential])
        credentialChecks[credential] = .checking
    }

    /// The retest of a key ended: its row shows the result, or what it showed before (see CredentialCheck.afterRetest)
    private func endRetest(_ credential: Credential, result: Bool?) {
        guard let before = checksBeforeRetest.removeValue(forKey: credential) else { return }
        let after = CredentialCheck.afterRetest(result, before: before, now: credentialChecks[credential])
        if credentialChecks[credential] != after { credentialChecks[credential] = after }
    }

    /// Whether NJ Transit accepts the account on one of its servers, by one live download the way refreshes make it: with the stored
    /// token while that works, else one sign-in at the pace the client keeps (see NJTransitClient.tripUpdates). true: its live data
    /// came; false: it refused the account; nil: couldn't tell (offline, NJ Transit failing, no sign-in allowed yet, stopped)
    private nonisolated static func njTransitLiveCheck(_ account: NJTransitClient.Account, with client: NJTransitClient) async -> Bool? {
        do {
            _ = try await client.tripUpdates(account: account)
            return true
        } catch NJTransitLive.LiveError.rejected {
            return false
        } catch {
            return nil
        }
    }

    /// The retest of the NJ Transit account on one of its servers ended: Settings shows what a live download would have noted
    /// (see noteNJTransit, and the buses' refresh)
    private func endNJTransitRetest(_ credential: Credential, works: Bool?) {
        // Something else settled this row meanwhile (a new account saved, a download): that stands
        let stillChecking = credentialChecks[credential] == .checking
        endRetest(credential, result: works)
        guard stillChecking, hasNJTransitAccount, let works else { return }
        let server = credential == .njTransitRail ? FerryFeed.Source.njTransitRail.name : RegionalBusFeed.njTransit.name + " buses"
        let outcome = works ? "accepted the account" : "refused the account"
        AppLog.data.notice("account check: \(server, privacy: .public) \(outcome, privacy: .public)")
        if credential == .njTransitRail {
            njTransitRejected = !works
            if !works { noteNJTransitRefusal(from: FerryStore.njTransit) }
        } else {
            njTransitBusRejected = !works
            if !works, !njTransitRejected { noteNJTransitRefusal(from: FerryStore.njTransitBus) }
        }
    }

    // MARK: - NJ Transit test system check

    private static let njTransitTestProbeKey = "njTransitTestProbe"

    /// Last test-system check: when it ran and whether the account worked there (nil = couldn't tell)
    static func savedNJTransitTestProbe() -> (date: Date, works: Bool?)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: njTransitTestProbeKey),
              let date = dict["date"] as? Date else { return nil }
        return (date, dict["works"] as? Bool)
    }

    /// NJ Transit refused the account: try it once on NJ Transit's test system. If it works there, the account is fine but production access isn't
    /// turned on yet, which Settings then says. At most once a day (sign-ins are limited); the test system's data is never used.
    /// Not on standby or in Demo mode (a refusal that arrives just after the demo was turned on doesn't go online either).
    func probeNJTransitTestSystem(now: Date = Date()) {
        guard isActive, !isDemo, hasNJTransitAccount, !probingNJTransitTest else { return }
        if let last = Self.savedNJTransitTestProbe(), now.timeIntervalSince(last.date) < 86_400 { return }
        guard let account = KeychainStore.njTransitAccount else { return }
        probingNJTransitTest = true
        Task { [weak self] in
            async let rail = Self.check(account, with: NJTransitClient(endpoints: .railTest, loadToken: { nil }, saveToken: { _ in },
                                                                       log: { FerryStore.noteSignIn($0) }))
            async let bus = Self.check(account, with: NJTransitClient(endpoints: .busTest, loadToken: { nil }, saveToken: { _ in },
                                                                      log: { FerryStore.noteSignIn($0) }))
            let r = await rail, b = await bus
            let works: Bool? = r == true || b == true ? true : (r == false && b == false ? false : nil)
            var dict: [String: Any] = ["date": now]
            if let works { dict["works"] = works }
            UserDefaults.standard.set(dict, forKey: Self.njTransitTestProbeKey)
            self?.njTransitTestOnly = works
            self?.probingNJTransitTest = false
        }
    }

    // MARK: - Swiftly key for Suffolk County Transit

    /// Tests the Swiftly key first (not saved if Swiftly refuses it; on standby, in Demo mode or offline it's saved untested), then saves it
    /// to the Keychain and refreshes. A rate-limit pause belongs to the key that got it: a different key is still tested.
    func saveSuffolkKey(_ key: String) async -> AccountSaveResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let feed = RegionalBusFeed.all.first(where: \.needsKey) else { return .rejected }
        savingSuffolkKey = true
        defer { savingSuffolkKey = false }
        let fetcher = URLSessionFetcher(authorization: trimmed, checksPause: trimmed == suffolkKey)
        let result: (works: Bool?, said: String?) = isActive && !isDemo
            ? await CredentialTester.keyedFeedCheck(feed, key: trimmed, fetcher: fetcher) : (nil, nil)
        let works = result.works
        if works == false { return .rejected }
        guard KeychainStore.save(trimmed, for: KeychainStore.suffolkKey) else { return .keychainFailed }
        suffolkKeyLeftover = false
        suffolkCheckNote = works == true ? nil : result.said
        hasSuffolkKey = true
        suffolkKeyCache = .some(trimmed)
        suffolkKeyUnreadable = false
        suffolkKeyRejected = false
        credentialChecks[.suffolk] = CredentialCheck(works)
        if system == .bus { refresh() }
        return works == true ? .saved : .savedUnchecked
    }

    /// Deletes the key from the Keychain and stops using it at once, whether or not the delete worked. Returns false when it's still there
    /// (see KeychainRemoval): Settings then says so and keeps the Remove button, and the key is never used, after a relaunch too
    /// (suffolkKeyLeftover), until a key is saved.
    func removeSuffolkKey() -> Bool {
        let deleted = KeychainStore.delete(KeychainStore.suffolkKey)
        // Read again only after the delete worked (a read may move a copy from the older keychain back)
        let removal = KeychainRemoval(deleted: deleted, stillReadable: deleted && KeychainStore.read(KeychainStore.suffolkKey).value != nil)
        suffolkKeyLeftover = removal == .leftover
        hasSuffolkKey = false
        suffolkKeyCache = .some(nil)
        suffolkKeyUnreadable = false
        suffolkKeyRejected = false
        suffolkCheckNote = nil
        credentialChecks[.suffolk] = nil
        if system == .bus { refresh() }
        return removal == .removed
    }

    /// Deletes the key from the Keychain and stops using it at once, whether or not the delete worked. Returns false when it's still there
    /// (see KeychainRemoval): Settings then says so and keeps the Remove button, and the key is never used, after a relaunch too
    /// (busKeyLeftover), until a key is saved.
    func removeBusKey() -> Bool {
        let deleted = KeychainStore.delete(KeychainStore.busTimeAccount)
        // Read again only after the delete worked (a read may move a copy from the older keychain back)
        let removal = KeychainRemoval(deleted: deleted, stillReadable: deleted && KeychainStore.read(KeychainStore.busTimeAccount).value != nil)
        busKeyLeftover = removal == .leftover
        hasBusKey = false
        busKeyCache = .some(nil)
        busKeyUnreadable = false
        credentialChecks[.busTime] = nil
        BusTimeBackoff.forget()
        updateRateLimits(now: Date())
        if system == .bus { refresh() }
        return removal == .removed
    }

    // MARK: - Saved test results

    private static let credentialChecksKey = "credentialChecks"

    static func savedCredentialChecks() -> [Credential: CredentialCheck] {
        let raw = UserDefaults.standard.dictionary(forKey: credentialChecksKey) as? [String: String] ?? [:]
        var result: [Credential: CredentialCheck] = [:]
        for (key, value) in raw {
            // "Checking" never survives a restart: the test stopped with the app
            if let credential = Credential(rawValue: key), let check = CredentialCheck(rawValue: value), check != .checking {
                result[credential] = check
            }
        }
        return result
    }

    static func saveCredentialChecks(_ checks: [Credential: CredentialCheck]) {
        let raw = Dictionary(uniqueKeysWithValues: checks.filter { $0.value != .checking }.map { ($0.key.rawValue, $0.value.rawValue) })
        UserDefaults.standard.set(raw, forKey: credentialChecksKey)
    }
}
