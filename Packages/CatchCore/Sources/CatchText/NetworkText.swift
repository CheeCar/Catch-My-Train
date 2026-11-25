import Foundation
import TransitCore

/// Text for when a data provider can't be reached or the official data has a problem (see NetworkReach): shared by the main window, Settings, menu bar and widget, with the same wording.
/// Says only what was observed; the cause can't be known for sure, hence "may". Never says where the user might be or what they use.
extension AppText {
    /// Long form (main window, Settings): which operator, and what kind of failure was seen
    public func reachText(_ n: NetworkReach.Notice) -> String {
        let name = t(n.provider)
        switch n.problem {
        case .offline:
            return t("This Mac isn't connected to the internet, so times can't update. Times shown are from the timetable or the last update.")
        case .noDNS:
            return f("Can't reach %@: this network can't find its server.", name)
        case .noResponse:
            return f("Can't reach %@: its server isn't responding on this network.", name)
        case .secureConnection:
            return f("Can't reach %@: a secure connection to its server couldn't be made on this network.", name)
        case .refused:
            return f("Can't reach %@: its server refuses connections from this network or region.", name)
        // About this Mac or its network as a whole, one notice for several providers (see NetworkReach.generalNotices)
        case .clock:
            return t("This Mac's date or time looks wrong, so secure connections to the transit data servers fail. Make sure “Set time and date automatically” is on in System Settings → General → Date & Time.")
        case .signIn:
            return t("Several transit data servers sent back a web page instead of their data. This network may need you to sign in first, or it may be showing a page of its own. Open any web page to check.")
        // Problems on the data provider's side (also warns on server migrations and changed URLs or formats)
        case .notFound:
            return f("Can't get data from %@: it's no longer at its usual address. The operator may have moved or changed it.", name)
        case .serverError:
            return f("Can't get data from %@: its server keeps returning errors.", name)
        case .badData:
            return f("Can't read the data from %@: it isn't in the expected format. The operator may have changed it.", name)
        case .stale:
            return f("Live data from %@ has stopped updating.", name)
        }
    }

    /// Icon: Wi-Fi for network problems, a clock for this Mac's date or time, a triangle for data provider problems (not
    /// distinguished by color alone)
    public func reachSymbol(_ n: NetworkReach.Notice) -> String {
        if n.problem == .offline { return "wifi.slash" }
        if n.problem == .clock { return "clock.badge.exclamationmark" }
        return n.problem.isNetwork ? "wifi.exclamationmark" : "exclamationmark.triangle"
    }

    /// This Mac's clock is off and the app goes by the servers' time (main window, Settings; see ClockSkew.noticeOffset). The menu bar
    /// and widget don't say it: their times are already corrected
    public func clockOffsetText(_ offset: TimeInterval) -> String {
        f("This Mac's clock is about %@ off, so the app goes by the transit data servers' time. To fix the clock, make sure “Set time and date automatically” is on in System Settings → General → Date & Time.",
          duration(abs(offset)))
    }

    /// Short form (menu bar, medium and large widgets)
    public func reachShortText(_ n: NetworkReach.Notice) -> String {
        let name = t(n.provider)
        switch n.problem {
        case .offline: return t("No internet connection")
        case .noDNS: return f("%@: server not found on this network", name)
        case .noResponse: return f("%@: server not responding", name)
        case .secureConnection: return f("%@: secure connection failed", name)
        case .refused: return f("%@: refused from this network", name)
        case .clock: return t("Check this Mac's date and time")
        case .signIn: return t("This network may need you to sign in")
        case .notFound: return f("%@: data moved or missing", name)
        case .serverError: return f("%@: server errors", name)
        case .badData: return f("%@: data format changed", name)
        case .stale: return f("%@: live data not updating", name)
        }
    }

