import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// Add / replace the Suffolk Swiftly key. The request form asks for a name and email, so the user fills it in themselves; the app doesn't do it for them.
struct SuffolkKeySheet: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    /// The eye button shows the key being pasted (never a saved one); hidden each time the window opens and when Save is clicked
    @State private var keyShown = false
    @State private var message: String?
    @State private var saving = false
    /// Remove Key asks first (see RemoveKeyAlert)
    @State private var confirmRemove = false

    /// The request form listed on the Suffolk County website (Swiftly's form)
    static let requestURL = URL(string: "https://docs.google.com/forms/d/e/1FAIpQLScy9Jye91QPSTS3WVEU-13es0A1rT9Ep5JhAmXUZEiop7fmIw/viewform")!

    var body: some View {
        let l = transit.l10n
        // Also while another copy of this window saves (see TransitModel.savingSuffolkKey)
        let busy = saving || transit.savingSuffolkKey
        VStack(alignment: .leading, spacing: 14) {
            Label(l.t("Suffolk County Transit key"), systemImage: "key.fill")
                .font(.scaled(.title3).bold())
            Text(l.t("Suffolk's live bus times come from Swiftly. Ask Swiftly for a free key with the request form: choose Suffolk County Transit and GTFS-Realtime Trip Updates. Swiftly reviews each request and emails the key. Paste it here. It's kept only in this Mac's Keychain."))
                .font(.scaled(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("1. Get a key")).font(.scaled(.headline))
                Link(destination: Self.requestURL) {
                    Label(l.t("Open the Swiftly Request Form"), systemImage: "arrow.up.right.square")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("2. Paste it here")).font(.scaled(.headline))
                SecretField(title: transit.hasSuffolkKey ? l.t("Paste a new key to replace it") : l.t("Paste your key here"),
                            text: $draft, shown: $keyShown, showLabel: l.t("Show key"), hideLabel: l.t("Hide key"), onSubmit: save)
                if let message {
                    Text(message).font(.scaled(.caption)).foregroundStyle(Color.noticeRed)
                }
            }
            Group {
                if transit.suffolkKeyUnreadable {
                    KeychainRetryLine(credential: .suffolk)
                } else if !transit.hasSuffolkKey {
                    Label(l.t("No key yet"), systemImage: "key").foregroundStyle(.secondary)
                } else if transit.suffolkKeyRejected || transit.credentialChecks[.suffolk] == .rejected {
                    Label(l.t("Key saved, but Swiftly didn't accept it. Using the timetable."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.noticeRed)
                } else if transit.credentialChecks[.suffolk] != .works {
                    Label(l.t("Key saved, but it couldn't be checked yet. It's checked again when you open Settings.") + (transit.suffolkCheckNote.map { "\n" + l.f("Swiftly said: %@", $0) } ?? ""),
                          systemImage: "questionmark.circle")
                        .foregroundStyle(Color.noticeOrange)
                } else {
                    Label(l.t("Key saved in your Keychain."), systemImage: "checkmark.seal").foregroundStyle(Color.noticeGreen)
                }
            }
            .font(.scaled(.callout))
            HStack {
                // Also after a removal that left the key in the Keychain, so it can be tried again
                if transit.hasSuffolkKey || transit.suffolkKeyLeftover {
                    Button(l.t("Remove Key"), role: .destructive) { confirmRemove = true }
                        .appButtonStyle()
                        .disabled(busy)
                        .modifier(RemoveKeyAlert(isPresented: $confirmRemove, account: false) {
                            message = transit.removeSuffolkKey() ? nil : transit.l10n.t("Couldn't remove the key from the Keychain.")
                        })
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                // A save in progress can't be called back (it may already be writing to the Keychain): Cancel waits for it
                Button(l.t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appButtonStyle()
                    .disabled(saving)
                Button(l.t("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .appButtonStyle(.defaultAction)
                    .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .environment(\.locale, transit.language.locale)
        .environment(\.layoutDirection, transit.layoutDirection)
        .onAppear {
            // Says why there's a Remove Key button with no key
            if transit.suffolkKeyLeftover { message = transit.l10n.t("Couldn't remove the key from the Keychain.") }
        }
    }

    /// Tests the key with Swiftly first; a refused key isn't saved and the window stays open with the reason
    private func save() {
        guard !saving, !transit.savingSuffolkKey, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        keyShown = false
        saving = true
        message = nil
        Task {
            let result = await transit.saveSuffolkKey(draft)
            saving = false
            let l = transit.l10n
            switch result {
            case .saved, .savedUnchecked:
                draft = ""
                dismiss()
            case .rejected:
                message = l.t("Swiftly didn't accept this key. Check that you copied all of it and that Swiftly has approved it.")
            case .keychainFailed:
                message = l.t("Couldn't save the key to the Keychain.")
            }
        }
    }
}

/// Window to add / replace the NJ Transit developer account. The account is stored only in this Mac's Keychain, never in code or settings files.
struct NJTransitAccountSheet: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    /// The eye button shows the password being typed (never a saved one); hidden each time the window opens and when Save is clicked
    @State private var passwordShown = false
    @State private var message: String?
    @State private var saving = false
    /// Remove Account asks first (see RemoveKeyAlert)
    @State private var confirmRemove = false

    var body: some View {
        let l = transit.l10n
        // Also while another copy of this window saves (see TransitModel.savingNJTransitAccount)
        let busy = saving || transit.savingNJTransitAccount
        VStack(alignment: .leading, spacing: 14) {
            Label(l.t("NJ Transit account"), systemImage: "key.fill")
                .font(.scaled(.title3).bold())
            Text(l.t("Live NJ Transit times (trains and buses) need a free NJ Transit developer account. Sign up on NJ Transit's developer site and wait for the email saying your account is approved, then enter your username and password below. They're kept only in this Mac's Keychain. Without an account, NJ Transit times come from the timetable."))
                .font(.scaled(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("1. Get an account")).font(.scaled(.headline))
                Link(destination: NJTransitLive.signUpURL) {
                    Label(l.t("Sign Up on NJ Transit's Developer Site"), systemImage: "arrow.up.right.square")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("2. Enter it here")).font(.scaled(.headline))
                let usernameHint = l.t("Type your username exactly as NJ Transit shows it at the top right of its developer site, including capital letters.")
                TextField(l.t("Username"), text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    // VoiceOver reads the line under the field with it
                    .accessibilityHint(usernameHint)
                // NJ Transit accepts the username only as its site shows it, in capitals: lowercase letters turn the line orange.
                // Only a warning: what's typed is never changed, and Save still works
                let lowercase = username != username.uppercased()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if lowercase { Image(systemName: "exclamationmark.triangle") }
                    Text(usernameHint).fixedSize(horizontal: false, vertical: true)
                }
                .font(.scaled(.caption))
                .foregroundStyle(lowercase ? Color.noticeOrange : Color.secondary)
                .accessibilityHidden(true)
                SecretField(title: l.t("Password"), text: $password, shown: $passwordShown,
                            showLabel: l.t("Show password"), hideLabel: l.t("Hide password"), contentType: .password, onSubmit: save)
                if let message {
                    Text(message).font(.scaled(.caption)).foregroundStyle(Color.noticeRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Group {
                if transit.njTransitAccountUnreadable {
                    KeychainRetryLine(credential: .njTransitRail)
                } else if !transit.hasNJTransitAccount {
                    Label(l.t("No account yet"), systemImage: "key").foregroundStyle(.secondary)
                } else if transit.njTransitRejected && transit.njTransitBusRejected {
                    Label(l.t("Account saved, but NJ Transit didn't accept it."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.noticeRed)
                } else if transit.njTransitRejected || transit.njTransitBusRejected {
                    // Trains and buses are two APIs; only one may be enabled
                    Label(transit.njTransitRejected ? l.t("Account saved. It works for buses, but not for trains.")
                              : l.t("Account saved. It works for trains, but not for buses."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.noticeOrange)
                } else if transit.credentialChecks[.njTransitRail] != .works && transit.credentialChecks[.njTransitBus] != .works {
                    Label(l.t("Account saved, but it couldn't be checked yet. It's checked again when you open Settings."), systemImage: "questionmark.circle")
                        .foregroundStyle(Color.noticeOrange)
                } else {
                    Label(l.t("Account saved in your Keychain."), systemImage: "checkmark.seal").foregroundStyle(Color.noticeGreen)
                }
            }
            .font(.scaled(.callout))
            HStack {
                // Also after a removal that left part of the account behind, so it can be tried again
                if transit.hasNJTransitAccount || transit.njTransitPartlyRemoved {
                    Button(l.t("Remove Account"), role: .destructive) { confirmRemove = true }
                        .appButtonStyle()
                        .disabled(busy)
                        .modifier(RemoveKeyAlert(isPresented: $confirmRemove, account: true) {
                            message = transit.removeNJTransitAccount() ? nil : transit.l10n.t("Couldn't remove the account from the Keychain.")
                        })
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                // A save in progress can't be called back (it may already be writing to the Keychain): Cancel waits for it
                Button(l.t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appButtonStyle()
                    .disabled(saving)
                Button(l.t("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .appButtonStyle(.defaultAction)
                    .disabled(busy || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .environment(\.locale, transit.language.locale)
        .environment(\.layoutDirection, transit.layoutDirection)
        .onAppear {
            // Says why there's a Remove Account button with no account
            if transit.njTransitPartlyRemoved { message = transit.l10n.t("Couldn't remove the account from the Keychain.") }
        }
    }

    private func save() {
        guard !saving, !transit.savingNJTransitAccount, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else { return }
        passwordShown = false
        saving = true
        message = nil
        Task {
            let result = await transit.saveNJTransitAccount(username: username, password: password)
            saving = false
            let l = transit.l10n
            switch result {
            case .saved, .savedUnchecked:
                password = ""
                dismiss()
            case .rejected:
                let said = transit.njTransitTriedRefusal.flatMap { NJTransitLive.saysOnlyRefused($0) ? nil : "\n" + l.f("NJ Transit said: %@", $0) } ?? ""
                let testOnly = transit.njTransitTriedTestOnly ? "\n" + l.t("Your account works only on NJ Transit's test system. Ask NJ Transit to turn on live data access for your account.") : ""
                message = l.t("NJ Transit didn't accept this username and password. Check that the username matches the one at the top right of NJ Transit's developer site, including capital letters. If you just signed up, wait for the approval email.") + said + testOnly
            case .keychainFailed:
                message = l.t("Couldn't save the account to the Keychain.")
            }
        }
    }
}

/// A password or key field with an eye button inside it, at the trailing edge (the left in right-to-left languages): clicking it shows
/// what's typed, clicking again hides it. Only what's typed in this window can be shown: a saved password or key is never read into it.
/// The window hides it again when it opens and when Save is clicked (shown). Switching keeps the text, and the caret where it was.
struct SecretField: View {
    let title: String
    @Binding var text: String
    @Binding var shown: Bool
    /// The button's hover text and VoiceOver label: "Show password" or "Show key" while hidden, "Hide password" or "Hide key" while shown
    let showLabel: String
    let hideLabel: String
    var contentType: NSTextContentType?
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if shown {
                TextField(title, text: $text).textContentType(contentType)
            } else {
                SecureField(title, text: $text).textContentType(contentType)
            }
        }
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .onSubmit(onSubmit)
        .overlay(alignment: .trailing) {
            Button(action: toggle) {
                Image(systemName: shown ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3)
            .help(shown ? hideLabel : showLabel)
            .accessibilityLabel(shown ? hideLabel : showLabel)
        }
    }

    /// Typing goes on where it was: when the field had the focus, the other field takes it over with the same caret (or selection)
    private func toggle() {
        let range = focused ? (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectedRange() : nil
        shown.toggle()
        guard let range else { return }
        DispatchQueue.main.async {
            focused = true
            // Focusing a field selects all of it: put the caret back once it has the focus
            DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.setSelectedRange(range) }
        }
    }
}

/// Removing a key or an account asks first: getting it again means going back to the operator's website (and for some, waiting
/// for an approval email), so a slip of the mouse shouldn't cost that
struct RemoveKeyAlert: ViewModifier {
    @EnvironmentObject var transit: TransitModel
    @Binding var isPresented: Bool
    /// An account (NJ Transit's) rather than a key: the question says which
    let account: Bool
    let remove: () -> Void

    func body(content: Content) -> some View {
        let l = transit.l10n
        content.alert(account ? l.t("Remove this account?") : l.t("Remove this key?"), isPresented: $isPresented) {
            Button(l.t("Cancel"), role: .cancel) {}
            Button(l.t("Remove"), role: .destructive) { remove() }
        } message: {
            Text(l.t("Live times that need it stop until you add it again."))
        }
    }
}

/// Window to add / replace the MTA Bus Time key (opened from Settings and from the prompt in the main bus view).
/// The key is stored only in this Mac's Keychain, never in code or settings files; when the app is shared, the other person enters their own key.
struct BusKeySheet: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    /// The eye button shows the key being pasted (never a saved one); hidden each time the window opens and when Save is clicked
    @State private var keyShown = false
    @State private var message: String?
    @State private var saving = false
    /// Remove Key asks first (see RemoveKeyAlert)
    @State private var confirmRemove = false

    static let signUpURL = URL(string: "https://register.developer.obanyc.com/")!

    var body: some View {
        let l = transit.l10n
        // Also while another copy of this window saves (see TransitModel.savingBusKey)
        let busy = saving || transit.savingBusKey
        VStack(alignment: .leading, spacing: 14) {
            Label(l.t("MTA Bus Time key"), systemImage: "key.fill")
                .font(.scaled(.title3).bold())
            Text(l.t("Live bus times need a free key from MTA. It takes about two minutes: open the sign-up page, fill in your name and email, and MTA emails you the key. Paste it here. It's kept only in this Mac's Keychain."))
                .font(.scaled(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("1. Get a key")).font(.scaled(.headline))
                Link(destination: Self.signUpURL) {
                    Label(l.t("Get a Free Key from MTA"), systemImage: "arrow.up.right.square")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(l.t("2. Paste it here")).font(.scaled(.headline))
                SecretField(title: transit.hasBusKey ? l.t("Paste a new key to replace it") : l.t("Paste your key here"),
                            text: $draft, shown: $keyShown, showLabel: l.t("Show key"), hideLabel: l.t("Hide key"), onSubmit: save)
                if let message {
                    Text(message).font(.scaled(.caption)).foregroundStyle(Color.noticeRed)
                }
            }
            BusKeyStatus().font(.scaled(.callout))
            HStack {
                // Also after a removal that left the key in the Keychain, so it can be tried again
                if transit.hasBusKey || transit.busKeyLeftover {
                    Button(l.t("Remove Key"), role: .destructive) { confirmRemove = true }
                        .appButtonStyle()
                        .disabled(busy)
                        .modifier(RemoveKeyAlert(isPresented: $confirmRemove, account: false) {
                            message = transit.removeBusKey() ? nil : transit.l10n.t("Couldn't remove the key from the Keychain.")
                        })
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                // A save in progress can't be called back (it may already be writing to the Keychain): Cancel waits for it
                Button(l.t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appButtonStyle()
                    .disabled(saving)
                Button(l.t("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .appButtonStyle(.defaultAction)
                    .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .environment(\.locale, transit.language.locale)
        .environment(\.layoutDirection, transit.layoutDirection)
        .onAppear {
            // Says why there's a Remove Key button with no key
            if transit.busKeyLeftover { message = transit.l10n.t("Couldn't remove the key from the Keychain.") }
        }
    }

    /// Tests the key with MTA first; a refused key isn't saved and the window stays open with the reason
    private func save() {
        guard !saving, !transit.savingBusKey, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        keyShown = false
        saving = true
        message = nil
        Task {
            let result = await transit.saveBusKey(draft)
            saving = false
            let l = transit.l10n
            switch result {
            case .saved, .savedUnchecked:
                draft = ""
                dismiss()
            case .rejected:
                message = l.t("MTA Bus Time didn't accept this key. Check that you copied all of it.")
            case .keychainFailed:
                message = l.t("Couldn't save the key to the Keychain.")
            }
        }
    }
}
