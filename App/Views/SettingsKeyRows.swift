import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// The bus row in Settings → Data source: MTA Bus Time key status, with a button opening a separate window to add or replace it.
/// MTA's buses in Data source (New York's Bus page): their times all come from MTA Bus Time, with the key under Keys and accounts
/// above (see AccountKeyRow)
struct BusKeyRow: View {
    @EnvironmentObject var transit: TransitModel

    var body: some View {
        let l = transit.l10n
        let check = transit.credentialChecks[.busTime]
        let invalid = transit.hasBusKey && (transit.busError == .invalidKey || check == .rejected)
        // MTA buses have no timetable: a refused key shows no badge (the red line says why)
        let badge = invalid ? nil : SourceBadge.credential(has: transit.hasBusKey, refused: false, check: check)
        let detail = !transit.hasBusKey ? l.t("Live times need your free MTA Bus Time key (above).")
            : invalid ? l.t("The MTA Bus Time key above wasn't accepted, so there are no MTA bus times for now.")
            : l.t("Live times with your MTA Bus Time key (above).")
        SourceRow(icon: "key", name: l.t("MTA buses (MTA Bus Time)"), detail: detail,
                  detailColor: invalid ? .noticeRed : .secondary,
                  notUsed: transit.dataNotUsedLine(DataChangeLog.cityBusKey).map { [$0] } ?? [], badge: badge)
    }
}

/// Settings → Data source → Keys and accounts: the keys and accounts the live times of the chosen metro area need, above the
/// transit modes, one row each; the operators' rows below say "(above)". A key used in other areas too says where: it's one key,
/// kept once in the Keychain. Which keys an area needs follows from its operators (AccountKey)
struct AccountKeyRows: View {
    @EnvironmentObject var transit: TransitModel
    let area: MetroArea

    var body: some View {
        let l = transit.l10n
        let keys = AccountKey.needed(in: area)
        VStack(alignment: .leading, spacing: 4) {
            Text(l.t("Keys and accounts"))
                .font(.scaled(.headline))
                .accessibilityAddTraits(.isHeader)
            Text(keys.isEmpty ? l.t("No key or account needed in this area.")
                 : l.t("Some live times in this area need your own free key or account. Each one is kept only in this Mac's Keychain."))
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .id(SettingsJump.Target.keys.id)
        // A saved key that couldn't be checked is tried again whenever these rows show (at most every 10 minutes), whichever area
        .onAppear { transit.verifyUntestedCredentials() }
        ForEach(keys, id: \.self) { key in
            AccountKeyRow(key: key, area: area)
        }
    }
}

/// One key or account under Keys and accounts: what it's for in this area and where else it's used, how it stands (saved,
/// refused, not checked yet, unreadable), and Add… or Change…
struct AccountKeyRow: View {
    @EnvironmentObject var transit: TransitModel
    let key: AccountKey
    let area: MetroArea
    @State private var showSheet = false

    /// How it stands: the line under the name, whether it was refused (red), the badge, and the Keychain retry when it couldn't be read
    private struct Status {
        var text: String?
        var refused = false
        var badge: SourceBadge?
        var retry: Credential?
    }

    var body: some View {
        let l = transit.l10n
        let status = status(l)
        let account = key == .njTransit
        let buttonTitle = has ? (account ? l.t("Change account…") : l.t("Change key…"))
                              : (account ? l.t("Add account…") : l.t("Add key…"))
        SourceRow(icon: "key", name: name(l), about: usedFor(l), detail: status.text,
                  detailColor: status.refused ? .noticeRed : .secondary, badge: status.badge, keychainRetry: status.retry) {
            // Screen readers hear which key or account too: every row has a button like this one
            Button(buttonTitle) { showSheet = true }
                .appButtonStyle()
                .accessibilityLabel(Text(buttonTitle + l.comma + name(l)))
        }
        .sheet(isPresented: $showSheet) {
            switch key {
            case .busTime: BusKeySheet()
            case .njTransit: NJTransitAccountSheet()
            case .suffolk: SuffolkKeySheet()
            }
        }
    }

    private var has: Bool {
        switch key {
        case .busTime: return transit.hasBusKey
        case .njTransit: return transit.hasNJTransitAccount
        case .suffolk: return transit.hasSuffolkKey
        }
    }