    /// A mode's timetables couldn't be downloaded the first time (main window, menu bar, map, trip planner, Settings): `network` asks
    /// to check the network. When an operator's own problem was seen, it's said instead, one line per operator (short: the menu bar's
    /// form), and so is a reason about this Mac or its network as a whole (its clock, a sign-in page); the network sentence stays
    /// when nothing was seen, or when the network failed too
    /// - Parameter problems: the notices of the operators whose timetables failed, and those about this Mac or its network (see
    ///   NetworkReach.notices)
    public func downloadFailedText(_ network: String, problems: [NetworkReach.Notice], short: Bool = false) -> String {
        let said = problems.filter { !$0.problem.isNetwork || ($0.problem.isGeneral && $0.problem != .offline) }
        let networkToo = said.isEmpty || problems.contains { $0.problem.isNetwork && !$0.problem.isGeneral }
        return ((networkToo ? [network] : []) + said.map { short ? reachShortText($0) : reachText($0) }).joined(separator: "\n")
    }

    /// A note after the list (main window, Settings). Not needed when offline (the line above already says so).
    /// Several operators unreachable at once: most likely the network is blocking; just one: maybe that operator's server has a problem, or maybe the network is blocking.
    public func reachExplanation(_ notices: [NetworkReach.Notice]) -> String? {
        let network = networkExplanation(notices.filter { $0.problem.isNetwork })
        let source = sourceExplanation(notices.filter { !$0.problem.isNetwork })
        let both = [network, source].compactMap { $0 }
        return both.isEmpty ? nil : sentences(both)
    }

    /// A problem on the data provider's side: not your network. Monthly downloaded data falls back to the previous download.
    func sourceExplanation(_ problems: [NetworkReach.Notice]) -> String? {
        guard !problems.isEmpty else { return nil }
        if problems.contains(where: { $0.lasting == true }) {
            return t("This is on the operator's side, not your network. The app keeps using the data it downloaded earlier and tries again at the next check. If it doesn't clear up, an app update may be needed.")
        }
        return t("This is on the operator's side, not your network. Until it's fixed, times from it are from the timetable or the last update. The app keeps trying. If it doesn't clear up, an app update may be needed.")
    }

    /// The notices about this Mac or its network as a whole (offline, its clock, a sign-in page) already say why, so only the
    /// unreachable servers get this
    func networkExplanation(_ notices: [NetworkReach.Notice]) -> String? {
        let problems = notices.filter { !$0.problem.isGeneral }
        guard !problems.isEmpty else { return nil }
        if NetworkReach.looksRestricted(problems) {
            return t("Several transit data servers can't be reached while the internet works. Your network may be blocking them, or they may refuse connections from certain countries, regions or networks. Try a different network or different connection settings. Until then, times from these sources are from the timetable or the last update.")
        }
        return t("Its server may be down, your network may be blocking it, or the server may refuse connections from certain countries, regions or networks. Times from it are from the timetable or the last update.")
    }

    /// When several operators are unreachable at once, the top of the main window uses a single line (the top can't scroll, and one line each would push trips down): which ones, plus a note
    /// Only network problems are combined; data provider problems get one line per operator (see reachSeparate)
    public func reachCombinedText(_ notices: [NetworkReach.Notice]) -> String? {
        let problems = notices.filter { $0.problem.isNetwork && !$0.problem.isGeneral }
        guard NetworkReach.looksRestricted(problems) else { return nil }
        return sentences([f("Can't reach %@.", commaList(problems.map { t($0.provider) })), networkExplanation(problems) ?? ""])
    }

    /// Still shown one line each after combining (reachCombinedText / reachShortSummary): data provider problems, and the notices
    /// about this Mac or its network as a whole
    public func reachSeparate(_ notices: [NetworkReach.Notice]) -> [NetworkReach.Notice] {
        let network = notices.filter { $0.problem.isNetwork && !$0.problem.isGeneral }
        guard NetworkReach.looksRestricted(network) else { return notices }
        return notices.filter { !$0.problem.isNetwork || $0.problem.isGeneral }
    }

    /// One sentence for the menu bar and widget when several operators are unreachable
    public func reachShortSummary(_ notices: [NetworkReach.Notice]) -> String? {
        let problems = notices.filter { $0.problem.isNetwork && !$0.problem.isGeneral }
        guard NetworkReach.looksRestricted(problems) else { return nil }
        return f("Can't reach %@ data sources. Your network may be blocking them.", "\(problems.count)")
    }
}
