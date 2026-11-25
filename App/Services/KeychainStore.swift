import Foundation
import Security
import TransitCore

/// Stores the MTA Bus Time key in this Mac's Keychain (never in code, settings files or shared data).
/// Each user enters their own key in Settings.
enum KeychainStore {
    private static let service = "com.cheecar.catchmytrain"
    static let busTimeAccount = "MTA Bus Time API key"
    /// NJ Transit developer account (live data for trains and light rail): username, password, and the token obtained with them
    static let njTransitUsername = "NJ Transit username"
    static let njTransitPassword = "NJ Transit password"
    static let njTransitToken = "NJ Transit token"
    /// Bus live data uses a different API, with a different token too (obtained with the same account)
    static let njTransitBusToken = "NJ Transit bus token"
    /// Suffolk County Transit live data (Swiftly API): a key the user applies for
    static let suffolkKey = "Suffolk County Transit Swiftly API key"

    /// What reading an item found. Only "no such item" means nothing is saved: a denied or cancelled prompt, or a locked keychain,
    /// is a failure, and the item may still be on this Mac, so it must never be taken for a missing key.
    enum Lookup<Value: Equatable & Sendable>: Equatable, Sendable {
        case found(Value)
        case notFound
        case failed(OSStatus)

        /// The value, when it was read
        var value: Value? {
            if case .found(let value) = self { return value }
            return nil
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// The stored NJ Transit account (when both username and password exist). Read once and kept: every refresh needs it, no need to read the Keychain each time;
    /// re-read when the username or password is saved or deleted. A read that failed isn't kept, so the next one asks the Keychain again.
    static var njTransitAccountLookup: Lookup<NJTransitClient.Account> {
        accountCache.value {
            // The password isn't read when the username can't be: each read of a denied item may show the system prompt again
            switch read(njTransitUsername) {
            case .failed(let status): return .failed(status)
            case .notFound: return .notFound
            case .found(let username):
                switch read(njTransitPassword) {
                case .found(let password): return .found(NJTransitClient.Account(username: username, password: password))
                case .notFound: return .notFound
                case .failed(let status): return .failed(status)
                }
            }
        }
    }

    /// The stored NJ Transit account; nil when there's none or it couldn't be read (see njTransitAccountLookup to tell the two apart)
    static var njTransitAccount: NJTransitClient.Account? { njTransitAccountLookup.value }

    private static let accountCache = AccountCache()

    private final class AccountCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: Lookup<NJTransitClient.Account>?
        func value(_ load: () -> Lookup<NJTransitClient.Account>) -> Lookup<NJTransitClient.Account> {
            lock.lock(); defer { lock.unlock() }
            if let cached { return cached }
            let v = load()
            if !v.isFailure { cached = v }
            return v
        }
        func reset() {
            lock.lock(); defer { lock.unlock() }
            cached = nil
        }
    }

    private static func accountChanged(_ account: String) {
        if account == njTransitUsername || account == njTransitPassword { accountCache.reset() }
    }

    /// What one background read of the keys and the account found (nil: not read this time)
    struct Reads: Sendable {
        var busKey: Lookup<String>?
        var account: Lookup<NJTransitClient.Account>?
        var suffolkKey: Lookup<String>?
    }

    /// Reads the chosen items. Each read may wait for the system's Keychain prompt, so call this off the main thread.
    static func readKeys(bus: Bool, account: Bool, suffolk: Bool) -> Reads {
        Reads(busKey: bus ? read(busTimeAccount) : nil,
              account: account ? njTransitAccountLookup : nil,
              suffolkKey: suffolk ? read(suffolkKey) : nil)
    }

    /// Read one item. Read the new "data protection keychain" first; if it has nothing (or this build can't use it), read the copy an older version saved
    /// in the file-based keychain, and move it to the new one if found (the "available after first unlock" setting doesn't work in the legacy keychain,
    /// and after switching to the release signature it may show system dialogs). A failure in the new keychain doesn't fall back: a copy left in the
    /// legacy keychain could be older, and moving it would replace the real one.
    static func read(_ account: String) -> Lookup<String> {
        var result = read(account, modern: true)
        if result == .notFound {
            result = read(account, modern: false)
            if case .found(let legacy) = result, write(legacy, for: account, modern: true) == errSecSuccess {
                SecItemDelete(baseQuery(account, modern: false) as CFDictionary)
            }
        }
        if case .failed(let status) = result {
            let text = "\(status)"
            AppLog.data.error("Reading \(account, privacy: .public) from the Keychain failed: \(text, privacy: .public)")
        }
        return result
    }

    /// Save. Store in the new keychain; fall back to the legacy keychain when this Mac's signature doesn't support it (missing entitlement).
    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        var status = write(value, for: account, modern: true)
        if status == errSecSuccess {
            // Delete the copy left by the older version, so there aren't two
            SecItemDelete(baseQuery(account, modern: false) as CFDictionary)
        } else if status == errSecMissingEntitlement {
            status = write(value, for: account, modern: false)
        }
        accountChanged(account)
        return status == errSecSuccess
    }

    /// Delete (from both the new and legacy keychains). Returns false if it can't be deleted, so the UI can show a notice.
    /// A failure is logged like a failed read: the item's fixed name and what each keychain answered, never its value.
    static func delete(_ account: String) -> Bool {
        let modern = SecItemDelete(baseQuery(account, modern: true) as CFDictionary)
        let legacy = SecItemDelete(baseQuery(account, modern: false) as CFDictionary)
        accountChanged(account)
        let succeeded = deleteSucceeded(modern: modern, legacy: legacy)
        if !succeeded {
            let text = "data protection keychain \(modern), legacy keychain \(legacy)"
            AppLog.data.error("Deleting \(account, privacy: .public) from the Keychain failed: \(text, privacy: .public)")
        }
        return succeeded
    }

    /// Whether nothing is left after deleting from both keychains: each one either deleted the item, had none, or isn't available
    /// to this build (missing entitlement). Anything else (a denied or cancelled prompt, interaction not allowed) leaves the item there.
    static func deleteSucceeded(modern: OSStatus, legacy: OSStatus) -> Bool {
        let ok: Set<OSStatus> = [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement]
        return ok.contains(modern) && ok.contains(legacy)
    }

    /// What one keychain's answer to a read means. Only errSecItemNotFound says nothing is saved; so does a missing entitlement in the
    /// data protection keychain (a build signed without a team can't use it, and the legacy keychain is read instead). Anything else is a failure.
    static func lookup(status: OSStatus, data: Data?, modern: Bool) -> Lookup<String> {
        switch status {
        case errSecSuccess:
            // An empty or unreadable value counts as none (the app never saves one)
            guard let data, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return .notFound }
            return .found(s)
        case errSecItemNotFound:
            return .notFound
        case errSecMissingEntitlement where modern:
            return .notFound
        default:
            return .failed(status)
        }
    }

    private static func read(_ account: String, modern: Bool) -> Lookup<String> {
        var query = baseQuery(account, modern: modern)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return lookup(status: status, data: item as? Data, modern: modern)
    }

    private static func write(_ value: String, for account: String, modern: Bool) -> OSStatus {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(baseQuery(account, modern: modern) as CFDictionary, update)
        if status == errSecItemNotFound {
            var query = baseQuery(account, modern: modern)
            query[kSecValueData as String] = data
            // Only on this Mac (not synced to iCloud), readable once unlocked after startup (background refreshes from the menu bar need it too)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        return status
    }

    private static func baseQuery(_ account: String, modern: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if modern { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }
}