    /// The same names as the windows where they're entered
    private func name(_ l: UIText) -> String {
        switch key {
        case .busTime: return l.t("MTA Bus Time key")
        case .njTransit: return l.t("NJ Transit account")
        case .suffolk: return l.t("Suffolk County Transit key")
        }
    }

    /// "For: <the operators in this area that use it> · Also used in <the other areas>", naming the other areas while there are
    /// few, counting them beyond that (AccountKey.namedOtherAreas)
    private func usedFor(_ l: UIText) -> String {
        var users: [String] = key == .busTime ? [l.t("MTA buses (MTA Bus Time)")] : []
        // Only the operators the account makes live: NJ Transit's light rail has timetables only, with or without it
        users += key.sources.filter { $0.liveWithAccount && MetroArea.areas(of: $0).contains(area) }.map(\.name)
        users += key.buses.filter { MetroArea.areas(ofBus: $0).contains(area) }.map { $0.needsAccount ? l.t("NJ Transit buses") : $0.name }
        var parts: [String] = []
        if !users.isEmpty { parts.append(l.f("For: %@", l.commaList(users))) }
        let others = key.otherAreas(than: area)
        if others.count > AccountKey.namedOtherAreas {
            parts.append(l.f("Also used in %@ other areas.", l.number(Double(others.count))))
        } else if !others.isEmpty {
            parts.append(l.f("Also used in %@.", l.commaList(others.map(l.metroAreaName))))
        }
        return parts.joined(separator: " · ")
    }

    private func status(_ l: UIText) -> Status {
        switch key {
        case .busTime:
            let check = transit.credentialChecks[.busTime]
            let invalid = transit.hasBusKey && (transit.busError == .invalidKey || check == .rejected)
            let badge = invalid ? nil : SourceBadge.credential(has: transit.hasBusKey, refused: false, check: check)
            // A key the Keychain couldn't read isn't "No key yet": the row offers to read it again instead
            if transit.busKeyUnreadable { return Status(retry: .busTime) }
            if !transit.hasBusKey { return Status(text: l.t("Free, but needs your own key. No key yet.")) }
            if invalid { return Status(text: l.t("Key saved, but MTA Bus Time didn't accept it."), refused: true) }
            if badge == .notChecked {
                return Status(text: l.t("Key saved, but it couldn't be checked yet. It's checked again when you open Settings."), badge: badge)
            }
            return Status(text: l.t("Key saved in your Keychain."), badge: badge)
        case .suffolk:
            let check = transit.credentialChecks[.suffolk]
            let refused = transit.hasSuffolkKey && (transit.suffolkKeyRejected || check == .rejected)
            let badge = refused ? nil : SourceBadge.credential(has: transit.hasSuffolkKey, refused: false, check: check)
            if transit.suffolkKeyUnreadable { return Status(retry: .suffolk) }
            if !transit.hasSuffolkKey { return Status(text: l.t("Free, but needs your own key. No key yet.")) }
            if refused { return Status(text: l.t("Key saved, but Swiftly didn't accept it. Using the timetable."), refused: true) }
            if badge == .notChecked {
                // What Swiftly answered when the key couldn't be checked (an error code or message), on a new line
                let said = transit.suffolkCheckNote.map { "\n" + l.f("Swiftly said: %@", $0) } ?? ""
                return Status(text: l.t("Key saved, but it couldn't be checked yet. It's checked again when you open Settings.") + said,
                              badge: badge)
            }
            return Status(text: l.t("Key saved in your Keychain."), badge: badge)
        case .njTransit:
            let has = transit.hasNJTransitAccount
            // One account, tested on the rail and the bus servers: it shows as working once either accepted it
            let checks = [transit.credentialChecks[.njTransitRail], transit.credentialChecks[.njTransitBus]]
            let check: CredentialCheck? = checks.contains(.works) ? .works : checks.contains(.checking) ? .checking : checks[0]
            let refused = has && (transit.njTransitRejected || transit.njTransitBusRejected)
            let badge = refused ? nil : SourceBadge.credential(has: has, refused: false, check: check)
            if transit.njTransitAccountUnreadable { return Status(retry: .njTransitRail) }
            if !has { return Status(text: l.t("Live times need your own free NJ Transit developer account. Using the timetable for now.")) }
            if transit.njTransitRejected {
                return Status(text: refusedDetail(l.t("Account saved, but NJ Transit didn't accept it. Using the timetable."), l), refused: true)
            }
            if transit.njTransitBusRejected {
                return Status(text: refusedDetail(l.t("Account saved, but NJ Transit didn't accept it for buses. Using the timetable."), l),
                              refused: true)
            }
            if badge == .notChecked {
                return Status(text: l.t("Account saved, but it couldn't be checked yet. It's checked again when you open Settings."), badge: badge)
            }
            return Status(text: l.t("Account saved in your Keychain."), badge: badge)
        }
    }

