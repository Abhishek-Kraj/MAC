import Foundation
import Security

/// API keys in the login Keychain instead of the preferences plist, which is
/// plain text and travels in backups. One generic-password item per key under
/// this build's bundle id, so Dev, Beta and Prod keep their own; never synced.
///
/// Only for builds signed with an Apple Team ID. A Keychain item is tied to
/// the app's code identity; without a Team ID (a self-signed dev build) that
/// identity is the binary's hash, which changes on every rebuild, so macOS
/// asked for the login password each time. Those builds keep keys in
/// UserDefaults as before.
enum SecretStore {
    static let usesKeychain: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode,
                                            SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return dict[kSecCodeInfoTeamIdentifier as String] != nil
    }()

    /// A test binary has no bundle id; its own service keeps it away from the
    /// app's items (and from any Keychain prompt they would raise).
    private static let service = Bundle.main.bundleIdentifier ?? "tech.thecloser.mac.unbundled"
    private static let lock = NSLock()
    /// Reads are cached: `OpenRouterCatalog.hasKey` runs while views render.
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func string(_ account: String) -> String? {
        guard usesKeychain else { return UserDefaults.standard.string(forKey: account) }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[account] { return hit.isEmpty ? nil : hit }
        let value = read(account)
        cache[account] = value ?? ""
        return value
    }

    /// Saves `value`; an empty value deletes the item.
    static func set(_ value: String, for account: String) {
        guard usesKeychain else { return UserDefaults.standard.set(value, forKey: account) }
        lock.lock(); defer { lock.unlock() }
        if write(value, for: account) {
            cache[account] = value
        } else {
            NSLog("[SecretStore] could not save %@", account)
        }
    }

    /// Moves keys an earlier build left in UserDefaults into the Keychain. The
    /// plist copy goes only once the Keychain reads back the same value, so a
    /// failed write never loses a key.
    static func migrateFromDefaults(_ accounts: [String], defaults: UserDefaults = .standard) {
        guard usesKeychain else { return }
        for account in accounts {
            guard let legacy = defaults.string(forKey: account) else { continue }
            if !legacy.isEmpty && string(account) == nil {
                set(legacy, for: account)
                lock.lock(); let saved = read(account); lock.unlock()
                guard saved == legacy else { continue }
            }
            defaults.removeObject(forKey: account)
        }
    }

    // MARK: - Keychain

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String, for account: String) -> Bool {
        let q = query(account)
        guard !value.isEmpty else {
            let status = SecItemDelete(q as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(q as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = q
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
