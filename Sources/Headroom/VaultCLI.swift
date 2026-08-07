import Foundation

/// `Headroom --vault <status|save|list|switch|usage>`
///
/// The account commands exist on the command line as well as in the UI because
/// the first read of Claude Code's Keychain item triggers a macOS authorisation
/// prompt, and a prompt that appears out of nowhere while a menu bar popover is
/// open is a bad first experience. Running `--vault save` deliberately puts the
/// prompt where it is expected.
///
/// `status` is the one command guaranteed never to prompt: it asks whether the
/// item exists and when it changed, never for its contents.
enum VaultCLI {
    static func run(_ arguments: [String]) {
        let vault = AccountVault()
        let command = arguments.first ?? "status"

        switch command {
        case "status":
            status(vault)
        case "list":
            list(vault)
        case "save":
            guard let name = arguments.dropFirst().first else {
                print("usage: Headroom --vault save <name>")
                return
            }
            save(vault, name: name)
        case "switch":
            guard let name = arguments.dropFirst().first else {
                print("usage: Headroom --vault switch <name>")
                return
            }
            activate(vault, name: name, force: arguments.contains("--force"))
        case "forget":
            guard let name = arguments.dropFirst().first else {
                print("usage: Headroom --vault forget <name>")
                return
            }
            do {
                try vault.forget(name)
                print("forgot \(name) — its credential is kept in backups/")
            } catch {
                print("could not forget: \(error)")
            }
        case "login":
            guard let name = arguments.dropFirst().first else {
                print("usage: Headroom --vault login <name>")
                return
            }
            login(vault, name: name)
        case "login-url":
            guard let name = arguments.dropFirst().first else {
                print("usage: Headroom --vault login-url <name>")
                return
            }
            loginURL(vault, name: name)
        case "login-code":
            let rest = Array(arguments.dropFirst())
            guard rest.count >= 2 else {
                print("usage: Headroom --vault login-code <name> <code>")
                return
            }
            loginCode(vault, name: rest[0], pasted: rest[1])
        case "import":
            let rest = Array(arguments.dropFirst())
            guard rest.count >= 2 else {
                print("usage: Headroom --vault import <name> <path-to-credentials.json>")
                return
            }
            importBlob(vault, name: rest[0], path: rest[1])
        case "usage":
            usage(vault)
        default:
            print("usage: Headroom --vault <status|list|login <name>|import <name> <file>|save <name>|switch <name>|forget <name>|usage>")
        }
    }

    private static func status(_ vault: AccountVault) {
        print("KEYCHAIN  service=\(ClaudePaths.keychainService) account=\(Keychain.defaultAccount)")
        let exists = Keychain.exists()
        print("  present   \(exists ? "yes" : "no")")
        if let modified = Keychain.modifiedAt() {
            // The item is rewritten on every token refresh, so this doubles as
            // "when did this account last talk to the server".
            print("  modified  \(modified) (\(Format.ago(Date().timeIntervalSince(modified))) ago)")
        }
        if !exists {
            print("  note      Claude Code has never signed in on this machine, or uses a file")
        }

        let identity = IdentityReader().read()
        print("")
        print("SIGNED IN")
        print("  email     \(identity?.email ?? "—")")
        print("  plan      \(identity?.planLabel ?? "—")")

        print("")
        list(vault)
        print("")
        print("  (reading the token itself will prompt for Keychain access; run")
        print("   `--vault save <name>` when you are ready to approve it)")
    }

    private static func list(_ vault: AccountVault) {
        let accounts = vault.accounts()
        print("VAULT  \(accounts.count) account\(accounts.count == 1 ? "" : "s")")
        guard !accounts.isEmpty else {
            print("  none saved yet — `--vault save <name>` stores the current login")
            return
        }
        let active = vault.activeAccount()?.name
        for account in accounts {
            let mark = account.name == active ? "*" : " "
            let week = account.lastWeeklyPercent.map { "7d \($0)%" } ?? "7d —"
            print("  \(mark) \(account.name)  \(account.email ?? "—")  \(account.plan ?? "—")  \(week)")
        }
    }

