import Foundation
import Security

/// The half of an account swap that caam cannot do on this machine.
///
/// Claude Code's native installer keeps the OAuth token set in the login
/// Keychain, not in `~/.claude/.credentials.json`. caam swaps accounts by
/// copying that file, so on a native install it has nothing to copy -- `caam
/// robot status` reports the file as required-but-missing and every profile
/// stays blocked. Reading and writing the Keychain item directly is the only
/// thing that actually moves the account.
///
/// One sharp edge worth stating: the item's `account` attribute is the *Unix
/// username*, not the Claude email. Every Claude account on the machine
/// therefore collides on this single item, which is why swapping has to be an
/// explicit stash-then-write rather than anything resembling a file move.
enum Keychain {

    enum Failure: Error, CustomStringConvertible {
        case notFound
        case denied
        case os(OSStatus)

        var description: String {
            switch self {
            case .notFound: return "no Claude credentials in the Keychain"
            case .denied:   return "Keychain access denied — grant Headroom access when macOS asks"
            case .os(let s):
                let message = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
                return "Keychain error \(s): \(message)"
            }
        }
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The Unix username, which is what Claude Code stores the item under.
    static var defaultAccount: String { NSUserName() }

    /// Whether the item exists, without reading it.
    ///
    /// Asking only for attributes deliberately avoids `kSecReturnData`: returning
    /// the secret is what triggers the "Headroom wants to use your confidential
    /// information" prompt. Existence can be checked silently, so nothing
    /// surprises the user until they actually ask for a swap.
    static func exists(
        service: String = ClaudePaths.keychainService,
        account: String = defaultAccount
    ) -> Bool {
        var q = query(service: service, account: account)
        q[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess
    }

    /// When the item was last written -- Claude Code refreshes the token in
    /// place, so this doubles as "when did this account last talk to the server".
    static func modifiedAt(
        service: String = ClaudePaths.keychainService,
        account: String = defaultAccount
    ) -> Date? {
        var q = query(service: service, account: account)
        q[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any]
        else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    /// Reads the secret. This is the call that prompts.
    static func read(
        service: String = ClaudePaths.keychainService,
        account: String = defaultAccount
    ) throws -> Data {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw Failure.os(status) }
            return data
        case errSecItemNotFound:
            throw Failure.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw Failure.denied
        default:
            throw Failure.os(status)
        }
    }

    /// Writes the secret, creating the item if Claude Code has never run.
    static func write(
        _ data: Data,
        service: String = ClaudePaths.keychainService,
        account: String = defaultAccount
    ) throws {
        let q = query(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }

        guard status == errSecItemNotFound else {
            if status == errSecAuthFailed || status == errSecUserCanceled {
                throw Failure.denied
            }
            throw Failure.os(status)
        }

        // Only reached when Claude Code has never signed in, so there is no
        // existing item whose attributes we would otherwise inherit. Pin
        // accessibility explicitly: the default is `kSecAttrAccessibleWhenUnlocked`
        // with this-device-only semantics left to chance, and Claude Code needs to
        // read this item too.
        var insert = q
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure.os(addStatus) }
    }
}