    /// "NJ Transit didn't accept it" plus what NJ Transit said, when it said more than that (its words are in the log either way)
    private func refusedDetail(_ text: String, _ l: UIText) -> String {
        var detail = text
        if let said = transit.njTransitRefusal, !NJTransitLive.saysOnlyRefused(said) { detail += "\n" + l.f("NJ Transit said: %@", said) }
        if transit.njTransitTestOnly == true { detail += "\n" + l.t("Your account works only on NJ Transit's test system. Ask NJ Transit to turn on live data access for your account.") }
        return detail
    }
}

/// The Suffolk County Transit row: realtime data needs a Swiftly key the user requests themselves (like MTA Bus Time, stored only in the Keychain)
/// Suffolk County Transit in Data source (New York's Bus page): live with the Swiftly key under Keys and accounts above
/// (see AccountKeyRow), otherwise the timetable
struct SuffolkKeyRow: View {
    @EnvironmentObject var transit: TransitModel
    let feed: RegionalBusFeed

    var body: some View {
        let l = transit.l10n
        let check = transit.credentialChecks[.suffolk]
        let refused = transit.hasSuffolkKey && (transit.suffolkKeyRejected || check == .rejected)
        let badge = SourceBadge.credential(has: transit.hasSuffolkKey, refused: refused, check: check) ?? .timetable
        let detail = !transit.hasSuffolkKey ? l.t("Live times need a free Suffolk County Transit key (above). Using the timetable for now.")
            : refused ? l.t("Swiftly didn't accept your key (above). Using the timetable for now.")
            : l.t("Live times with your Suffolk County Transit key (above).")
        SourceRow(icon: "key", name: feed.name, detail: detail, detailColor: refused ? .noticeRed : .secondary, badge: badge)
    }
}

/// Shown at a key or account the Keychain couldn't read (a denied or cancelled prompt, a locked keychain) instead of "No key yet":
/// it may well still be saved. Clicking reads it again, which may show the system's Keychain prompt. Blue only because it's clickable.
struct KeychainRetryLine: View {
    @EnvironmentObject var transit: TransitModel
    let credential: Credential
    /// false where the height must not be fixed (the main window's fixed header, see BusKeyPrompt): it then wraps to 3 lines at most
    var fixedHeight = true

    var body: some View {
        Button(transit.l10n.t("Couldn't read the Keychain. Click to try again.")) { transit.retryKeychainRead(credential) }
            .buttonStyle(.link)
            .multilineTextAlignment(.leading)
            .lineLimit(fixedHeight ? nil : 3)
            .fixedSize(horizontal: false, vertical: fixedHeight)
            .disabled(transit.retryingKeychainRead)
    }
}

/// Whether there is a key and whether it works.
struct BusKeyStatus: View {
    @EnvironmentObject var transit: TransitModel

    var body: some View {
        let l = transit.l10n
        if transit.busKeyUnreadable {
            KeychainRetryLine(credential: .busTime)
        } else if !transit.hasBusKey {
            Label(l.t("No key yet"), systemImage: "key")
                .foregroundStyle(.secondary)
        } else if transit.busError == .invalidKey || transit.credentialChecks[.busTime] == .rejected {
            Label(l.t("Key saved, but MTA Bus Time didn't accept it."), systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.noticeRed)
        } else if transit.credentialChecks[.busTime] != .works {
            Label(l.t("Key saved, but it couldn't be checked yet. It's checked again when you open Settings."), systemImage: "questionmark.circle")
                .foregroundStyle(Color.noticeOrange)
        } else {
            Label(l.t("Key saved in your Keychain."), systemImage: "checkmark.seal")
                .foregroundStyle(Color.noticeGreen)
        }
    }
}
