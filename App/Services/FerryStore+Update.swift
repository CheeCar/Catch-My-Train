import Foundation
import TransitCore

extension FerryStore {
    /// For the ferry page: use the data if there is any; if there isn't yet, or the monthly check is due, download it (only while active).
    /// If the check fails but old data exists, keep using the old data.
    func ensure(allowNetwork: Bool, now: Date = Date(), near: Coordinate? = nil, radius: Double = 3000) async throws -> FerryFeed? {
        let current = load(near: near, radius: radius)
        // Also download if the stored data is missing an operator (e.g. a ferry operator added in an app update, one that failed last
        // time, or one downloaded only for places in its area once one is in use: see wantedSources)
        let missingSources = Set(wantedSources).subtracting(current?.sources ?? [])
        let missingCodes = isIndexed ? missingBusCodes(now: now) : []
        let missing = isIndexed ? !missingCodes.isEmpty : !missingSources.isEmpty
        // An operator downloaded only for places in its area, wanted again after this month's check went without it. Not while
        // the network is off: it couldn't be downloaded, and would keep the quick path below from being used until then
        let reachable = allowNetwork && NetworkSwitch.isAllowed
        // A bus company whose stored copy an older version read differently (see RegionalBusFeed.readingVersion): read again once,
        // keeping the old copy until then
        let readAgain = reachable && isIndexed ? outdatedBusCodes(now: now) : []
        let behind = reachable ? behindKeys(now: now).union(readAgain) : []
        // Nothing was due a moment ago: use what's stored, unless an operator is missing that can be downloaded now (a place in
        // its area just came into use)
        let canGetMissing = (isIndexed ? missing : missingSources.contains { monthlyCheck.canRetry($0.rawValue, now: now) }) || !behind.isEmpty
        if current != nil, !canGetMissing, let notDueAt, now >= notDueAt, now.timeIntervalSince(notDueAt) < Self.notDueRecheck,
           !SubwayMapSchedule.isDue(lastChecked: lastChecked, now: now) {
            return current
        }
        // If an operator has no sailings in the next few days (timetable ran out), the train timetable is about to run out, or an
        // operator's timetable ends within the next week: check daily for a new one, so it's in use before the old one ends
        // (New Jersey buses look at the full data, not the nearby chunk; an operator dropped in an app update isn't checked)
        let runningOut = current.map {
            $0.idleSources(from: now).union($0.endingSources(from: now)).union($0.endingSoonSources(from: now)).intersection(wantedSources)
        } ?? []
        let endingKeys = isIndexed ? endingBusCodes(now: now) : Set(runningOut.map(\.rawValue))
        // A good download of one of them counts as that day's check too: it's saved (idleCheckedAt isn't), so opening the app
        // again doesn't download them again within the day
        let saved = operatorDates
        let checked = ([lastChecked, idleCheckedAt] + endingKeys.map { saved[$0] }).compactMap { $0 }.max()
        let idle = !endingKeys.isEmpty && (checked.map { now.timeIntervalSince($0) >= Self.idleRecheckAfter } ?? true)
        let monthly = SubwayMapSchedule.isDue(lastChecked: lastChecked, now: now)
        // Built by an older version that read the packages differently (e.g. before Shore Line East was kept): download and read every operator
        // again once, keeping the old copy until then (see FerryFeed.contentVersion)
        let outdated = !isIndexed && (current?.isOutdated(for: system) ?? false)
        let due = missing || idle || monthly || outdated || !behind.isEmpty
        if !due { notDueAt = now }
        // Network off in Settings: use what's stored, and don't count it as a failed download
        guard allowNetwork, due, NetworkSwitch.isAllowed else { return current }
        if let lastFailure, now.timeIntervalSince(lastFailure) < Self.retryAfter {
            if let current { return current }
            throw URLError(.notConnectedToInternet)
        }
        notDueAt = nil
        let lastIdleCheck = idleCheckedAt
        // Only what's due: missing operators, ones whose timetable runs out (at most once a day), and the operators this month's check hasn't refreshed yet.
        // A failed operator waits its turn (see MonthlyCheck), so NJ Transit's 50 MB or every train operator isn't downloaded again for one failure
        var only = isIndexed ? missingCodes
            : Set(missingSources.map(\.rawValue).filter { monthlyCheck.canRetry($0, now: now) })
        only.formUnion(behind)
        if !readAgain.isEmpty {
            // NJ Transit's code is the empty one: its name instead, so the line says which company
            let names = readAgain.sorted().map { $0.isEmpty ? RegionalBusFeed.njTransit.name : $0 }.joined(separator: ", ")
            AppLog.data.notice("\(self.system.rawValue, privacy: .public) data was built by an older version: reading \(names, privacy: .public) again")
        }
        if idle {
            idleCheckedAt = now
            only.formUnion(endingKeys)
        }
        if monthly {
            let left = monthlyCheck.remaining(of: operatorKeys, lastChecked: lastChecked, now: now, downloaded: saved)
            // Every operator already downloaded this month (e.g. a package another store downloaded and handed over, see
            // handOver): the month is checked without downloading any of them again
            if left.isEmpty, monthlyCheck.refreshed([], of: operatorKeys, lastChecked: lastChecked, now: now, downloaded: saved) {
                UserDefaults.standard.set(now, forKey: lastCheckedKey)
            }
            only.formUnion(left)
        }
        if outdated {
            // The operators not read again yet in this run; a failed one waits its turn too
            let again = Set(wantedSources).subtracting(readThisRun).map(\.rawValue).filter { monthlyCheck.canRetry($0, now: now) }
            if !again.isEmpty {
                AppLog.data.notice("\(self.system.rawValue, privacy: .public) data was built by an older version: reading \(again.count, privacy: .public) operators again")
            }
            only.formUnion(again)
        }
        guard !only.isEmpty else {
            // Every due operator is still waiting after a failure, or this month's check turned out to be done already (see above)
            if let current { return current }
            // None of its operators is downloaded for the places in use: nothing to download, which isn't a failed download
            if operatorKeys.isEmpty { return nil }
            throw URLError(.notConnectedToInternet)
        }
        do {
            if isIndexed {
                try await updateBus(now: now, only: only)
                return load(near: near, radius: radius) ?? current
            }
            return try await updateSources(Set(sources.filter { only.contains($0.rawValue) }), now: now).1 ?? current
        } catch {
            // Stopped by standby: the daily check isn't done, so it runs again on the next Start instead of a day later
            if NetworkReach.isCancellation(error) { idleCheckedAt = lastIdleCheck }
            if let current { return current }
            throw error
        }
    }