    private static func save(_ vault: AccountVault, name: String) {
        do {
            let account = try vault.capture(as: name)
            print("saved \(account.name)  \(account.email ?? "—")  \(account.plan ?? "—")")
        } catch {
            print("could not save: \(error)")
        }
    }

    private static func activate(_ vault: AccountVault, name: String, force: Bool) {
        let verdict = SessionGuard().verdict()
        if case .busy(let sessions) = verdict, !force {
            let names = sessions.filter(\.isBusy).map(\.name).joined(separator: ", ")
            print("held: a session is mid-request (\(names))")
            print("swapping credentials under a live turn loses the turn — retry, or --force")
            return
        }
        do {
            let account = try vault.activate(name, force: force)
            print("switched to \(account.name)  \(account.email ?? "—")")
            print("existing sessions pick this up on their next turn")
        } catch {
            print("could not switch: \(error)")
        }
    }

    /// Signs a *new* account in through the browser and files it in the vault.
    ///
    /// Unlike `save`, this never reads or writes the Keychain, so the account you
    /// are currently working under is untouched. That removes the ordering trap
    /// in the old flow, where adding a second account meant signing out of the
    /// first and stranding its token if the vault copy was stale.
    private static func login(_ vault: AccountVault, name: String) {
        let pending = OAuthFlow.begin()

        print("opening your browser to sign in\n")
        print(pending.url.absoluteString)
        print("")
        Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [pending.url.absoluteString])

        print("sign in, then paste the code the page shows you:")
        guard let pasted = readLine(strippingNewline: true), !pasted.isEmpty else {
            print("nothing pasted — aborted, nothing changed")
            return
        }

        let done = DispatchSemaphore(value: 0)
        // Detached for the same reason `usage` is: this binary links AppKit, so a
        // plain Task would be main-actor bound and deadlock against the wait below.
        Task.detached {
            do {
                let (credentials, identity) = try await OAuthFlow.exchange(
                    pasted: pasted, pending: pending, diagnosticsDirectory: vault.root)
                let account = try vault.adopt(credentials, identity: identity, as: name)
                print("added \(account.name)  \(account.email ?? "—")  \(account.plan ?? "—")")
                print("the account you were using is still signed in — nothing was swapped")
            } catch {
                print("could not add: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
    }

    /// Half one of the same flow, split so the browser does not have to be on
    /// this machine.
    ///
    /// `login` holds the verifier in memory and blocks on `readLine`, which ties
    /// the sign-in to this terminal and loses the flow if the window goes away.
    /// Splitting it costs one file and buys three things: you can sign in on a
    /// phone or another Mac, the flow survives a closed terminal, and the code
    /// can arrive through any channel at all.
    ///
    /// That last point is safe in a way the tokens never are. The pasted code is
    /// single-use, short-lived, and worthless without the PKCE verifier -- which
    /// is written below and never leaves this machine. Someone who intercepts the
    /// code cannot redeem it. That is the entire reason PKCE exists.
    private static func loginURL(_ vault: AccountVault, name: String) {
        let pending = OAuthFlow.begin()
        do {
            try PendingLogin(name: name, pending: pending).write(to: vault.root)
        } catch {
            print("could not stash the pending sign-in: \(error.localizedDescription)")
            return
        }

        print("1. open this on any device and sign in as the account you want to add:\n")
        print(pending.url.absoluteString)
        print("\n2. the page shows a code. then run:\n")
        print("   Headroom --vault login-code \(name) <code>")
    }

    /// Half two: redeems the code against the verifier stashed by `login-url`.
    private static func loginCode(_ vault: AccountVault, name: String, pasted: String) {
        let stash: PendingLogin
        do {
            stash = try PendingLogin.read(from: vault.root)
        } catch {
            print("no sign-in is pending — run `--vault login-url \(name)` first")
            return
        }
        guard stash.name == name else {
            // The verifier is bound to one authorization code. Redeeming under a
            // different name would file the wrong account under it silently.
            print("the pending sign-in is for \(stash.name), not \(name)")
            return
        }

        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let (credentials, identity) = try await OAuthFlow.exchange(
                    pasted: pasted, pending: stash.pending, diagnosticsDirectory: vault.root)
                let account = try vault.adopt(credentials, identity: identity, as: name)
                // Only now: the code is spent, so the stash is dead weight and the
                // verifier should not outlive its use.
                PendingLogin.clear(from: vault.root)
                print("added \(account.name)  \(account.email ?? "—")  \(account.plan ?? "—")")
                print("the account you were using is still signed in — nothing was swapped")
            } catch {
                print("could not add: \(error.localizedDescription)")
                print("codes expire quickly — run `--vault login-url \(name)` again for a fresh one")
            }
            done.signal()
        }
        done.wait()
    }

