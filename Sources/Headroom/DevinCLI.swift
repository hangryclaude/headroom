import Foundation

/// `Headroom --devin <status|set|org|allowance|list|clear>`
///
/// `set` reads the key from stdin and never from an argument. That is not
/// fussiness: anything passed as argv is visible to every process on the machine
/// via `ps`, and lands in shell history besides. Piping it means the secret
/// exists only in the pipe and the Keychain.
///
/// Usage:
///     pbpaste | Headroom --devin set
///     Headroom --devin org org-8a31…
///     Headroom --devin allowance 500
enum DevinCLI {
    static func run(_ arguments: [String]) {
        let command = arguments.first ?? "status"

        switch command {
        case "status":
            status()
        case "set":
            setKey()
        case "org":
            setOrg(arguments.dropFirst().first)
        case "allowance":
            setAllowance(arguments.dropFirst().first)
        case "clear":
            clear()
        case "list":
            list()
        default:
            print("usage: Headroom --devin <status|set|org <id>|allowance <n>|list|clear>")
        }
    }

    // MARK: Commands

    /// Never reads the key, so it never prompts — same contract as `--vault status`.
    private static func status() {
        print("key       \(DevinCredentials.hasKey ? "stored in Keychain (\(DevinCredentials.keychainService))" : "not set")")
        print("org       \(DevinCredentials.orgID ?? "not set")")
        print("allowance \(DevinCredentials.allowance.map { "\(Int($0)) ACUs" } ?? "not set — no gauge, count only")")
        print("ready     \(DevinCredentials.isConfigured ? "yes" : "no")")
    }

    private static func setKey() {
        // readLine strips the newline; a key pasted with a trailing space is the
        // most common way this goes wrong, so writeKey trims as well.
        guard let key = readLine(strippingNewline: true), !key.isEmpty else {
            print("no key on stdin — pipe it: pbpaste | Headroom --devin set")
            return
        }
        do {
            try DevinCredentials.writeKey(key)
            // Echo only the prefix and length. Enough to tell two keys apart,
            // not enough to be a leak if the terminal is shared or screenshotted.
            let shown = key.prefix(8)
            print("stored \(shown)… (\(key.count) chars)")
            if DevinCredentials.orgID == nil {
                print("now set the org: Headroom --devin org org-…")
            }
        } catch {
            print("could not store the key: \(error)")
        }
    }

    private static func setOrg(_ value: String?) {
        guard let value, !value.isEmpty else {
            print("usage: Headroom --devin org <org-…>")
            return
        }
        // The bare UUID is the mistake worth catching here: the endpoint answers
        // "Organization not found" for it, which reads like the wrong account
        // rather than the wrong format.
        if !value.hasPrefix("org-") {
            print("warning: org ids start with 'org-'; a bare UUID will 404")
        }
        DevinCredentials.orgID = value
        print("org set to \(value)")
    }

    private static func setAllowance(_ value: String?) {
        guard let value, let number = Double(value), number > 0 else {
            print("usage: Headroom --devin allowance <acus per period>")
            return
        }
        DevinCredentials.allowance = number
        print("allowance set to \(Int(number)) ACUs — the gauge now has a denominator")
    }

    private static func clear() {
        do {
            try DevinCredentials.clearKey()
            print("key cleared")
        } catch {
            print("could not clear the key: \(error)")
        }
    }

    /// The one command that talks to the network, so it doubles as the check that
    /// a freshly stored key and org actually work together.
    private static func list() {
        guard let org = DevinCredentials.orgID else {
            print("no org set: Headroom --devin org org-…")
            return
        }
        let key: String
        do {
            key = try DevinCredentials.readKey()
        } catch {
            print("no key: \(error)")
            return
        }

        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            do {
                let sessions = try await DevinClient().fetchSessions(orgID: org, apiKey: key)
                let summary = DevinUsage.summarise(
                    sessions, allowance: DevinCredentials.allowance, now: Date())

                if summary.isEmpty {
                    print("no sessions in this org yet")
                } else {
                    for session in sessions {
                        print(String(format: "  %-40s %-10s %6.2f ACU",
                                     (session.displayTitle as NSString).utf8String!,
                                     (session.status.label as NSString).utf8String!,
                                     session.acusConsumed))
                    }
                }
                print("")
                print("\(summary.active) active · \(summary.asleep) asleep · \(summary.failed) failed")
                let acus = String(format: "%.2f", summary.acus)
                if let percent = summary.percent {
                    print("\(acus) ACUs — \(String(format: "%.1f", percent))% of allowance")
                } else {
                    print("\(acus) ACUs — set an allowance for a percentage")
                }
            } catch {
                print("fetch failed: \(error)")
            }
        }
        done.wait()
    }
}