    /// Check every operator wanted now online right now. Returns (result, new data).
    /// On standby, throws CancellationError without downloading (see DownloadGate); that isn't a failure.
    func update(now: Date = Date()) async throws -> (SubwayMapStore.CheckResult, FerryFeed?) {
        if isIndexed {
            let result = try await updateBus(now: now)
            return (result, load())
        }
        return try await updateSources(Set(wantedSources), now: now)
    }

    /// Downloads these train or ferry operators; the others keep their saved copy. Records which ones got through:
    /// the month counts as checked once every operator has (see MonthlyCheck), and a failed one is retried on its own later.
    func updateSources(_ wanted: Set<FerryFeed.Source>, now: Date) async throws -> (SubwayMapStore.CheckResult, FerryFeed?) {
        try NetworkSwitch.check()
        // Trains' packages and ones several modes share are large: read, built and saved one store at a time (see OneAtATime)
        let large = sources.contains { wanted.contains($0) && ($0.isRail || SharedPackage.isShared($0.url)) }
        let asked = Date()
        if large { await OneAtATime.largePackages.enter() }
        // Done by another check of this store while this one waited its turn: nothing new to download or build
        if large, built(wanted.map(\.rawValue), since: asked) {
            await OneAtATime.largePackages.leave()
            AppLog.data.notice("\(self.system.rawValue, privacy: .public): built while waiting, not built again")
            return (.unchanged, feed ?? load())
        }
        do {
            let result = try await updateSourcesNow(wanted, now: now)
            if large { await OneAtATime.largePackages.leave() }
            return result
        } catch {
            if large { await OneAtATime.largePackages.leave() }
            throw error
        }
    }

