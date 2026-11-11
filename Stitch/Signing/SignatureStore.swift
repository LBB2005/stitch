import Foundation
import LocalAuthentication
import Observation
import Security

/// Codable values in the login Keychain (generic passwords under Stitch's service name).
struct KeychainStore: Sendable {
    var service = "com.liamblackshawbrown.Stitch"

    enum Failure: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            if case .status(let s) = self { return (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)" }
            return nil
        }
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let q = query(account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Stitch \(account)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
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

    @ObservationIgnored private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        reload()
    }

    func reload() {
        signature = keychain.load(Signature.self, account: "signature")
        initials = keychain.load(Signature.self, account: "initials")
        profile = keychain.load(Profile.self, account: "profile") ?? Profile()
    }

    func setSignature(_ value: Signature?, initials isInitials: Bool) throws {
        let account = isInitials ? "initials" : "signature"
        if let value { try keychain.save(value, account: account) } else { keychain.delete(account: account) }
        if isInitials { initials = value } else { signature = value }
    }

    func setProfile(_ value: Profile) throws {
        try keychain.save(value, account: "profile")
        profile = value
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
