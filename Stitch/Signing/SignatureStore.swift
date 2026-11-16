import Foundation
import LocalAuthentication
import Observation
import Security

/// Codable values in the login Keychain (generic passwords under Stitch's service name).
struct KeychainStore: Sendable {
    var service = "com.liamblackshawbrown.Stitch"

    enum Failure: LocalizedError {
        case status(OSStatus)
        /// The saved item couldn't be read, so Stitch won't write over it.
        case wontOverwrite(String)
        var errorDescription: String? {
            switch self {
            case .status(let s): (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
            case .wontOverwrite(let what):
                "Stitch couldn't read your saved \(what) from the Keychain, so it won't save over it. Quit and reopen Stitch, and choose Always Allow if macOS asks."
            }
        }
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// What a read found. `damaged` means the bytes were there but didn't decode (a newer or older format);
    /// they've been copied to `<account>.unreadable` so saving over them loses nothing.
    enum Read<T> {
        case found(T)
        case missing
        case damaged
        case inaccessible(String)
    }

    func read<T: Decodable>(_ type: T.Type, account: String) -> Read<T> {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = out as? Data else {
            return .inaccessible(Failure.status(status).localizedDescription)
        }
        if let value = try? JSONDecoder().decode(T.self, from: data) { return .found(value) }
        if rawData(account: Self.backupAccount(account)) == nil {
            try? saveRaw(data, account: Self.backupAccount(account))
        }
        return .damaged
    }

    func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        if case .found(let value) = read(type, account: account) { return value }
        return nil
    }

    static func backupAccount(_ account: String) -> String { account + ".unreadable" }

    func rawData(account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func save<T: Encodable>(_ value: T, account: String) throws {
        try saveRaw(try JSONEncoder().encode(value), account: account)
    }

    func saveRaw(_ data: Data, account: String) throws {
        let q = query(account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Stitch \(account)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            add[kSecAttrSynchronizable as String] = false   // this Mac only, never iCloud Keychain
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.status(added) }
        } else if status != errSecSuccess {
            throw Failure.status(status)
        }
    }

    func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Your signature, initials and form-filling details, kept in the Keychain on this Mac only.
@MainActor
@Observable
final class SignatureStore {
    static let shared = SignatureStore()

    private(set) var signature: Signature?
    private(set) var initials: Signature?
    private(set) var profile = Profile()
    /// Set when something saved couldn't be read; shown in Settings.
    private(set) var problem: String?

    @ObservationIgnored private let keychain: KeychainStore
    /// Accounts that exist but couldn't be read: never written over until a reload reads them.
    @ObservationIgnored private var unreadable: Set<String> = []

    static let accounts = ["signature", "initials", "profile"]

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        reload()
    }

    func reload() {
        unreadable = []
        problem = nil
        signature = value(keychain.read(Signature.self, account: "signature"), account: "signature")
        initials = value(keychain.read(Signature.self, account: "initials"), account: "initials")
        profile = value(keychain.read(Profile.self, account: "profile"), account: "profile") ?? Profile()
    }

    private func value<T>(_ read: KeychainStore.Read<T>, account: String) -> T? {
        switch read {
        case .found(let value): return value
        case .missing: return nil
        case .damaged:
            problem = "Your saved \(Self.label(account)) was in a format this version can't read. A copy is kept in your Keychain as “Stitch \(KeychainStore.backupAccount(account))”."
            return nil
        case .inaccessible(let why):
            unreadable.insert(account)
            problem = "Couldn't read your saved \(Self.label(account)) from the Keychain (\(why)). Quit and reopen Stitch, and choose Always Allow if macOS asks."
            return nil
        }
    }

    static func label(_ account: String) -> String {
        account == "profile" ? "details" : account
    }

    private func guardWritable(_ account: String) throws {
        guard !unreadable.contains(account) else { throw KeychainStore.Failure.wontOverwrite(Self.label(account)) }
    }

    func setSignature(_ value: Signature?, initials isInitials: Bool) throws {
        let account = isInitials ? "initials" : "signature"
        try guardWritable(account)
        if let value { try keychain.save(value, account: account) } else { keychain.delete(account: account) }
        if isInitials { initials = value } else { signature = value }
    }

    func setProfile(_ value: Profile) throws {
        try guardWritable("profile")
        try keychain.save(value, account: "profile")
        profile = value
    }

    /// Removes the signature, initials, details and any unreadable copies from this Mac's Keychain.
    func deleteAll() {
        for account in Self.accounts {
            keychain.delete(account: account)
            keychain.delete(account: KeychainStore.backupAccount(account))
        }
        signature = nil
        initials = nil
        profile = Profile()
        unreadable = []
        problem = nil
    }
}

/// Asks for Touch ID (or the Mac's password) before a saved signature, initials or your details are used.
@MainActor
enum BiometricGate {
    private static var lastSuccess: Date?

    /// Within this many seconds of the last success, don't ask again (Settings → "Don't ask again for 5 minutes").
    static var graceSeconds: TimeInterval = 0

    static func authorize(_ reason: String) async -> Bool {
        if AppDelegate.isTesting { return true }
        if let last = lastSuccess, graceSeconds > 0, Date().timeIntervalSince(last) < graceSeconds { return true }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No Touch ID and no password set up: nothing to check against.
            return true
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { lastSuccess = Date() }
            return ok
        } catch {
            return false
        }
    }
}