    private func updateSourcesNow(_ wanted: Set<FerryFeed.Source>, now: Date) async throws -> (SubwayMapStore.CheckResult, FerryFeed?) {
        let ordered = sources.filter(wanted.contains)
        let due = lastChecked
        let period = try DownloadGate.shared.begin()
        let task = running.join(period: period) { stopped in
            Task {
                // Standby stopped a download that was still processing: a complete result it got for these operators is the same data, don't download it again
                if let earlier = try? await stopped?.value, earlier.requested.isSuperset(of: wanted),
                   earlier.feed.sources.isSuperset(of: earlier.requested) { return earlier }
                return (feed: try await Self.download(ordered, now: now), requested: Set(ordered))
            }
        }
        defer { running.finished(task) }
        // Set once the downloads are done: an error after that (reading or saving here) isn't a failed download
        var downloaded = false
        do {
            let result = try await task.value
            downloaded = true
            let got = result.feed.sources.intersection(result.requested)
            let missed = result.requested.subtracting(got)
            // Standby stopped it before every operator was done: save nothing, it's checked again on the next Start (a finished download is still saved)
            if task.isCancelled, !missed.isEmpty { throw CancellationError() }
            if !missed.isEmpty, NetworkSwitch.isAllowed { monthlyCheck.failed(Set(missed.map(\.rawValue)), now: now) }
            // Each operator downloaded now is held against its data in use (FerryFeed.sourcesKeptOut, which logs what changed): one
            // whose new data looks wrong keeps the data in use (filled in below, as for one not downloaded this time) and is
            // downloaded again the next day; the others are taken
            let stored = load()
            let keptOut = FerryFeed.sourcesKeptOut(new: result.feed, old: stored, sources: got, now: now)
            if !keptOut.isEmpty { monthlyCheck.held(Set(keptOut.map(\.rawValue)), now: now) }
            let taken = got.subtracting(keptOut)
            // Operators downloaded earlier this month count toward this month's check only while it's due: once it's done, a later
            // download of a few of them isn't a new check of them all (lastChecked stays, see ensure)
            let dates = SubwayMapSchedule.isDue(lastChecked: due, now: now) ? operatorDates : [:]
            // Counted as checked only once what was taken is saved (or was the same as saved): a save that failed leaves them due
            func noteChecked() {
                if monthlyCheck.refreshed(Set(taken.map(\.rawValue)), of: operatorKeys, lastChecked: due, now: now, downloaded: dates) {
                    UserDefaults.standard.set(now, forKey: lastCheckedKey)
                }
                noteDownloaded(Set(taken.map(\.rawValue)), now: now)
            }
            // Once this store's own reading and saving below are done, so the two don't read a large package at the same time
            defer { handOver(got.map { (url: $0.url, provider: $0.name) }) }
            lastFailure = missed.isEmpty || !NetworkSwitch.isAllowed ? nil : now
            // Operators not downloaded this time (not asked for, or failed) keep the last saved copy; one the source list turned off
            // is left out of the file
            var fresh = keptOut.isEmpty ? result.feed : result.feed.removing(keptOut)
            if fresh.sources != Set(sources), let old = readFileWithShapes() {
                fresh = fresh.filling(missingSourcesFrom: old.withoutTurnedOff())
            }
            // Operators whose areas' data was removed meanwhile (30 days unused, or Settings' Remove…) stay removed
            let gone = fresh.sources.filter { !DownloadedData.keeps(.source($0)) }
            if !gone.isEmpty { fresh = fresh.removing(gone) }
            // Marked with this version's way of reading once every operator in it was read in this run (see FerryFeed.markBuilt);
            // one whose new data wasn't taken still has the data read before
            let read = readThisRun.union(taken)
            fresh.markBuilt(for: system, read: read, older: stored)
            let slim = fresh.withoutShapes()
            if slim == stored {
                noteChecked()
                readThisRun = read
                noteBuilt(got.map(\.rawValue))
                return (.unchanged, slim)
            }
            do {
                try save(fresh)
            } catch {
                AppLog.data.error("Saving \(self.fileName, privacy: .public) failed: \(AppLog.reason(error), privacy: .public)")
                // Not saved: the operators taken wait as failed, and are downloaded again by the rules for a failed download
                if NetworkSwitch.isAllowed { monthlyCheck.failed(Set(taken.map(\.rawValue)), now: now) }
                throw error
            }
            noteChecked()
            noteBuilt(got.map(\.rawValue))
            readThisRun = read
            if let stored, stored.isOutdated(for: system), !slim.isOutdated(for: system) {
                AppLog.data.notice("\(self.system.rawValue, privacy: .public) data built again with this version's reading (\(FerryFeed.contentVersion(for: self.system), privacy: .public))")
            }
            feed = slim
            saveCoverage(slim)
            noteUnknown(slim)
            generation += 1
            return (.updated, slim)
        } catch {
            // Turning the network off in Settings isn't a failed download either
            if !NetworkReach.isCancellation(error), NetworkSwitch.isAllowed {
                lastFailure = now
                // Only operators whose download failed wait as failed (the ones missing from a finished download were marked above)
                if !downloaded { monthlyCheck.failed(Set(wanted.map(\.rawValue)), now: now) }
            }
            throw error
        }
    }