    /// Files a credential exported from another machine.
    ///
    /// The safe way to move an account that is already signed in elsewhere: copy
    /// the blob over directly and hand the file to this command. Nothing about
    /// the token ever passes through a chat, an inbox, or a clipboard it did not
    /// have to.
    ///
    /// **The account must be signed out on the machine it came from.** Two
    /// machines holding one refresh token is not a backup, it is a race: the
    /// first to refresh rotates the token and the second is left holding a
    /// consumed one, whose replay revokes the whole family.
    private static func importBlob(_ vault: AccountVault, name: String, path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            print("cannot read \(url.path)")
            return
        }

        let credentials = Credentials(raw: data)
        guard credentials.accessToken != nil else {
            print("that file has no access token in it — expected the contents of a")
            print("`Claude Code-credentials` keychain item, or a Headroom credentials.json")
            return
        }

        // The blob carries the account's own identity when it was minted by
        // OAuthFlow. An older one may not, in which case the account still saves
        // and picks up its email the first time it is switched to.
        let identity = Self.identity(in: data)
        do {
            let account = try vault.adopt(credentials, identity: identity, as: name)
            print("imported \(account.name)  \(account.email ?? "email unknown until first switch")")
            if let expiry = credentials.expiresAt {
                print("access token expires \(expiry) — it will refresh itself")
            }
            print("sign this account OUT on the machine it came from, or the two")
            print("copies will race and burn the token")
        } catch {
            print("could not import: \(error)")
        }
    }

    /// Identity out of a credential blob's `tokenAccount`, which is where Claude
    /// Code stores it alongside the tokens.
    private static func identity(in data: Data) -> Identity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] ?? root as [String: Any]?,
              let account = oauth["tokenAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String,
              let uuid = account["uuid"] as? String
        else { return nil }

        return Identity(
            email: email,
            accountUUID: uuid,
            organizationUUID: account["organizationUuid"] as? String,
            organizationType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    /// Proves the per-account usage endpoint end to end.
    private static func usage(_ vault: AccountVault) {
        let accounts = vault.accounts()
        guard !accounts.isEmpty else {
            print("no accounts saved — `--vault save <name>` first")
            return
        }

        // Resolve every token up front so the detached task captures only plain
        // strings. Reaching into the vault from inside the closure would make it
        // a `sending` violation under Swift 6 concurrency checking.
        let tokens: [(name: String, token: String?)] = accounts.map {
            ($0.name, vault.accessToken(for: $0))
        }

        let done = DispatchSemaphore(value: 0)

        // Detached so the work never lands on the main run loop, which this
        // thread is about to block. Getting that wrong hangs forever -- this
        // binary links AppKit, so a plain `Task` would be main-actor bound.
        Task.detached {
            let client = UsageClient()
            for entry in tokens {
                guard let token = entry.token else {
                    print("  \(entry.name.padded(16)) no token")
                    continue
                }
                do {
                    let snapshot = try await client.fetch(accessToken: token)
                    let p5 = snapshot.session?.reading.percent.map { "\($0)%" } ?? "—"
                    let p7 = snapshot.weekly?.reading.percent.map { "\($0)%" } ?? "—"
                    print("  \(entry.name.padded(16)) 5h \(p5.padded(6)) 7d \(p7)")
                } catch {
                    print("  \(entry.name.padded(16)) \(error)")
                }
            }
            done.signal()
        }
        done.wait()
    }
}
