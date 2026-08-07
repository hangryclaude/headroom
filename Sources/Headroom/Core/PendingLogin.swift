import Foundation

/// A sign-in waiting for its code.
///
/// Exists so the browser half of the OAuth flow can happen somewhere other than
/// the terminal that started it — another Mac, a phone, a browser profile that
/// is already signed in as the account being added.
///
/// The verifier stored here is the secret half of the PKCE pair, so the file is
/// 0600 and is deleted the moment its code is redeemed. It is deliberately *not*
/// in the Keychain: this is a value with a lifetime of about two minutes, and
/// putting it there would mean a macOS authorisation prompt in the middle of a
/// flow whose whole point is to avoid disturbing the live login.
struct PendingLogin {
    let name: String
    let pending: OAuthFlow.Pending

    private static let filename = ".pending-login.json"

    func write(to directory: URL) throws {
        let object: [String: String] = [
            "name": name,
            "verifier": pending.verifier,
            "state": pending.state,
            "url": pending.url.absoluteString,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let url = directory.appending(path: Self.filename)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        // After the write, not before: an atomic write replaces the inode, so
        // permissions set on the old one do not survive.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read(from directory: URL) throws -> PendingLogin {
        let url = directory.appending(path: filename)
        let data = try Data(contentsOf: url)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let name = o["name"],
              let verifier = o["verifier"],
              let state = o["state"],
              let raw = o["url"], let parsed = URL(string: raw)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return PendingLogin(
            name: name,
            pending: OAuthFlow.Pending(verifier: verifier, state: state, url: parsed))
    }

    static func clear(from directory: URL) {
        try? FileManager.default.removeItem(at: directory.appending(path: filename))
    }
}