    /// Standby: stop the downloads that started before it (see DownloadGate). Their callers get a cancellation, which isn't a failure,
    /// and the next Start can download again right away.
    func cancelDownloads(before period: Int) {
        running.cancel(before: period)
        busRunning.cancel(before: period)
    }

    /// Standby: stop every system's downloads (see cancelDownloads)
    static func cancelAllDownloads(before period: Int) async {
        for store in [shared, train, path, lightRail, njBus] { await store.cancelDownloads(before: period) }
    }

    /// Release memory when this system isn't in use (files remain).
    func release() {
        feed = nil
        busIndexes = nil
        busServiceDays = nil
        sliceCenter = nil
        emptySlice = nil
        detached = nil
        notDueAt = nil
    }

    /// What each operator's data in this store takes on this Mac, in bytes, by operator key (bus company codes, or train and ferry
    /// operator ids): a bus company's own file, or its share of the system's file (with its map lines)
    func sizes() -> [String: Int64] {
        if isIndexed {
            var out: [String: Int64] = [:]
            for feed in RegionalBusFeed.all {
                if let url = busFileURL(feed), let size = DownloadedData.fileSize(url) { out[feed.code] = size }
            }
            return out
        }
        guard let url = fileURL, let size = DownloadedData.fileSize(url) else { return [:] }
        let total = size + (shapesURL.flatMap(DownloadedData.fileSize) ?? 0)
        let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if shares == nil || shares?.changed != changed {
            guard let full = readFileWithShapes() else { return [:] }
            var weights: [String: Int] = [:]
            for source in full.sources {
                let part = full.removing(full.sources.subtracting([source]))
                weights[source.rawValue] = ((try? part.withoutShapes().encoded().count) ?? 0) + ((try? JSONEncoder().encode(part.shapes).count) ?? 0)
            }
            shares = (changed, weights)
        }
        let weights = shares?.weights ?? [:]
        let sum = Double(max(weights.values.reduce(0, +), 1))
        return weights.mapValues { Int64((Double($0) / sum * Double(total)).rounded()) }
    }

    /// Removes these operators' data (keys as in sizes): a bus company's file, or its part of the system's file. They're downloaded
    /// again, as missing, once one of their areas is kept again. False when a file couldn't be written or deleted
    func remove(_ keys: Set<String>) -> Bool {
        var ok = true
        let fm = FileManager.default
        var removed: Set<String> = []
        if isIndexed {
            for feed in RegionalBusFeed.all where keys.contains(feed.code) {
                guard let url = busFileURL(feed), fm.fileExists(atPath: url.path) else { continue }
                do {
                    try fm.removeItem(at: url)
                    removed.insert(feed.code)
                } catch {
                    ok = false
                    AppLog.data.error("Removing \(feed.fileName, privacy: .public) failed: \(AppLog.reason(error), privacy: .public)")
                }
                busBounds[feed.code] = nil
            }
        } else if let full = readFileWithShapes() {
            let drop = full.sources.filter { keys.contains($0.rawValue) }
            if !drop.isEmpty {
                let rest = full.removing(drop)
                do {
                    if rest.sources.isEmpty {
                        for url in [fileURL, shapesURL, namesURL].compactMap({ $0 }) where fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                    } else {
                        try save(rest)
                    }
                    removed = Set(drop.map(\.rawValue))
                } catch {
                    ok = false
                    AppLog.data.error("Removing operators from \(self.fileName, privacy: .public) failed: \(AppLog.reason(error), privacy: .public)")
                }
                shares = nil
            }
        }
        guard !removed.isEmpty else { return ok }
        var dates = operatorDates
        for key in removed { dates[key] = nil }
        UserDefaults.standard.set(dates, forKey: operatorDatesKey)
        release()
        readThisRun.subtract(FerryFeed.Source.allCases.filter { removed.contains($0.rawValue) })
        generation += 1
        UserDefaults.standard.removeObject(forKey: coverageKey)
        forgetUnknown()
        return ok
    }

    /// Map: trains and ferries use stored data (operators whose timetable ran out aren't drawn); New Jersey buses use the bus map in NJBusIndex.
    func map(now: Date = Date()) -> SubwayMap? {
        if isIndexed {
            let maps = (loadBusIndexes() ?? [:]).sorted { $0.key < $1.key }.compactMap { $0.value.map() }
            busIndexes = nil   // release the full data once drawn
            guard let first = maps.first else { return nil }
            return maps.dropFirst().reduce(first) { $0.merged(with: $1) }
        }
        return readFileWithShapes()?.withoutTurnedOff().active(from: now).map()
    }
}
